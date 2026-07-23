# EFA-accelerated FSx for Lustre (self-managed Karpenter)

A `p6-b200.48xlarge` NodePool whose nodes install the **EFA-enabled Lustre client** at boot via `userData`, so they can mount FSx for Lustre over the **EFA (RDMA) transport** rather than TCP. This is the piece EKS Auto Mode cannot do - Auto Mode manages node bootstrap and does not support `userData`, so its nodes mount Lustre over TCP via the CSI driver only (see [`../../../../../manifests/fsx-lustre/README.md`](../../../../../manifests/fsx-lustre/README.md)).

This folder is the EFA counterpart to [`../b-200s-static/`](../b-200s-static/): same reservation-backed static p6-b200 pool, but the `gpu-static-fsx` NodeClass adds the Lustre + EFA + GDS client install. It is applied manually with `kubectl` (not wired into `var.nodepools`), against an existing capacity reservation.

## What the userData installs

The `gpu-static-fsx` NodeClass `userData` is MIME-multipart: an EKS `NodeConfig` doc (same bootstrap settings as the base `gpu-static` pool) plus a shell script that:

1. Installs `lustre-client` and the EFA driver (`install-fsx-lustre-client.sh --install-lustre --install-efa`).
2. Builds and loads the NVIDIA **GDS** (GPUDirect Storage) kernel module `nvidia-fs` so GPUs can read from Lustre directly. *Optional* - remove that block if you don't need GDS.
3. Configures EFA for the Lustre client (`setup.sh --optimized-for-gds`).

This adds **~5-10 minutes** to first boot (package installs + a kernel-module build). It is harmless when no FSx is mounted.

Refs: <https://docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html>

## Prerequisites

