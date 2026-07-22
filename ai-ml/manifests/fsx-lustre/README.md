# FSx for Lustre on EKS Auto Mode

Provision and test a high-throughput, shared [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html) file system for GPU workloads on the **EKS Auto Mode** cluster (`../../set-up-cluster/terraform/auto-mode/`). The file system, the FSx CSI driver, and a static `PersistentVolume`/`PersistentVolumeClaim` are provisioned by Terraform behind `enable_fsx`; this directory holds the end-to-end mount + throughput test.

Lustre gives the cluster a POSIX, `ReadWriteMany` filesystem that many GPU pods mount at once - the natural home for training datasets, checkpoints, and shared scratch. It is an optional accelerator: the inference path in [`../inference/`](../inference/) runs off the S3 model bucket and does not need Lustre.

## EFA acceleration: Auto Mode vs. Karpenter

FSx for Lustre can serve clients over two transports:

- **TCP** - the standard path. The FSx CSI driver mounts the filesystem into pods over TCP. No node configuration required.
- **EFA (RDMA)** - higher bandwidth / lower latency, but the node must run the EFA-enabled Lustre client, installed by a `userData` bootstrap script (`install-fsx-lustre-client.sh --install-lustre --install-efa`).

**EKS Auto Mode manages node bootstrap and does not support `userData`**, so Auto Mode nodes mount Lustre **over TCP via the CSI driver** - which is exactly what the Terraform here provisions and what this test exercises. The node-level EFA-accelerated client is only available on the self-managed **Karpenter** variant, where the `EC2NodeClass` can carry the bootstrap script. `EfaEnabled` is still set on the filesystem (required for PERSISTENT_2 with automatic metadata), but Auto Mode clients will not use the EFA transport.

> If you need EFA-accelerated Lustre, use the Karpenter variant (`../../set-up-cluster/terraform/karpenter/`) whose `EC2NodeClass` supports the `userData` client install.

## How Lustre throughput works

A Lustre filesystem has three server-side components:

- **MDS** (Metadata Server) - file names, directories, permissions.
- **OSS** (Object Storage Server) - serves file data.
- **OST** (Object Storage Target) - the disk volume attached to an OSS. Files are **striped** across OSTs, so more OSTs = more parallel I/O paths = more throughput.

On FSx PERSISTENT_2, FSx creates **1 OST per 2400 GiB** of capacity, and each OST does roughly 4-5 GiB/s. So **capacity determines the throughput ceiling**, and `per_unit_storage_throughput` (125/250/500/1000 MB/s/TiB) sets the per-TiB baseline. Aggregate baseline = `per_unit_storage_throughput x (storage_capacity / 1024)` MB/s. Example: 125 MB/s/TiB over 38.4 TiB (the EFA minimum) ≈ 4.8 GB/s baseline across 16 OSTs.

## Prerequisites

- The Auto Mode cluster deployed (see [`../../set-up-cluster/terraform/README.md`](../../set-up-cluster/terraform/README.md)) and `kubectl` configured:

  ```bash
  aws eks update-kubeconfig --region us-east-2 --name ai-eks-docs --alias ai-eks-docs
  ```

## Provision the file system

From the Auto Mode Terraform directory. Lustre lives in a single subnet, which should be in the same AZ as the GPU nodes that will mount it. Pick a private subnet (tagged `karpenter.sh/discovery=<cluster>`) in that AZ:

```bash
cd ../../set-up-cluster/terraform/auto-mode

# A private subnet in the AZ where your GPU capacity lives (adjust the AZ):
export FSX_SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:karpenter.sh/discovery,Values=ai-eks-docs" "Name=availability-zone,Values=us-east-2a" \
  --query 'Subnets[0].SubnetId' --output text)
echo "FSx subnet: $FSX_SUBNET_ID"
```

Apply with `enable_fsx=true`. The default is the EFA-enabled minimum (38400 GiB) at the lowest throughput tier (125 MB/s/TiB), which is the most likely to have capacity:

```bash
terraform apply \
  -var 'enable_fsx=true' \
  -var "subnet_id=$FSX_SUBNET_ID"
```

