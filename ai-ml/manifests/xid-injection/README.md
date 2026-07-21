# XID Fault Injection Testing

Manifest for testing GPU error detection and automatic node repair on EKS, by simulating an NVIDIA XID error without needing a real hardware fault. Works on **EKS Auto Mode** and on **self-managed Karpenter / managed node groups**.

Reference: https://docs.aws.amazon.com/eks/latest/userguide/node-health-nma.html

## Background: GPU health detection and node repair

The EKS **node monitoring agent** detects GPU health issues via its DCGM component (`nv-hostengine`) and sets the `AcceleratedHardwareReady` node condition; EKS **automatic node repair** watches that condition and reboots or replaces the node after a default 10-minute wait. How the agent is packaged differs by cluster type, but in both cases its `nv-hostengine` is reachable at `localhost:5555` from a `hostNetwork` pod:

- **EKS Auto Mode** - the node monitoring agent is built into the node AMI and always on; there is no `eks-node-monitoring-agent` add-on to install and no `dcgm-server` pod.
- **Self-managed Karpenter / managed node groups** - install the `eks-node-monitoring-agent` add-on, which runs a dcgm-server DaemonSet containing nv-hostengine (reachable at localhost:5555 from hostNetwork pods or by exec'ing into the dcgm-server pod directly). On Karpenter it needs the `dcgmAgent` toleration to schedule on GPU-tainted nodes (configured in `../../set-up-cluster/terraform/karpenter/eks.tf`).

Note the two DCGM components serve different purposes:
- **Node monitoring agent** (health detection/repair) - includes its own `nv-hostengine`. This is what turns an XID error into a node condition.
- **dcgm-exporter** - the GPU Prometheus metrics exporter, installed separately by this repo's monitoring stack (pods in the `monitoring` namespace). It exports metrics and is not involved in node repair.

Detection path:
```
NVIDIA Driver → DCGM Host Engine (nv-hostengine) → Policy Violation Channel → Node Monitoring Agent → Node Condition → Node Repair
```

### Node repair behavior

- Watches `AcceleratedHardwareReady=False` with a **10-minute wait**.
- On EKS Auto Mode all `AcceleratedHardwareReady` repairs are **Replace**. On managed node groups some XIDs Reboot instead (see the table below).

### NVIDIA XID codes

Well-known critical XIDs set `AcceleratedHardwareReady=False` and trigger auto repair; non-critical XIDs are logged as Kubernetes events only. Full reference: https://docs.aws.amazon.com/eks/latest/userguide/node-health-nma.html

| XID | Description | Repair (managed node groups) |
|-----|-------------|------------------------------|
| 48 | Double Bit ECC Error | Reboot |
| 63 | GPU memory remapping event | Reboot |
| 95 | Uncontained memory error | Reboot |
| 109 | Context switch timeout | Reboot |
| 143 | GPU initialization error | Reboot |
| 64 | GPU memory remapping failure | Replace |
| 74 | NVLink Error | Replace |
| 79 | GPU has fallen off the bus | Replace |
| 119 | GSP RPC Timeout | Replace |
| 120 | GSP Error | Replace |
| 151 | Key rotation error (H100/B100/GB200) | Replace |

On EKS Auto Mode every well-known XID above results in **Replace** regardless of the "managed node group" column.

## Injection method

XID errors are detected through DCGM's **policy violation channel**, not by parsing kernel logs (source: [`aws/eks-node-monitoring-agent`](https://github.com/aws/eks-node-monitoring-agent), `monitors/nvidia/dcgm/dcgm_client.go` registers `dcgmapi.XidPolicy`). So the reliable simulation is injecting into DCGM's XID field (230) with `dcgmi test --inject`.

The node's host filesystem has no `dcgmi` binary, so `xid-inject.yaml` brings its own (from a DCGM image matching the agent's DCGM major version) and connects over host networking to the agent's `nv-hostengine` on `localhost:5555` - which works the same on Auto Mode (in-AMI agent) and Karpenter (`dcgm-server` DaemonSet with `hostPort 5555`).

