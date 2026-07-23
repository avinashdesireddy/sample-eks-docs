# EFA-accelerated FSx for Lustre (self-managed Karpenter)

A static, reservation-backed GPU NodePool whose nodes install the **EFA-enabled Lustre client** at boot (via `userData`), so they mount FSx for Lustre over the **EFA (RDMA) transport** instead of TCP.

> The manifests here are sized for **`p6-b200.48xlarge`** (8 EFA network cards). For another EFA-capable instance, set `$INSTANCE_TYPE` below and adjust the `networkInterfaces` list in `nodeclass-gpu-static-fsx.yaml` to that instance's network-card count.

## Prerequisites

- The Karpenter cluster deployed with `enable_efa=true` (see the [EFA section of the top-level README](../../../README.md#elastic-fabric-adapterefa)).
- An existing On-Demand Capacity Reservation or [Capacity Block for ML](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-blocks-using.html) for your GPU instance type.

First, set your environment. Every command below references these:

```bash
export AWS_REGION=us-west-2        # region hosting the cluster and reservation
export CLUSTER_NAME=ai-eks-docs    # matches var.cluster_name
```

Set your reserved EFA-capable GPU instance type (e.g. `p6-b200.48xlarge`):

```bash
export INSTANCE_TYPE=
```

Next, read the reservation's values back from EC2 — its ID, then the instance count and AZ from that ID. (The AZ drives the FSx same-AZ requirement, so you don't set it by hand.)

```bash
# Find the reservation for your instance type:
export CAPACITY_RESERVATION_ID=$(aws ec2 describe-capacity-reservations \
  --region "$AWS_REGION" \
  --filters "Name=state,Values=active" "Name=instance-type,Values=$INSTANCE_TYPE" \
  --query 'CapacityReservations[0].CapacityReservationId' --output text)


# Which AZ it's in (FSx and the nodes must share it):
export FSX_AZ=$(aws ec2 describe-capacity-reservations \
  --region "$AWS_REGION" --capacity-reservation-ids "$CAPACITY_RESERVATION_ID" \
  --query 'CapacityReservations[0].AvailabilityZone' --output text)

echo "Reservation: $CAPACITY_RESERVATION_ID AZ: $FSX_AZ"
```

> With **more than one** active reservation for `$INSTANCE_TYPE` (e.g. in different AZs), this picks the first. Add additional `--filters` to pin the one you want.

## 1. Provision the file system

FSx must land in the **same AZ** as the reservation, and for EFA the file system and clients must share the same **/16 CIDR**. Pick a private subnet (tagged `karpenter.sh/discovery`) in that AZ:

```bash
export FSX_SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" "Name=availability-zone,Values=$FSX_AZ" \
  --query 'Subnets[0].SubnetId' --output text)
echo "FSx subnet: $FSX_SUBNET_ID"
```

Use `terraform` to create the smallest file system by default (4800 GiB):

```bash
terraform -chdir=../.. apply -var 'enable_fsx=true' -var "subnet_id=$FSX_SUBNET_ID"
```

> To size it up, override `storage_capacity` and `per_unit_storage_throughput` (see their descriptions in [`../../fsx-lustre.tf`](../../fsx-lustre.tf) for the valid values and how they interact). If creation fails with an insufficient-capacity error, that AZ is short on the requested tier — drop to a lower `per_unit_storage_throughput` (`500`/`250`/`125`) and raise `storage_capacity` to that tier's minimum.

The file system takes ~10-30 min to reach `AVAILABLE`. Terraform also creates the FSx CSI driver add-on and the static PV/PVC. Verify:

```bash
terraform output fsx_file_system_id
kubectl get pvc fsx-lustre-claim -n default   # expect STATUS Bound
```

## 2. Apply the NodeClass and NodePool

The manifests use template vars: `nodeclass-gpu-static-fsx.yaml` needs `${CLUSTER_NAME}`, `${KARPENTER_NODE_ROLE}`, `${CAPACITY_RESERVATION_ID}`; `nodepool-gpu-static-fsx.yaml` needs `${RESERVED_INSTANCE_COUNT}`. Fill in the node role, then substitute with `envsubst`:

```bash
export KARPENTER_NODE_ROLE=$(terraform -chdir=../.. output -raw node_iam_role_name)
echo "Node role: $KARPENTER_NODE_ROLE"
```

> **Pass `envsubst` an explicit variable allowlist.** The NodeClass `userData` contains shell variables (`$GDS_NVIDIA_FS_VERSION`, `$(uname -r)`, ...) that a bare `envsubst` would blank out, breaking the boot script (e.g. `git clone --branch ""`). Restricting it to the template vars leaves the shell script intact.

Preview to confirm the vars resolved
```bash
envsubst '$CLUSTER_NAME $KARPENTER_NODE_ROLE $CAPACITY_RESERVATION_ID' < nodeclass-gpu-static-fsx.yaml | cat
envsubst '$RESERVED_INSTANCE_COUNT' < nodepool-gpu-static-fsx.yaml | cat
```

Apply:
```bash
envsubst '$CLUSTER_NAME $KARPENTER_NODE_ROLE $CAPACITY_RESERVATION_ID' < nodeclass-gpu-static-fsx.yaml | kubectl apply -f -
envsubst '$RESERVED_INSTANCE_COUNT' < nodepool-gpu-static-fsx.yaml | kubectl apply -f -
```

Nodes take longer than the base pool to become `Ready` because of the client install. Watch:

```bash
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-static-fsx -o wide -w
```

## 3. Verify the client install (SSM)

Confirm the `userData` install succeeded before mounting. Find the node's instance ID and open an SSM session:

```bash
INSTANCE_ID=$(kubectl get nodes -l karpenter.sh/nodepool=gpu-static-fsx \
  -o jsonpath='{.items[0].spec.providerID}' | cut -d/ -f5)
aws ssm start-session --target "$INSTANCE_ID"
```

On the node:

```bash
sudo tail -n 20 /var/log/cloud-init-output.log   # expect: EFA on FSx for Lustre client setup completed successfully.
which lfs lctl lnetctl
lsmod | grep -E 'lustre|nvidia_fs'
```

## 4. Test with a GPU pod (CSI mount, TCP)

[`fsx-efa-test.yaml`](../../../../../manifests/fsx-lustre/fsx-efa-test.yaml) runs a GPU pod on `gpu-static-fsx` that mounts `fsx-lustre-claim` and installs `fio`. The **CSI pod mount is over TCP** — the EFA transport is verified at the node level in step 5.

```bash
kubectl apply -f ../../../../../manifests/fsx-lustre/fsx-efa-test.yaml
kubectl get pod fsx-efa-test          # expect Running
kubectl exec fsx-efa-test -- df -hT /data
```

Expect a `lustre` type with a `<ip>@tcp:/<mountname>` source, e.g. `100.64.59.94@tcp:/iatcdb4v ... /data`.

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

The EFA (RDMA) transport shows up on a **node-level** mount using the client from step 3. SSM into the node, mount the filesystem, and watch the Lustre network interfaces while fio runs.

> Read the Lustre source (`<nid>@tcp:/<mountname>`) off the existing CSI mount rather than the AWS CLI — your local exports don't cross into the SSM session, and the NID Lustre uses is the MGS IP, not the FSx DNS name.

```bash
# On the node (via SSM). Reuse the source from the existing CSI mount — no AWS CLI needed:
SRC=$(mount -t lustre | awk 'NR==1{print $1}')   # e.g. 10.0.114.214@tcp:/lbg6db4v
echo "$SRC"

sudo mkdir -p /mnt/fsx
sudo mount -t lustre "$SRC" /mnt/fsx
df -h /mnt/fsx

# Run fio and check which interfaces carry traffic:
sudo yum install -y fio
sudo fio --name=test --rw=write --bs=16M --size=16G --numjobs=32 --directory=/mnt/fsx \
  --direct=1 --ioengine=libaio --iodepth=64 --group_reporting &
sleep 3
sudo lctl get_param nis | grep @efa | head -5
sudo lctl get_param nis | grep @tcp | head -5
wait
```

**Reading the output.** The columns are `nid status alive refs peer rtr max tx min`. The tell is the last three — tx credits: `max` (ceiling), `tx` (current), `min` (low-water mark: fewest credits ever left, i.e. how much concurrent traffic actually hit that interface). A pass looks like this — `min` drops below `max` on every `@efa` NID, while `@tcp` stays pegged at `min == max`:

```
115.10.113.0@efa   up  -1  1  128  0  256  256  248   <- min 248 < max 256: RDMA traffic went out
115.10.114.0@efa   up  -1  0  128  0  256  256  249
115.10.132.0@efa   up  -1  0  128  0  256  256  249
10.0.115.10@tcp    up  -1  1    8  0  320  320  320   <- min == max: TCP essentially idle
```

Multiple active `@efa` NIDs (one per network card) means the multi-rail config from `setup.sh --optimized-for-gds` took. If instead `@tcp` shows the drop and `@efa` stays at `min == max` (or has no rows), the client install or EFA setup didn't take — re-check step 3's `cloud-init-output.log`.

### Confirm a real pod / ML job is using it

The mount above is a manual node-level test. "Using it" can mean three different things — the mount, the EFA transport, or GPUDirect Storage (GDS) — and a pod can pass the first and fail the later ones. Check each layer:

**Layer 1 — is the pod mounting FSx?** (`fsx-efa-test` mounts `fsx-lustre-claim` at `/data`)

```bash
kubectl exec fsx-efa-test -- df -hT /data           # expect type "lustre", source <nid>@tcp:/<mountname>
kubectl exec fsx-efa-test -- stat -f -c '%T' /data  # expect: lustre  (works without `mount` installed)
```

The `@tcp:/` in the source is only the bootstrap NID string — it does **not** mean the data path is TCP (LNet picks the transport per node; see layer 2). If `/data` isn't `lustre`, the PVC didn't attach — `kubectl describe pod fsx-efa-test` and confirm `fsx-lustre-claim` is `Bound`.

**Layer 2 — is the pod's I/O riding EFA?** LNet is node-global, shared by every Lustre mount on the node (including the pod's CSI mount), so the same `nis` check works — just watch it **while the pod does I/O**:

