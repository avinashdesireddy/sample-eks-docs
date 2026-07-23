# FSx for Lustre on EKS

Provision and test a high-throughput, shared [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html) file system for GPU workloads. This applies to **both** cluster variants - EKS Auto Mode (`../../set-up-cluster/terraform/auto-mode/`) and self-managed Karpenter (`../../set-up-cluster/terraform/karpenter/`). The file system, the FSx CSI driver, and a static `PersistentVolume`/`PersistentVolumeClaim` are provisioned by Terraform behind `enable_fsx`; this directory holds the end-to-end mount + throughput test that works on either.

Lustre gives the cluster a POSIX, `ReadWriteMany` filesystem that many GPU pods mount at once - the natural home for training datasets, checkpoints, and shared scratch. It is an optional accelerator: the inference path in [`../inference/`](../inference/) runs off the S3 model bucket and does not need Lustre.

## Transport: TCP everywhere, EFA on Karpenter

FSx for Lustre can serve clients over two transports:

- **TCP** - the standard path. The FSx CSI driver mounts the filesystem into pods over TCP. No node configuration required, and it's what **both variants** use out of the box. The provisioning and test steps on this page exercise this path.
- **EFA (RDMA)** - higher bandwidth / lower latency, but the node must run the EFA-enabled Lustre client, installed by a `userData` bootstrap script. EKS Auto Mode manages node bootstrap and does not support `userData`, so the EFA-accelerated client is only available on the self-managed **Karpenter** variant, whose `EC2NodeClass` can carry that script.