```bash
# Set spec.nodeName to the target GPU node, then:
kubectl apply -f xid-inject.yaml
kubectl logs -f xid-inject
```

The pod injects one XID on one GPU, set via env vars (defaults `XID_CODE="79"`, `GPU_ID="0"`):

```yaml
env:
  - name: XID_CODE
    value: "79"    # 79 = GPU fell off the bus -> Replace
  - name: GPU_ID
    value: "0"
```

One critical XID on one GPU is a complete repair test - `AcceleratedHardwareReady` is a *node-level* condition, so the first critical XID already marks the whole node for replacement; injecting more XIDs or more GPUs adds nothing to the repair signal. For firing several codes (e.g. warning-only XIDs to exercise your event/alerting pipeline without replacing the node), use the on-demand

`kubectl exec` path below.

### Dynamic (on-demand) injection

The pod idles after its injection (`sleep 3600`), so it doubles as a live injection client. Exec into it to inject any XID into any GPU on demand - no YAML edits or re-apply. `dcgmi` defaults to `localhost:5555`, so pass no host flag (note `-h` means `--help`, not host):

```bash
kubectl exec -it xid-inject -- dcgmi test --inject --gpuid 0 -f 230 -v 79
# → Successfully injected field info.
```

To fire several codes (e.g. warning-only XIDs, which emit events but don't replace the node), loop from your workstation:

```bash
for xid in 13 31 43; do
  kubectl exec xid-inject -- dcgmi test --inject --gpuid 0 -f 230 -v $xid
done
```

> On Karpenter you can alternatively exec straight into the add-on's `dcgm-server` pod (`kubectl exec -n kube-system <dcgm-server-pod> -- dcgmi test --inject ...`) - the `xid-inject` pod is not required there, but it works identically and keeps one manifest for both cluster types.

### Verify detection

```bash
# Events (appear within ~30 seconds)
kubectl get events -A | grep NvidiaXID

# Node condition
kubectl get nodes -o custom-columns='NAME:.metadata.name,ACCEL:.status.conditions[?(@.type=="AcceleratedHardwareReady")].status,REASON:.status.conditions[?(@.type=="AcceleratedHardwareReady")].reason'
# Expected: False / NvidiaXID79Error
```

Verified result on a `p6-b200.48xlarge` node - injecting XID 79 produced:

```
AcceleratedHardwareReady  True → False  Reason: NvidiaXID79Error
Message: detected XID-79 on the instance, review kernel logs for additional information.
```

## Observing the full repair cycle

After a critical XID sets `AcceleratedHardwareReady=False`, repair kicks in after the 10-minute wait. How you observe it differs by cluster type.

### EKS Auto Mode

Node auto-repair is always on and fully managed - Karpenter runs in the AWS-managed control plane, so there is no `karpenter` controller pod to tail. Observe via node conditions, events, and NodeClaims:

```bash
# Watch the node condition flip to False, and NodeClaim replacement
kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="AcceleratedHardwareReady")].status,REASON:.status.conditions[?(@.type=="AcceleratedHardwareReady")].reason' -w
```

```bash 
kubectl get nodeclaims
kubectl get events -A --sort-by=.lastTimestamp | grep -iE "disrupt|unhealthy|terminat|NvidiaXID"
```

### Self-managed Karpenter

The Karpenter controller runs as a pod in `kube-system`, so you can tail it directly:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f | grep -iE "repair|health|unhealthy|terminat"
kubectl get nodeclaims -w
```

Expected sequence (both):
1. Critical XID detected → `AcceleratedHardwareReady=False`
2. 10 minutes pass (wait period)
3. Repair begins (Karpenter logs `deleting unhealthy node`; Auto Mode does this silently)
4. Node tainted with `karpenter.sh/disrupted:NoSchedule`
5. New NodeClaim created → replacement node launches
6. Old node terminated

## Cleanup

```bash
kubectl delete pod xid-inject 2>/dev/null
```

Note: the injected XID persists in DCGM until the node is replaced. If auto repair is enabled, the faulted node is replaced automatically after the 10-minute wait; otherwise clear the condition by replacing the node (a `dcgmi` injection cannot be "un-injected").