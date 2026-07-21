## Static P6-B200 NodePool with EFA + MPI NCCL test

Terraform for the self-managed Karpenter cluster used to run a static, reservation-backed
`p6-b200.48xlarge` NodePool with EFA networking, the MPI Operator, and a distributed NCCL test.

The EC2NodeClass/NodePool manifests, the NCCL `MPIJob`, and their setup steps have moved to
[`../set-up-cluster/terraform/karpenter/nodepools/b-200s-static/README.md`](../set-up-cluster/terraform/karpenter/nodepools/b-200s-static/README.md) -
that's the canonical, up-to-date version of this guide. This folder's `terraform/` remains as a
working copy of the cluster stack.

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

Then follow [`../set-up-cluster/terraform/karpenter/nodepools/b-200s-static/README.md`](../set-up-cluster/terraform/karpenter/nodepools/b-200s-static/README.md)
to apply the EC2NodeClass, NodePool, and run the NCCL test.

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

See the Cleanup section in
[`../set-up-cluster/terraform/karpenter/nodepools/b-200s-static/README.md`](../set-up-cluster/terraform/karpenter/nodepools/b-200s-static/README.md#cleanup)
to remove the NodePool/EC2NodeClass and NCCL test. To tear down the cluster itself:

```bash
cd terraform/karpenter
terraform destroy -var 'region=ap-south-1'
```