`EfaEnabled` is set on the filesystem regardless (it's required for PERSISTENT_2 with automatic metadata, and is harmless for the TCP path).

> For the EFA (RDMA) path - the userData client install plus node-level verification that traffic actually rides EFA - see the Karpenter nodepool guide: [`../../set-up-cluster/terraform/karpenter/nodepools/b-200s-static-fsx/README.md`](../../set-up-cluster/terraform/karpenter/nodepools/b-200s-static-fsx/README.md).

## How Lustre throughput works

A Lustre filesystem has three server-side components:

- **MDS** (Metadata Server) - file names, directories, permissions.
- **OSS** (Object Storage Server) - serves file data.
- **OST** (Object Storage Target) - the disk volume attached to an OSS. Files are **striped** across OSTs, so more OSTs = more parallel I/O paths = more throughput.

On FSx PERSISTENT_2, FSx creates **1 OST per 2400 GiB** of capacity, and each OST does roughly 4-5 GiB/s. So **capacity determines the throughput ceiling**, and `per_unit_storage_throughput` (125/250/500/1000 MB/s/TiB) sets the per-TiB baseline. Aggregate baseline = `per_unit_storage_throughput x (storage_capacity / 1024)` MB/s. Example: 1000 MB/s/TiB over 4.8 TiB (the default) ≈ 4.7 GB/s baseline across 2 OSTs.

## Prerequisites

- Either cluster variant deployed (see [`../../set-up-cluster/terraform/README.md`](../../set-up-cluster/terraform/README.md)) and `kubectl` configured:

  ```bash
  aws eks update-kubeconfig --region us-east-2 --name ai-eks-docs --alias ai-eks-docs
  ```

The rest of this page runs from your chosen variant's Terraform directory. Set it once:

```bash
export TF_DIR=../../set-up-cluster/terraform/auto-mode   # or .../karpenter
```

## Provision the file system

Lustre lives in a single subnet, which should be in the same AZ as the GPU nodes that will mount it. Pick a private subnet (tagged `karpenter.sh/discovery=<cluster>`) in that AZ:

```bash
# A private subnet in the AZ where your GPU capacity lives (adjust the AZ):
export FSX_SUBNET_ID=$(aws ec2 describe-subnets \
 --filters "Name=tag:karpenter.sh/discovery,Values=ai-eks-docs" "Name=availability-zone,Values=us-east-2a" \
 --query 'Subnets[0].SubnetId' --output text)
echo "FSx subnet: $FSX_SUBNET_ID"

Apply with `enable_fsx=true`. The default is the smallest EFA-enabled file system (4800 GiB) at the top throughput tier (1000 MB/s/TiB):

```bash
terraform -chdir="$TF_DIR" apply \
  -var 'enable_fsx=true' \
  -var "subnet_id=$FSX_SUBNET_ID"
```

To size up, raise the capacity (more OSTs) and/or drop the tier - each lower `per_unit_storage_throughput` requires more capacity:

```bash
terraform -chdir="$TF_DIR" apply \
  -var 'enable_fsx=true' \
  -var "subnet_id=$FSX_SUBNET_ID" \
  -var 'storage_capacity=9600' \
  -var 'per_unit_storage_throughput=1000'
```

The file system takes ~10-30 minutes to reach `AVAILABLE`. Terraform creates the CSI driver add-on and the static PV/PVC as part of the same apply.

> **`PERSISTENT_2` capacity errors.** *"Your filesystem failed to create due to insufficient capacity"* is a real AWS-side, **per-AZ** signal for the throughput tier you requested - lowering `storage_capacity` does not help. The top tier (`per_unit_storage_throughput=1000`) is the most constrained. Retry with a lower tier (`500`/`250`/`125`) - raising `storage_capacity` to that tier's minimum (up to 38400 GiB at 125) - pick a subnet in another AZ (trading GPU-node locality), or wait and retry. If the file system reaches `FAILED`, delete it (`aws fsx delete-file-system --file-system-id <id>`) - a `FAILED` file system does not bill but is left behind - and if the failed apply recorded it in state, run `terraform state rm 'aws_fsx_lustre_file_system.this[0]'` before retrying.

Verify the PVC bound (the static PV binds it by `volumeName`):

```bash
terraform -chdir="$TF_DIR" output fsx_file_system_id
kubectl get pvc fsx-lustre-claim -n default
```

Expected output (capacity reflects your `storage_capacity`; `4800Gi` by default):

```
NAME               STATUS   VOLUME          CAPACITY   ACCESS MODES
fsx-lustre-claim   Bound    fsx-lustre-pv   4800Gi     RWX
```

Confirm the CSI driver registered:

```bash
kubectl get csidriver fsx.csi.aws.com
kubectl get pods -n kube-system -l app=fsx-csi-controller
```

## Test end-to-end

`fsx-lustre-test.yaml` runs two Jobs on the built-in `general-purpose` NodePool (no GPU, so it does not touch reserved GPU capacity):

- **writer** - mounts the claim, writes a marker file, benchmarks throughput with `fio`, and inspects Lustre striping.
- **reader** - mounts the *same* claim on a different node and reads the marker back, proving `ReadWriteMany` shared access.

```bash
kubectl apply -f fsx-lustre-test.yaml
kubectl logs -f job/fsx-lustre-writer    # mount, fio benchmark, lfs checks
kubectl logs -f job/fsx-lustre-reader    # cross-node read-back
```

The writer's mount line should show a `lustre` type over `@tcp`, e.g.:

```
100.64.59.94@tcp:/iatcdb4v   4.5T  7.5M   4.5T   1% /data
```

and a quick single-job `fio` write should report roughly the per-OST rate (~1 GB/s):

```
WRITE: bw=988MiB/s (1036MB/s), io=1024MiB (1074MB), run=1036-1036msec
```

The reader logs `SUCCESS: reader on <node> read data written by another pod.` Both Jobs reach `Complete`:

```bash
kubectl get jobs -l app=fsx-lustre-test
```

```
NAME                STATUS     COMPLETIONS   DURATION
fsx-lustre-reader   Complete   1/1           1m
fsx-lustre-writer   Complete   1/1           2m
```

### Interpreting throughput

- A single-job sequential write is limited by one OST (~1 GB/s here).
- Scaling `--numjobs` spreads writes across OSTs; aggregate rises toward the baseline until OST count or the throughput tier caps it.
- Very high `--numjobs` on a small (few-OST) filesystem can *reduce* throughput from lock contention on a shared OST. If you need more, add capacity (more OSTs) or raise the tier - not just more jobs.

To use Lustre from a real workload, mount `fsx-lustre-claim` into the pod (`ReadWriteMany`, so many pods share it) at your dataset/checkpoint path.

## Troubleshooting

**PVC stuck `Pending`.** The PV binds by `volumeName`; confirm the filesystem is `AVAILABLE` and the CSI controller is running:

```bash
terraform -chdir="$TF_DIR" output fsx_file_system_id
aws fsx describe-file-systems --query 'FileSystems[0].Lifecycle' --output text
kubectl get pods -n kube-system -l app=fsx-csi-controller
kubectl describe pvc fsx-lustre-claim -n default
```

**Pod stuck `ContainerCreating` / mount timeout.** Almost always the security group. FSx needs Lustre ports **988** and **1018-1023** reachable between the nodes and the filesystem. This cluster attaches the `shared` SG (which the filesystem also uses) to nodes, and its self-ingress rule is all-protocols (`-1`), so this is covered by default. If you changed the SG, re-add the rules:

```bash
SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:karpenter.sh/discovery,Values=ai-eks-docs" \
  --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 988       --source-group "$SG"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 1018-1023 --source-group "$SG"
```

**Confirm the mount from inside a pod:**

```bash
POD=$(kubectl get pod -l app=fsx-lustre-test,role=writer -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- df -hT /data
kubectl exec "$POD" -- mount | grep lustre
```

Expected: a `lustre` filesystem type with a `<ip>@tcp:/<mountname>` source.

**AZ mismatch.** If mounts hang and the filesystem and nodes are in different AZs, Lustre traffic is crossing AZs (or blocked). Keep the `subnet_id` in the same AZ as the GPU nodes.

## Cleanup

Remove the test (leaves the filesystem in place):

```bash
kubectl delete -f fsx-lustre-test.yaml
```

The PV uses a `Retain` reclaim policy, so the filesystem is not deleted by removing Kubernetes objects. To destroy the filesystem, CSI driver, and PV/PVC, re-apply with `enable_fsx=false` (keeping the other vars) or `terraform destroy`:

```bash
terraform -chdir="$TF_DIR" apply -var 'enable_fsx=false' -var "subnet_id=$FSX_SUBNET_ID"
```
