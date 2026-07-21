# XID Fault Injection Testing

Manifests and a script for testing GPU error detection and node repair on EKS, by simulating
NVIDIA XID errors without needing a real hardware fault.

Reference: https://docs.aws.amazon.com/eks/latest/userguide/node-health-nma.html

## Background: GPU health detection and node repair

The EKS node monitoring agent (`eks-node-monitoring-agent` addon) monitors GPU health via DCGM
and sets the `AcceleratedHardwareReady` node condition. Karpenter's `nodeRepair` feature gate (or
EKS Auto Mode's built-in equivalent) watches this condition and replaces nodes after a 10-minute
toleration.

Detection path:

```
NVIDIA Driver → DCGM Host Engine (nv-hostengine) → Policy Violation Channel → Monitoring Agent → Node Condition → Node Repair
```

### Prerequisites for GPU health monitoring

The `eks-node-monitoring-agent` addon must have the `dcgmAgent` toleration for GPU-tainted nodes.
Without it, the `dcgm-server` DaemonSet won't schedule on GPU nodes and the monitoring agent
cannot perform GPU health checks. This is already configured in
`../../set-up-cluster/terraform/{auto-mode,karpenter}/eks.tf`:

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

### Verify GPU health monitoring

```bash
# Check dcgm-server is running on GPU nodes
kubectl get ds dcgm-server -n kube-system

# Check node condition
kubectl get nodes -o custom-columns='NAME:.metadata.name,ACCELERATOR_READY:.status.conditions[?(@.type=="AcceleratedHardwareReady")].status,REASON:.status.conditions[?(@.type=="AcceleratedHardwareReady")].reason'

# Check for XID events
kubectl get events -A | grep -i NvidiaXID
```

### Node repair behavior

- Watches `AcceleratedHardwareReady=False` with a **10-minute toleration**
- Bypasses disruption budgets (forceful repair)
- Safety: will not repair if >20% of NodePool nodes are unhealthy (rounds up, so 1 unhealthy out
  of 1 total is allowed)

### NVIDIA XID codes and repair actions

The monitoring agent detects XID errors from the NVIDIA driver via DCGM. Well-known critical XIDs
set `AcceleratedHardwareReady=False` and trigger auto repair. Non-critical XIDs are logged as
Kubernetes events only.

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

## Injection methods

### DCGM injection (recommended - works for any XID code)

The most reliable method is injecting directly into DCGM's field cache via `dcgmi`. This uses the
same detection path as real hardware faults and works for any XID code, including critical ones
that trigger node repair.

Reference: https://github.com/jicowan/hma-cli/blob/main/pkg/simulator/accelerator/nvidia.go#L92

`xid-dcgmi-inject.yaml` documents the commands to run (it prints usage from a pod, but the actual
injection runs from your workstation against the `dcgm-server` pod):

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

### CUDA fault injection (triggers driver errors)

`xid-cuda-fault.yaml` triggers XID 13 via illegal memory access. This is a real driver fault but
only produces a non-critical warning event.

```bash
kubectl apply -f xid-cuda-fault.yaml
kubectl logs -f xid-cuda-fault

# Verify
kubectl get events -A | grep NvidiaXID
# Expected: NvidiaXID13Warning: detected unknown XID-13 on the instance
```

### Kernel log injection (dmesg only - NOT detected by DCGM)

`xid.sh` writes XID-formatted messages to `/dev/kmsg`. These appear in dmesg but are **not
detected by DCGM or the monitoring agent**, because the detection path is purely through the DCGM
API, not kernel log parsing. Useful only for testing dmesg-based tooling you control.

```bash
sudo ./xid.sh xid 13 0   # inject XID 13 for GPU 0
sudo ./xid.sh sxid 1     # inject SXID 1
sudo ./xid.sh both       # inject both (default XID 13, SXID 1)
```

`journal-check.yaml` is a debugging pod that reads the host's journal/dmesg to confirm whether an
injected message actually landed in the kernel log, useful when validating `xid.sh` injections.

```bash
kubectl apply -f journal-check.yaml
kubectl logs journal-check
```

## Observing the full repair cycle

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

## Cleanup

```bash
kubectl delete pod xid-cuda-fault journal-check xid-dcgmi-inject 2>/dev/null
```