```bash
kubectl get pod fsx-efa-test -o wide     # note NODE, then SSM into it

# On the node (SSM), watch live:
watch -n1 'lctl get_param -n nis | grep -E "@efa|@tcp"'

# In another shell, drive I/O from the pod:
kubectl exec -it fsx-efa-test -- bash -c \
  'dnf install -y -q fio && fio --name=w --rw=write --bs=16M --size=16G --numjobs=32 \
   --directory=/data --direct=1 --ioengine=libaio --iodepth=64 --group_reporting'
```

`@efa` tx credits (`min`) dipping below `max` in lockstep with the pod's writes = the pod's Lustre I/O is on EFA. Only `@tcp` moving = it's not. Two static checks confirm the plumbing even without driving I/O:

```bash
lnetctl peer show | grep -c '@efa'      # count of EFA peers; 0 means EFA never came up
lctl get_param osc.*.ost_conn_uuid      # which NID each OST is reached through
```

**Layer 3 — is the GPU using GDS?** The mount and EFA can both be perfect while the app still bounces through a CPU buffer. GDS only engages on `cuFile` reads (from a cuFile-aware framework like NVIDIA DALI, or the `gdsio` benchmark — not plain `fio`), and the kernel counters move only on real GDS I/O:

```bash
# On the node (SSM), while a GDS-aware job runs:
cat /proc/driver/nvidia-fs/stats     # read/write ops + bytes climbing = GDS in use
```

