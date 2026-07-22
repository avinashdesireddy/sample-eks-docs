# Static p6-b200.48xlarge NodePool with EFA + MPI NCCL test (EKS Auto Mode)

Manifests for a static, reservation-backed `p6-b200.48xlarge` NodePool with EFA networking on the **EKS Auto Mode** cluster (`../../`), plus a distributed NCCL test over EFA. This is the Auto Mode counterpart to `../../../karpenter/nodepools/b-200s-static` - it uses the Auto Mode managed `NodeClass` (`eks.amazonaws.com/v1`) and a [static capacity NodePool][static-capacity] (`spec.replicas`) instead of the self-managed Karpenter `EC2NodeClass`.

This is **not** wired into `var.nodepools` like the other strategy folders - it's applied manually with `kubectl` against an **existing** On-Demand Capacity Reservation or Capacity Block, since Terraform has no way to create a Capacity Block for a specific instance type/date on your behalf. `var.enable_efa` still needs to be `true` on the cluster (installs the EFA device plugin and MPI Operator - see `../../README.md`).

## What's different from the Karpenter version

EKS Auto Mode manages the AMI, instance store, and node bootstrap, so the fields the self-managed `EC2NodeClass` set for those (`amiSelectorTerms`, `instanceStorePolicy`, `userData`) are not valid on the Auto Mode `NodeClass` and have been dropped. The remaining changes:

- `NodeClass` uses `apiVersion: eks.amazonaws.com/v1`, `kind: NodeClass`.
- EFA `networkInterfaces` move under `spec.advancedNetworking`. When `networkInterfaces` is set, Auto Mode attaches no additional IPs/ENIs after launch, so the primary ENI declares pod IP capacity up front via `secondaryIPv4PrefixCount: 1` (a /28 = 16 pod IPs).
- The NodePool uses `spec.replicas` (static capacity) with `limits.nodes` (the only limit honored on a static pool). The Karpenter-only `karpenter.k8s.aws/capacity-reservation-type` requirement is dropped - Auto Mode targets the reservation via the NodeClass `capacityReservationSelectorTerms` plus `karpenter.sh/capacity-type: reserved` on the pool.

## Prerequisites

- The cluster deployed with `enable_efa=true` (see `../../README.md`):

  ```bash
  cd ../..    # into terraform/auto-mode
  terraform apply -var 'enable_efa=true'
  ```

- An existing On-Demand Capacity Reservation or Capacity Block for `p6-b200.48xlarge`.

Look up the reservation and export the values used later when applying the NodeClass and NCCL test:

```bash
export CAPACITY_RESERVATION_ID=$(aws ec2 describe-capacity-reservations \
  --region ap-south-1 \
  --filters "Name=state,Values=active" "Name=instance-type,Values=p6-b200.48xlarge" "Name=availability-zone,Values=ap-south-1c" \
  --query 'CapacityReservations[0].CapacityReservationId' \
  --output text)

export RESERVED_INSTANCE_COUNT=$(aws ec2 describe-capacity-reservations \
  --region ap-south-1 \
  --capacity-reservation-ids "$CAPACITY_RESERVATION_ID" \
  --query 'CapacityReservations[0].TotalInstanceCount' \
  --output text)

export GPUS_PER_INSTANCE=$(aws ec2 describe-instance-types \
  --region ap-south-1 \
  --instance-types p6-b200.48xlarge \
  --query 'InstanceTypes[0].GpuInfo.Gpus[0].Count' \
  --output text)

export TOTAL_GPU_COUNT=$((RESERVED_INSTANCE_COUNT * GPUS_PER_INSTANCE))

echo "Capacity Reservation ID: $CAPACITY_RESERVATION_ID"
echo "Reserved instances: $RESERVED_INSTANCE_COUNT"
echo "GPUs per instance: $GPUS_PER_INSTANCE"
echo "Total GPUs: $TOTAL_GPU_COUNT"
```

Expected output:

```
Capacity Reservation ID: cr-xxxxxxxxxxxxxxxxx
Reserved instances: 4
GPUs per instance: 8
Total GPUs: 32
```

`RESERVED_INSTANCE_COUNT` drives the NodePool's `replicas` and the NCCL test's worker count below;
`GPUS_PER_INSTANCE`/`TOTAL_GPU_COUNT` drive the per-worker and total GPU/EFA resource requests.

## Apply the NodeClass and NodePool

