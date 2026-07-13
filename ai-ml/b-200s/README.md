## Static P6-B200 NodePool with EFA + MPI NCCL test

Manifests for running a static, reservation-backed `p6-b200.48xlarge` NodePool with EFA
networking on the self-managed Karpenter cluster from
[`set-up-cluster/terraform/karpenter/`](../set-up-cluster/terraform/karpenter/), plus the MPI
Operator install and a distributed NCCL test adapted for B200. Adapted from the
[fine-tuning P5 EFA walkthrough](https://github.com/awslabs/ai-on-eks) (`fine-tuning/karpenter/tf/README.md`).

- `nodeclass-gpu-static.yaml` - EC2NodeClass selecting an existing capacity reservation by ID, with
  EFA network interfaces for `p6-b200.48xlarge` (1 primary ENA + 8 EFA-only, one per network card).
- `nodepool-gpu-static.yaml` - Static NodePool (`replicas: 4`) pinned to `p6-b200.48xlarge`,
  constrained to reserved capacity via the NodeClass above.
- `mpijob-b200-efa.yaml` - MPIJob running a multi-node `all_reduce_perf` NCCL test over EFA across
  4 worker pods (32 GPUs total).

### Prerequisites

- Cluster deployed from `set-up-cluster/terraform/karpenter/`.
- An existing On-Demand Capacity Reservation or Capacity Block for `p6-b200.48xlarge` (see the
  `reservation.id` option in [`../set-up-cluster/terraform/README.md`](../set-up-cluster/terraform/README.md)).

### Apply the EC2NodeClass and NodePool

`nodeclass-gpu-static.yaml` uses `${CLUSTER_NAME}`, `${KARPENTER_NODE_ROLE}`, and
`${CAPACITY_RESERVATION_ID}` as template variables. Set them and substitute with `envsubst`:

```bash
export CLUSTER_NAME=ai-eks-docs
export KARPENTER_NODE_ROLE=$(terraform -chdir=../set-up-cluster/terraform/karpenter output -raw node_iam_role_name)
export CAPACITY_RESERVATION_ID=cr-xxxxxxxxxxxxxxxxx

envsubst < nodeclass-gpu-static.yaml | kubectl apply -f -
kubectl apply -f nodepool-gpu-static.yaml
```

### Verify

```bash
kubectl get ec2nodeclass gpu-static
kubectl get nodepool gpu-static
```

Expected output:

```
NAME         READY
gpu-static   True

NAME         NODECLASS    NODES   READY
gpu-static   gpu-static   4       True
```

Nodes provision once the NodePool's `replicas: 4` triggers launches into the reservation (5-10
minutes). Check Karpenter logs for progress:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep gpu-static
```

### Install MPI Operator

MPI Operator is an open-source Kubernetes controller from Kubeflow that manages distributed MPI
jobs by automating worker pod creation, SSH setup, and `mpirun` orchestration across nodes. To
validate multi-instance EFA networking, we need to run a distributed NCCL test
(`all_reduce_perf`) across multiple GPU nodes, which requires MPI to coordinate the communication
between workers, and the MPI Operator handles that orchestration on Kubernetes.

> [!NOTE]
> There is no official Helm chart for MPI Operator, only community-maintained (outdated) charts.
> Kubeflow recommends `kubectl apply`. See the
> [MPI Operator GitHub repo](https://github.com/kubeflow/mpi-operator) for details.

Install the latest release (v0.8.0) directly from the Kubeflow repo:

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.8.0/deploy/v2beta1/mpi-operator.yaml
```

This installs the operator and the `MPIJob` CRD (`mpijobs.kubeflow.org`) used to run distributed
MPI workloads on Kubernetes.

#### Verify installation

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

### Run the NCCL test

`mpijob-b200-efa.yaml` runs `all_reduce_perf` over EFA across 4 worker pods (`p6-b200.48xlarge`,
8 GPUs each = 32 GPUs total), matching the static NodePool's `replicas: 4`.

```bash
kubectl apply -f mpijob-b200-efa.yaml
```

Follow the launcher logs:

```bash
kubectl logs -f -l training.kubeflow.org/job-role=launcher
```

> The container image (`public.ecr.aws/hpc-cloud/efa:b200`) is a placeholder - swap in an
> image with NCCL/EFA libraries built for B200 if a published one differs.

### Cleanup

```bash
kubectl delete -f mpijob-b200-efa.yaml
kubectl delete -f nodepool-gpu-static.yaml
kubectl delete -f nodeclass-gpu-static.yaml
```

Deleting the NodePool drains and terminates the reserved nodes; the reservation itself is not
deleted (it keeps billing until you release it in the EC2 console/CLI).
