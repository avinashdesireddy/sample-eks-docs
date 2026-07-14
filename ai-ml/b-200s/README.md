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

### GPU Health Detection and Node Repair

The EKS node monitoring agent (`eks-node-monitoring-agent` addon) monitors GPU health
via DCGM and sets the `AcceleratedHardwareReady` node condition. Karpenter's `nodeRepair`
feature gate watches this condition and replaces nodes after a 10-minute toleration.

Detection path:

```
NVIDIA Driver → DCGM Host Engine (nv-hostengine) → Policy Violation Channel → Monitoring Agent → Node Condition → Karpenter Repair
```

#### Prerequisites for GPU health monitoring

The `eks-node-monitoring-agent` addon must have the `dcgmAgent` toleration for GPU-tainted
nodes. This is configured in `eks.tf`:

```hcl
eks-node-monitoring-agent = {
  configuration_values = jsonencode({
    dcgmAgent = {
      tolerations = [{
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      }]
    }
  })
}
```

Without this, the `dcgm-server` DaemonSet won't schedule on GPU nodes and the monitoring
agent cannot perform GPU health checks.

#### Verify GPU health monitoring

```bash
# Check dcgm-server is running on GPU nodes
kubectl get ds dcgm-server -n kube-system

# Check node condition
kubectl get nodes -o custom-columns='NAME:.metadata.name,ACCELERATOR_READY:.status.conditions[?(@.type=="AcceleratedHardwareReady")].status,REASON:.status.conditions[?(@.type=="AcceleratedHardwareReady")].reason'

# Check for XID events
kubectl get events -A | grep -i NvidiaXID
```

#### Karpenter node repair behavior

- Watches `AcceleratedHardwareReady=False` with **10-minute toleration**
- Bypasses disruption budgets (forceful repair)
- Safety: will not repair if >20% of NodePool nodes are unhealthy (rounds up,
  so 1 unhealthy out of 1 total is allowed)

#### NVIDIA XID codes and repair actions

The monitoring agent detects XID errors from the NVIDIA driver via DCGM. Well-known
critical XIDs set `AcceleratedHardwareReady=False` and trigger auto repair. Non-critical
XIDs are logged as Kubernetes events only.

Full reference: https://docs.aws.amazon.com/eks/latest/userguide/node-health-nma.html

**Reboot action XIDs:**

| XID | Description |
|-----|-------------|
| 46 | GPU stopped processing |
| 48 | Double Bit ECC Error |
| 54 | Auxiliary power not connected |
| 62 | Internal micro-controller halt |
| 63 | GPU memory remapping event |
| 95 | Uncontained memory error |
| 109 | Context switch timeout |
| 110 | Security fault error |
| 136 | Link training failed |
| 140 | ECC Unrecovered Error |
| 143 | GPU initialization error |
| 155 | NVLink software-defined error |
| 156 | Resource retirement event |
| 158 | GPU fatal timeout |

**Replace action XIDs:**

| XID | Description |
|-----|-------------|
| 64 | GPU memory remapping failure |
| 74 | NVLink Error |
| 79 | GPU has fallen off the bus |
| 119 | GSP RPC Timeout |
| 120 | GSP Error |
| 142 | NVENC3 Error (GB200) |
| 151 | Key rotation error (H100/B100/GB200) |

### XID Fault Injection Testing

The `xid-injection/` folder contains tools for testing GPU error detection and node repair.

Reference: https://docs.aws.amazon.com/eks/latest/userguide/node-health-nma.html

#### DCGM injection (recommended — works for any XID code)

The most reliable method is injecting directly into DCGM's field cache via `dcgmi`. This
uses the same detection path as real hardware faults and works for any XID code including
critical ones that trigger node repair.

Reference: https://github.com/jicowan/hma-cli/blob/main/pkg/simulator/accelerator/nvidia.go#L92

```bash
# Find the dcgm-server pod on the GPU node
DCGM_POD=$(kubectl get pods -n kube-system -l k8s-app=dcgm-server -o jsonpath='{.items[0].metadata.name}')

# Inject XID 79 (Replace action) — field 230 = xid_errors
kubectl exec -n kube-system $DCGM_POD -- dcgmi test --inject --gpuid 0 -f 230 -v 79
```

**Simulate node replacement (XID 79):**

```bash
kubectl exec -n kube-system $DCGM_POD -- dcgmi test --inject --gpuid 0 -f 230 -v 79
# XID 79 = GPU has fallen off the bus → Replace
```

**Simulate node reboot (XID 48):**

```bash
kubectl exec -n kube-system $DCGM_POD -- dcgmi test --inject --gpuid 0 -f 230 -v 48
# XID 48 = Double Bit ECC Error → Reboot
```

**Simulate warning event (XID 13):**

```bash
kubectl exec -n kube-system $DCGM_POD -- dcgmi test --inject --gpuid 0 -f 230 -v 13
# XID 13 = Graphics Engine Exception → Warning event only
```

Verify detection:

```bash
# Check events (appears within 30 seconds)
kubectl get events -A | grep NvidiaXID

# Check node condition
kubectl describe node <gpu-node> | grep -A3 AcceleratedHardwareReady
# Expected: False / DCGMHealthCode120 with "detected XID-79"
```

#### CUDA fault injection (triggers driver errors)

`xid-cuda-fault.yaml` triggers XID 13 via illegal memory access. This is a real driver
fault but only produces a non-critical warning event.

```bash
kubectl apply -f xid-injection/xid-cuda-fault.yaml
kubectl logs -f xid-cuda-fault

# Verify
kubectl get events -A | grep NvidiaXID
# Expected: NvidiaXID13Warning: detected unknown XID-13 on the instance
```

#### Observing the full repair cycle

After a critical XID sets `AcceleratedHardwareReady=False`:

```bash
# Watch Karpenter detect and repair (10-minute toleration)
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f | grep -iE "repair|health|unhealthy|terminat"

# Watch NodeClaim replacement
kubectl get nodeclaims -w

# Watch node condition
kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="AcceleratedHardwareReady")].status,REASON:.status.conditions[?(@.type=="AcceleratedHardwareReady")].reason' -w
```

Expected sequence:
1. Critical XID detected → `AcceleratedHardwareReady=False`
2. 10 minutes pass (toleration period)
3. Karpenter: `deleting unhealthy node`
4. Node tainted with `karpenter.sh/disrupted:NoSchedule`
5. New NodeClaim created → replacement node launches
6. Old node terminated

#### Kernel log injection (dmesg only — NOT detected by DCGM)

`xid.sh` writes XID-formatted messages to `/dev/kmsg`. These appear in dmesg but are
**NOT detected by DCGM or the monitoring agent** because the detection path is purely
through the DCGM API, not kernel log parsing.

Useful only for testing dmesg-based tooling you control:


#### Cleanup

```bash
kubectl delete pod xid-cuda-fault journal-check 2>/dev/null
```

### Cleanup

```bash
kubectl delete -f mpijob-nccl.yaml
kubectl delete -f mpijob-nccl-2.yaml
kubectl delete -f nodepool-gpu-static.yaml
kubectl delete -f nodeclass-gpu-static.yaml
```

Deleting the NodePool drains and terminates the reserved nodes; the reservation itself is not
deleted (it keeps billing until you release it in the EC2 console/CLI).