`nodeclass-gpu-static.yaml` and `nodepool-gpu-static.yaml` use `${CLUSTER_NAME}`, `${NODE_IAM_ROLE}`, `${CAPACITY_RESERVATION_ID}`, `${RESERVED_INSTANCE_COUNT}`, and `${NODE_LIMIT}` as template variables. `CAPACITY_RESERVATION_ID` and `RESERVED_INSTANCE_COUNT` are already exported from the Prerequisites step above; set the rest and substitute with `envsubst`:

```bash
export CLUSTER_NAME=ai-eks-docs
export NODE_IAM_ROLE=$(terraform -chdir=../.. output -raw node_iam_role_name)
# Allow one extra node above replicas for drift/AMI-update replacements.
export NODE_LIMIT=$((RESERVED_INSTANCE_COUNT + 1))
```

Preview the substituted manifests before applying them, to confirm all variables resolved (no leftover `${...}` placeholders):

```bash
envsubst < nodeclass-gpu-static.yaml | cat
envsubst < nodepool-gpu-static.yaml | cat
```

Once they look right, apply them:

```bash
envsubst < nodeclass-gpu-static.yaml | kubectl apply -f -
envsubst < nodepool-gpu-static.yaml | kubectl apply -f -
```

> **Access entry:** this custom `NodeClass` reuses the cluster's node IAM role (`node_iam_role_name`), for which EKS already creates an EC2 access entry with the `AmazonEKSAutoNodePolicy`. If you point the NodeClass at a _different_ role, create the access entry first - see [Create node class access entry][node-class-access].

## Verify

```bash
kubectl get nodeclass gpu-static
kubectl get nodepool gpu-static
```

Expected output:

```
NAME         READY
gpu-static   True

NAME         NODECLASS    NODES   READY
gpu-static   gpu-static   4       True
```

Nodes provision once the NodePool's `replicas` (= `$RESERVED_INSTANCE_COUNT`) triggers launches into the reservation. Check the NodeClaims for launch status - this is usually where the real error shows up (insufficient capacity, IAM issues, reservation ID mismatch, etc.):

```bash
kubectl get nodeclaims -o wide
kubectl describe nodeclaim -l karpenter.sh/nodepool=gpu-static
```

### Verify EFA device plugin is installed

```bash
kubectl get daemonset -n kube-system efa-aws-efa-k8s-device-plugin
```

Check that nodes have allocatable EFA resources (`$GPUS_PER_INSTANCE` per node, matching the 8 `efa-only` interfaces in the NodeClass):

```bash
kubectl get nodes -o custom-columns="NAME:.metadata.name,EFA:.status.allocatable.vpc\.amazonaws\.com/efa"
```

Expected output:

```
NAME                                          EFA
i-0xxxxxxxxxxxxxxxx                           8
```

### Verify MPI Operator is installed

```bash
kubectl get pods -n mpi-operator
```

Expected output:

```
NAME                            READY   STATUS    RESTARTS   AGE
mpi-operator-85f8599757-wz2gp   1/1     Running   0          41s
```

```bash
kubectl get crd | grep mpi
```

Expected output:

```
mpijobs.kubeflow.org
```

## Run the NCCL test

`mpijob-nccl.yaml` runs `all_reduce_perf` over EFA across `$RESERVED_INSTANCE_COUNT` worker pods (`p6-b200.48xlarge`, `$GPUS_PER_INSTANCE` GPUs each = `$TOTAL_GPU_COUNT` GPUs total), matching the static NodePool's `replicas`. It uses `${RESERVED_INSTANCE_COUNT}` and `${GPUS_PER_INSTANCE}` as template variables:

```bash
envsubst < mpijob-nccl.yaml | cat   # preview
```

```bash
envsubst < mpijob-nccl.yaml | kubectl apply -f -
```

The launcher pod runs on CPU general-purpose instance and the container image will download slower than on GPU instance with SOCI enabled.

Once the launcher pod in Running, follow the launcher logs:

```bash
kubectl logs -f -l training.kubeflow.org/job-role=launcher
```

## Cleanup

```bash
kubectl delete -f mpijob-nccl.yaml
kubectl delete -f nodepool-gpu-static.yaml
kubectl delete -f nodeclass-gpu-static.yaml
```

Deleting the NodePool drains and terminates the reserved nodes; the reservation itself is not deleted (it keeps billing until you release it in the EC2 console/CLI).

[static-capacity]: https://docs.aws.amazon.com/eks/latest/userguide/auto-static-capacity.html
[node-class-access]: https://docs.aws.amazon.com/eks/latest/userguide/create-node-class.html#_create_node_class_access_entry