- The Karpenter cluster deployed with `enable_efa=true` (installs the EFA device plugin + MPI Operator; see the [EFA section of the top-level README](../../../README.md#elastic-fabric-adapterefa)).
- An existing On-Demand Capacity Reservation / Capacity Block for `p6-b200.48xlarge`.

First, set these to match your environment. Every command below references them, so nothing else needs editing:

```bash
export AWS_REGION=                         # region hosting the cluster and reservation; Terraform defaults to us-west-2
export CLUSTER_NAME=ai-eks-cmax-kar        # also the karpenter.sh/discovery tag value; matches var.cluster_name
export INSTANCE_TYPE=p6-b200.48xlarge      # reserved GPU instance type
```

> Set `AWS_REGION` to the region you deployed into. If you leave it empty, the commands fall back to
> your AWS CLI's configured default region (`aws configure get region`) - make sure that matches the
> Terraform stack, whose `var.region` default is **us-west-2**.

Export the reservation values (same as the base pool). The AZ is read back from the
reservation itself, so it does not need to be set by hand:

```bash
export CAPACITY_RESERVATION_ID=$(aws ec2 describe-capacity-reservations \
  --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=$INSTANCE_TYPE" \
  --query 'CapacityReservations[0].CapacityReservationId' --output text)

export RESERVED_INSTANCE_COUNT=$(aws ec2 describe-capacity-reservations \
  --region "$AWS_REGION" --capacity-reservation-ids "$CAPACITY_RESERVATION_ID" \
  --query 'CapacityReservations[0].TotalInstanceCount' --output text)

# AZ derived from the reservation - the same-AZ requirement for FSx keys off this:
export FSX_AZ=$(aws ec2 describe-capacity-reservations \
  --region "$AWS_REGION" --capacity-reservation-ids "$CAPACITY_RESERVATION_ID" \
  --query 'CapacityReservations[0].AvailabilityZone' --output text)

echo "Reservation: $CAPACITY_RESERVATION_ID  Instances: $RESERVED_INSTANCE_COUNT  AZ: $FSX_AZ"
```

> If you have **more than one** active reservation for `$INSTANCE_TYPE` (e.g. in different AZs),
> the lookup above picks the first one. Add `"Name=availability-zone,Values=<az>"` to the
> `--filters` to pin the one you want.

## 1. Provision the file system

FSx must land in the **same AZ** as the reservation, and for EFA the file system and clients must share the same **/16 CIDR**. Pick a private subnet (tagged `karpenter.sh/discovery`) in that AZ:

```bash
export FSX_SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" "Name=availability-zone,Values=$FSX_AZ" \
  --query 'Subnets[0].SubnetId' --output text)
echo "FSx subnet: $FSX_SUBNET_ID"
```

Apply from the Karpenter Terraform directory. The default is the EFA-enabled minimum (38400 GiB) at the lowest tier (125 MB/s/TiB) - the combination most likely to have capacity:

```bash
cd ../..    # into terraform/karpenter
terraform apply -var "region=$AWS_REGION" -var 'enable_fsx=true' -var "subnet_id=$FSX_SUBNET_ID"
```

> **`PERSISTENT_2` capacity errors.** *"Filesystem failed to create due to insufficient capacity"* is a real per-AZ signal for the throughput tier - lowering `storage_capacity` does not help. The top tier (`per_unit_storage_throughput=1000`) is the most constrained. Retry with a lower tier (`500`/`250`/`125`), or wait. The AZ is fixed by the EFA same-AZ requirement, so the tier is the lever, not the AZ.

The file system takes ~10-30 min to reach `AVAILABLE`. Terraform also creates the FSx CSI driver add-on and the static PV/PVC. Verify:

```bash
terraform output fsx_file_system_id
kubectl get pvc fsx-lustre-claim -n default   # expect STATUS Bound
```

## 2. Apply the NodeClass and NodePool

`nodeclass-gpu-static-fsx.yaml` uses `${CLUSTER_NAME}`, `${KARPENTER_NODE_ROLE}`, and `${CAPACITY_RESERVATION_ID}`; `nodepool-gpu-static-fsx.yaml` uses `${RESERVED_INSTANCE_COUNT}`. Set the remaining vars and substitute with `envsubst`:

```bash
cd nodepools/b-200s-static-fsx
# CLUSTER_NAME is already exported from the setup block above
export KARPENTER_NODE_ROLE=$(terraform -chdir=../.. output -raw node_iam_role_name)
echo "Node role: $KARPENTER_NODE_ROLE"
```

> **Important:** pass `envsubst` an **explicit variable allowlist**. The NodeClass `userData` contains
> shell variables (`$GDS_NVIDIA_FS_VERSION`, `$(uname -r)`, ...) that a bare `envsubst` would replace
> with empty strings, breaking the boot script (e.g. `git clone --branch ""`). Restricting it to only
> the three template vars leaves the shell script intact:

```bash
# Preview (confirm the three vars resolved and the userData shell vars are untouched):
envsubst '$CLUSTER_NAME $KARPENTER_NODE_ROLE $CAPACITY_RESERVATION_ID' < nodeclass-gpu-static-fsx.yaml | cat
envsubst '$RESERVED_INSTANCE_COUNT' < nodepool-gpu-static-fsx.yaml | cat

# Apply:
envsubst '$CLUSTER_NAME $KARPENTER_NODE_ROLE $CAPACITY_RESERVATION_ID' < nodeclass-gpu-static-fsx.yaml | kubectl apply -f -
envsubst '$RESERVED_INSTANCE_COUNT' < nodepool-gpu-static-fsx.yaml | kubectl apply -f -
```

Nodes take longer than the base pool to become `Ready` because of the client install. Watch:

```bash
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-static-fsx -o wide -w
```

## 3. Verify the client install (SSM)

The client install runs in `userData`; confirm it succeeded before mounting. Find the node's instance ID and open an SSM session:

```bash
INSTANCE_ID=$(kubectl get nodes -l karpenter.sh/nodepool=gpu-static-fsx \
  -o jsonpath='{.items[0].spec.providerID}' | cut -d/ -f5)
aws ssm start-session --target "$INSTANCE_ID"
```

On the node, check the bootstrap log and confirm the client is present:

```bash
sudo tail -n 20 /var/log/cloud-init-output.log   # expect: EFA on FSx for Lustre client setup completed successfully.
which lfs lctl lnetctl
lsmod | grep -E 'lustre|nvidia_fs'
```

## 4. Test with a GPU pod (CSI mount, TCP)

[`fsx-efa-test.yaml`](../../../../../manifests/fsx-lustre/fsx-efa-test.yaml) (in `manifests/fsx-lustre/`) runs a GPU pod on `gpu-static-fsx` that mounts `fsx-lustre-claim` and installs `fio`. The **CSI pod mount is over TCP** even here - the EFA transport is verified at the node level in step 5.

```bash
kubectl apply -f ../../../../../manifests/fsx-lustre/fsx-efa-test.yaml
kubectl get pod fsx-efa-test          # expect Running
kubectl exec fsx-efa-test -- df -hT /data
```

Expected: a `lustre` type with a `<ip>@tcp:/<mountname>` source, e.g. `100.64.59.94@tcp:/iatcdb4v ... /data`.

Run fio inside the pod:

```bash
kubectl exec -it fsx-efa-test -- bash
# quick single-job write (~1 GB/s = one OST):
fio --name=seqwrite --rw=write --bs=16M --size=1G --numjobs=1 --directory=/data --ioengine=sync --group_reporting
# scaled write across OSTs:
fio --name=seqwrite --rw=write --bs=16M --size=16G --numjobs=32 --directory=/data --direct=1 --ioengine=libaio --iodepth=64 --group_reporting --status-interval=1
```

Capacity sets the OST count (1 OST per 2400 GiB); more OSTs = more parallel throughput. See [`../../../../../manifests/fsx-lustre/README.md`](../../../../../manifests/fsx-lustre/README.md) for how to read the numbers.

## 5. Verify EFA is carrying the traffic (node-level, SSM)

The EFA (RDMA) transport shows up on a **node-level** mount using the client from step 3. SSM into the node, mount the filesystem directly, and watch the Lustre network interfaces while fio runs.

> The node already has the filesystem mounted by the CSI driver, so read the Lustre source
> (`<nid>@tcp:/<mountname>`) straight off that mount rather than calling the AWS CLI - your local
> `$AWS_REGION`/`$FSX_ID` exports do **not** cross into the SSM session, and the NID Lustre actually
> uses is the MGS IP, not the FSx DNS name.

```bash
# On the node (via SSM). Reuse the source from the existing CSI mount - no AWS CLI needed:
SRC=$(mount -t lustre | awk 'NR==1{print $1}')   # e.g. 10.0.114.214@tcp:/lbg6db4v
echo "$SRC"

sudo mkdir -p /mnt/fsx
sudo mount -t lustre "$SRC" /mnt/fsx
df -h /mnt/fsx
mount | grep /mnt/fsx

# Run fio and check which interfaces carry traffic:
sudo yum install -y fio
sudo fio --name=test --rw=write --bs=16M --size=16G --numjobs=32 --directory=/mnt/fsx \
  --direct=1 --ioengine=libaio --iodepth=64 --group_reporting &
sleep 3
sudo lctl get_param nis | grep @efa | head -5   # tx credits dip below max here = EFA is carrying traffic
sudo lctl get_param nis | grep @tcp | head -5
wait
```

**Reading the output.** The columns are `nid status alive refs peer rtr max tx min`. The tell is the
last three - tx credits: `max` (ceiling), `tx` (current), `min` (low-water mark: fewest credits ever
left, i.e. how much concurrent traffic actually hit that interface). A pass looks like this - `min`
drops below `max` on every `@efa` NID, while `@tcp` stays pegged at `min == max`:

```
115.10.113.0@efa   up  -1  1  128  0  256  256  248   <- min 248 < max 256: RDMA traffic went out
115.10.114.0@efa   up  -1  0  128  0  256  256  249
115.10.132.0@efa   up  -1  0  128  0  256  256  249
10.0.115.10@tcp    up  -1  1    8  0  320  320  320   <- min == max: TCP essentially idle
10.0.115.10@tcp    up  -1  0    8  0  320  320  320
```

Multiple active `@efa` NIDs (one per network card) means the multi-rail config from
`setup.sh --optimized-for-gds` took. If instead `@tcp` shows the drop and `@efa` stays at `min == max`
(or has no rows), the client install or EFA setup did not take - re-check step 3's `cloud-init-output.log`.

### Confirm a real pod / ML job is using it

The mount above is a manual node-level test. To confirm an actual **pod** (or ML job) is using FSx -
and over which transport - check three layers. "Using it" can mean the mount, the EFA transport, or
GPUDirect Storage (GDS); each has its own check, and a job can pass the first and fail the later ones.

**Layer 1 - is the pod mounting FSx?** From the pod (`fsx-efa-test` mounts `fsx-lustre-claim` at `/data`):

```bash
kubectl exec fsx-efa-test -- df -hT /data          # expect type "lustre", source <nid>@tcp:/<mountname>
kubectl exec fsx-efa-test -- stat -f -c '%T' /data  # expect: lustre  (works without `mount` installed)
```

The `@tcp:/` in the source is only the mount's bootstrap NID string - it does **not** mean the data
path is TCP. Transport is chosen per node by LNet (see layer 2). If `/data` isn't `lustre`, the PVC
didn't attach - `kubectl describe pod fsx-efa-test` and confirm `fsx-lustre-claim` is `Bound`.

**Layer 2 - is the pod's I/O riding EFA?** LNet is a single node-global subsystem shared by every
Lustre mount on the node (including the pod's CSI mount), so the same `nis` check works - just watch it
**while the pod does I/O**. Find the node, drive a write from the pod, and watch the transport live:

```bash
kubectl get pod fsx-efa-test -o wide     # note NODE, then SSM into it

# On the node (SSM), watch live:
watch -n1 'lctl get_param -n nis | grep -E "@efa|@tcp"'

# In another shell, drive I/O from the pod:
kubectl exec -it fsx-efa-test -- bash -c \
  'dnf install -y -q fio && fio --name=w --rw=write --bs=16M --size=16G --numjobs=32 \
   --directory=/data --direct=1 --ioengine=libaio --iodepth=64 --group_reporting'
```

`@efa` tx credits (`min`) dipping below `max` in lockstep with the pod's writes = the pod's Lustre I/O
is on EFA. Only `@tcp` moving = it's not. Two quick static checks on the node confirm the plumbing even
without driving I/O:

```bash
lnetctl peer show | grep -c '@efa'      # count of EFA peers; 0 means EFA never came up
lctl get_param osc.*.ost_conn_uuid      # which NID each OST is reached through
```

**Layer 3 - is the GPU using GDS?** The mount and EFA can both be perfect while the app still bounces
through a CPU buffer - GDS only engages when the app issues `cuFile` reads (via a cuFile-aware framework
like NVIDIA DALI, or the `gdsio` benchmark - not plain `fio`). The kernel module counters move only on
real GDS I/O:

```bash
# On the node (SSM), while a GDS-aware job runs:
cat /proc/driver/nvidia-fs/stats     # read/write ops + bytes climbing = GDS in use
```

If those counters stay at zero while the app reads `/data`, the data is taking the normal POSIX path
(GPU ← CPU bounce buffer ← Lustre), not GPUDirect - i.e. the app isn't using cuFile. This is the most
common "why isn't GDS helping" case and is an application concern, not a node-setup one.

To *generate* GDS traffic directly (rather than wait for a real workload), use `gdsio` - the benchmark
that ships with the NVIDIA GDS tools and issues genuine `cuFile` I/O. First stripe the target dir
across all OSTs so throughput isn't bottlenecked on one, then run a read against a GPU:

```bash
# On the node (SSM). Requires the GDS user-space tools (gdsio) and a GPU on the box:
sudo mkdir -p /mnt/fsx/gds && sudo lfs setstripe -S 1M -c -1 /mnt/fsx/gds   # stripe across all OSTs
gdsio -D /mnt/fsx/gds -d 0 -w 32 -s 100G -i 1M -x 0 -I 1                     # -d 0 = GPU 0, -x 0 = GDS mode, -I 1 = read
cat /proc/driver/nvidia-fs/stats     # confirm the read ops/bytes counters advanced
```

`gdsio -x 0` forces the GPUDirect path (`-x 1` would be the CPU-bounce comparison), so if the
`nvidia-fs` stats advance during an `-x 0` run, GDS is genuinely working end to end.

## Troubleshooting

- **Node never becomes `Ready`** - the client install failed. SSM in and read `/var/log/cloud-init-output.log`; a failed `make` (GDS kernel module) or a network error on the FSx script downloads are the usual causes.
- **Pod stuck `ContainerCreating` / mount timeout** - Lustre ports 988 and 1018-1023 between nodes and the filesystem. Covered by default (nodes attach the `shared` SG whose self-ingress is all-protocols); re-add if you changed the SG (see the Auto Mode README's troubleshooting).
- **`@efa` shows no traffic** - EFA client setup didn't apply, or the file system and node are not in the same /16. Confirm `EfaEnabled` on the filesystem and that `subnet_id` shares the node's CIDR block.

## Cleanup

Run from `nodepools/b-200s-static-fsx` (where the NodeClass/NodePool live; the test pod is under `manifests/`):

```bash
kubectl delete -f ../../../../../manifests/fsx-lustre/fsx-efa-test.yaml
kubectl delete -f nodepool-gpu-static-fsx.yaml
kubectl delete -f nodeclass-gpu-static-fsx.yaml
```

Deleting the NodePool drains and terminates the reserved nodes; the reservation keeps billing until released. The FSx PV uses a `Retain` policy, so the filesystem survives - to remove it, re-apply with `-var 'enable_fsx=false'` (keeping the other vars) or `terraform destroy`.
