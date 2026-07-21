## Static P6-B200 NodePool with EFA + MPI NCCL test

Terraform and manifests for running a static, reservation-backed `p6-b200.48xlarge` NodePool with EFA networking on the self-managed Karpenter cluster plus the MPI
Operator install and a distributed NCCL test adapted for B200s.

### Prerequisites

- An existing On-Demand Capacity Reservation or Capacity Block for `p6-b200.48xlarge`.

Look up its ID and export it as `CAPACITY_RESERVATION_ID` (used later when applying the
EC2NodeClass):

```bash
export CAPACITY_RESERVATION_ID=$(aws ec2 describe-capacity-reservations \
  --region ap-south-1 \
  --filters "Name=state,Values=active" "Name=instance-type,Values=p6-b200.48xlarge" "Name=availability-zone,Values=ap-south-1c" \
  --query 'CapacityReservations[0].CapacityReservationId' \
  --output text)

echo "Capacity Reservation ID: $CAPACITY_RESERVATION_ID"
```

Expected output:

```
Capacity Reservation ID: cr-xxxxxxxxxxxxxxxxx
```

### Deploy the cluster

```bash
cd terraform/karpenter
terraform init
terraform apply -var 'region=ap-south-1'
```

Configure `kubectl`:

```bash
aws eks update-kubeconfig --region ap-south-1 --name ai-eks-docs --alias ai-eks-docs
```

### Apply the EC2NodeClass and NodePool

`nodeclass-gpu-static.yaml` uses `${CLUSTER_NAME}`, `${KARPENTER_NODE_ROLE}`, and
`${CAPACITY_RESERVATION_ID}` as template variables. `CAPACITY_RESERVATION_ID` is already exported
from the Prerequisites step above; set the remaining two and substitute with `envsubst`:

```bash
export CLUSTER_NAME=ai-eks-docs
export KARPENTER_NODE_ROLE=$(terraform -chdir=terraform/karpenter output -raw node_iam_role_name)
```

Preview the substituted manifest before applying it, to confirm all three variables resolved
(no leftover `${...}` placeholders):

```bash
envsubst < nodeclass-gpu-static.yaml | cat
```

Once it looks right, apply it:

```bash
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

Nodes provision once the NodePool's `replicas: 4` triggers launches into the reservation. Check the
NodeClaims for launch status - this is usually where the real error shows up (insufficient
capacity, IAM issues, reservation ID mismatch, etc.):

```bash
kubectl get nodeclaims -o wide
kubectl describe nodeclaim -l karpenter.sh/nodepool=gpu-static
```

Check Karpenter logs for progress:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep gpu-static
```

#### Verify EFA device plugin is installed

```bash
kubectl get daemonset -n kube-system efa-aws-efa-k8s-device-plugin
```

Check that nodes have allocatable EFA resources (8 per `p6-b200.48xlarge` node, matching the 8
`efa-only` interfaces in the NodeClass):

```bash
kubectl get nodes -o custom-columns="NAME:.metadata.name,EFA:.status.allocatable.vpc\.amazonaws\.com/efa"
```

Expected output:

```
NAME                                          EFA
ip-10-0-xx-xx.us-east-2.compute.internal      8
```

#### Verify MPI Operator is installed

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

`mpijob-nccl.yaml` runs `all_reduce_perf` over EFA across 4 worker pods (`p6-b200.48xlarge`,
8 GPUs each = 32 GPUs total), matching the static NodePool's `replicas: 4`:

```bash
kubectl apply -f mpijob-nccl.yaml
```

Follow the launcher logs:

```bash
kubectl logs -f -l training.kubeflow.org/job-role=launcher
```

### GPU Monitoring

The Terraform stack deploys a full GPU monitoring pipeline:

- **DCGM Exporter** on GPU nodes (scrapes NVIDIA driver metrics via NVML)
- **kube-prometheus-stack** with remote write to Amazon Managed Prometheus
- **Grafana** with pre-loaded NVIDIA DCGM dashboard

#### Verify monitoring is working

```bash
# Check DCGM exporter pods are running on GPU nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=dcgm-exporter -o wide

# Check Prometheus is scraping DCGM
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets — dcgm-exporter should show as UP
```

Query available GPU metrics in Prometheus or Grafana Explore:

```promql
DCGM_FI_DEV_GPU_TEMP
DCGM_FI_DEV_GPU_UTIL
DCGM_FI_DEV_FB_USED
DCGM_EXP_XID_ERRORS_COUNT
DCGM_FI_DEV_ECC_DBE_VOL_TOTAL
```

Access Grafana:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Get admin password
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Login with `admin` / the password from above. The NVIDIA DCGM dashboard is in the
"GPU Monitoring" folder.

### GPU Health Detection, Node Repair, and XID Fault Injection Testing

See [`../manifests/xid-injection/README.md`](../manifests/xid-injection/README.md) for GPU health
detection background, node repair behavior, and how to simulate XID errors to test both.

### Cleanup

```bash
kubectl delete -f mpijob-nccl.yaml
kubectl delete -f mpijob-nccl-2.yaml
kubectl delete -f nodepool-gpu-static.yaml
kubectl delete -f nodeclass-gpu-static.yaml
```

Deleting the NodePool drains and terminates the reserved nodes; the reservation itself is not
deleted (it keeps billing until you release it in the EC2 console/CLI).