Counters stuck at zero while the app reads `/data` means the data is taking the normal POSIX path (GPU ← CPU bounce buffer ← Lustre), not GPUDirect — an application concern, not a node-setup one.

To *generate* GDS traffic directly, use `gdsio` (ships with the NVIDIA GDS tools, issues genuine `cuFile` I/O). Stripe the target dir across all OSTs first, then run a read against a GPU:

```bash
# On the node (SSM). Requires the GDS user-space tools (gdsio) and a GPU on the box:
sudo mkdir -p /mnt/fsx/gds && sudo lfs setstripe -S 1M -c -1 /mnt/fsx/gds   # stripe across all OSTs
gdsio -D /mnt/fsx/gds -d 0 -w 32 -s 100G -i 1M -x 0 -I 1                     # -d 0 = GPU 0, -x 0 = GDS mode, -I 1 = read
cat /proc/driver/nvidia-fs/stats     # confirm the read ops/bytes counters advanced
```

`gdsio -x 0` forces the GPUDirect path (`-x 1` is the CPU-bounce comparison), so if the `nvidia-fs` stats advance during an `-x 0` run, GDS is working end to end.

## What the userData installs

The `gpu-static-fsx` NodeClass `userData` is what makes the EFA mount possible, and is the reason this pool exists as a self-managed Karpenter NodeClass rather than an Auto Mode pool (Auto Mode owns node bootstrap and doesn't support `userData`). It's MIME-multipart: an EKS `NodeConfig` doc (the same bootstrap settings as the base `gpu-static` pool) plus a shell script that:

1. Installs `lustre-client` and the EFA driver.
2. Builds and loads the NVIDIA **GDS** (GPUDirect Storage) kernel module `nvidia-fs` so GPUs can read from Lustre directly. *Optional* — remove that block if you don't need GDS.
3. Configures EFA for the Lustre client (`setup.sh --optimized-for-gds`).

This adds **~5-10 minutes** to first boot (package installs + a kernel-module build), and is harmless when no FSx is mounted. Ref: <https://docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html>

## Troubleshooting

- **Node never becomes `Ready`** — the client install failed. SSM in and read `/var/log/cloud-init-output.log`; a failed `make` (GDS kernel module) or a network error on the FSx script downloads are the usual causes.
- **Pod stuck `ContainerCreating` / mount timeout** — Lustre needs ports 988 and 1018-1023 between nodes and the filesystem. Covered by default (nodes attach the `shared` SG whose self-ingress is all-protocols); re-add if you changed the SG.
- **`@efa` shows no traffic** — EFA client setup didn't apply, or the file system and node aren't in the same /16. Confirm `EfaEnabled` on the filesystem and that `subnet_id` shares the node's CIDR block.

## Cleanup

Run from `nodepools/b-200s-static-fsx` (the test pod lives under `manifests/`):

```bash
kubectl delete -f ../../../../../manifests/fsx-lustre/fsx-efa-test.yaml
kubectl delete -f nodepool-gpu-static-fsx.yaml
kubectl delete -f nodeclass-gpu-static-fsx.yaml
```

Deleting the NodePool drains and terminates the reserved nodes; the reservation keeps billing until released. The FSx PV uses a `Retain` policy, so the filesystem survives — to remove it, re-apply with `-var 'enable_fsx=false'` (keeping the other vars) or `terraform destroy`.