To push throughput, raise the tier and/or capacity (more OSTs):

```bash
terraform apply \
  -var 'enable_fsx=true' \
  -var "subnet_id=$FSX_SUBNET_ID" \
  -var 'storage_capacity=76800' \
  -var 'per_unit_storage_throughput=1000'
```

The file system takes ~10-30 minutes to reach `AVAILABLE`. Terraform creates the CSI driver add-on and the static PV/PVC as part of the same apply.

> **`PERSISTENT_2` capacity errors.** *"Your filesystem failed to create due to insufficient capacity"* is a real AWS-side, **per-AZ** signal for the throughput tier you requested - lowering `storage_capacity` does not help. The top tier (`per_unit_storage_throughput=1000`) is the most constrained. Retry with a lower tier (`500`/`250`/`125`), pick a subnet in another AZ (trading GPU-node locality), or wait and retry. If the file system reaches `FAILED`, delete it (`aws fsx delete-file-system --file-system-id <id>`) - a `FAILED` file system does not bill but is left behind - and if the failed apply recorded it in state, run `terraform state rm 'aws_fsx_lustre_file_system.this[0]'` before retrying.

### Find capacity across AZs

There is **no AWS API to pre-check FSx physical capacity** - the only way to know is to attempt `CreateFileSystem` and wait ~5-10 min for `AVAILABLE` vs `FAILED`. And FSx for Lustre uses a **single subnet**, so there is no native multi-AZ and a single Terraform resource cannot fall back on its own. `find-fsx-capacity.sh` does probe-and-fallback: it tries each candidate subnet, waits for the result, deletes the file system if it `FAILED`, and stops on the first success - printing the winning subnet and file system id.

```bash
SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:karpenter.sh/discovery,Values=ai-eks-docs" \
  --query 'SecurityGroups[0].GroupId' --output text)

# Probe one discovery-tagged subnet per AZ (defaults: 38400 GiB @ 125 MB/s/TiB).
# Run from the Terraform dir (terraform/auto-mode); the script lives in set-up-cluster/scripts/:
../../scripts/find-fsx-capacity.sh \
  --region us-east-2 --cluster ai-eks-docs --security-group-id "$SG"
```

On success it prints:

```
FSX_SUBNET_ID=subnet-...
FSX_AZ=us-east-2b
FSX_FILE_SYSTEM_ID=fs-...
FSX_DNS_NAME=fs-....fsx.us-east-2.amazonaws.com
FSX_MOUNT_NAME=abcd1234
```

The winning file system is EFA-enabled and identical to what `fsx-lustre.tf` builds, so **adopt it into Terraform** rather than letting Terraform create a second one (and re-gamble on capacity). Import it, then apply with the same vars so Terraform reconciles it and creates the CSI add-on + PV/PVC around it:

```bash
cd ../../set-up-cluster/terraform/auto-mode
terraform import \
  -var 'enable_fsx=true' -var "subnet_id=<FSX_SUBNET_ID from above>" \
  'aws_fsx_lustre_file_system.this[0]' <FSX_FILE_SYSTEM_ID from above>

terraform apply -var 'enable_fsx=true' -var "subnet_id=<FSX_SUBNET_ID>"
```

> The import must use the **same `storage_capacity` / `per_unit_storage_throughput`** you passed to the script (defaults match `fsx-lustre.tf`), or Terraform will plan a replacement.

Verify:

```bash
terraform output fsx_file_system_id
kubectl get pvc fsx-lustre-claim -n default
```

Expected output:

```
NAME               STATUS   VOLUME          CAPACITY   ACCESS MODES
fsx-lustre-claim   Bound    fsx-lustre-pv   38400Gi    RWX
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
100.64.59.94@tcp:/iatcdb4v   38T  7.5M   38T   1% /data
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
terraform -chdir=../../set-up-cluster/terraform/auto-mode output fsx_file_system_id
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
cd ../../set-up-cluster/terraform/auto-mode
terraform apply -var 'enable_fsx=false' -var "subnet_id=$FSX_SUBNET_ID"
```
