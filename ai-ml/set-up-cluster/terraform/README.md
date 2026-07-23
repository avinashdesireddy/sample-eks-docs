# ML on EKS - cluster setup (Terraform)

Terraform for the cluster used in [ML on EKS](https://docs.aws.amazon.com/eks/latest/userguide/ml-on-eks.html).

Each variant builds the same thing - a VPC, an EKS cluster, and the monitoring stack (Amazon Managed Prometheus, DCGM exporter, Grafana) - differing only in how compute is managed:

- **`auto-mode/`** - [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) manages the compute. Least operational overhead; AWS owns node provisioning and lifecycle. Start here unless you need node-level control it doesn't expose.
- **`karpenter/`** - self-managed [Karpenter](https://karpenter.sh/) manages the compute. Full control over node configuration.

Pick one and `cd` into it; every command below runs from that directory.

## Deploy the cluster

```bash
cd auto-mode   # or: cd karpenter
terraform init
terraform apply
```

This gives you a running cluster with the monitoring stack and ingress. You can customize the defaults by overriding them using `-var <property=value>`.

## Access EKS Cluster

Verify the cluster is up. The stack emits a ready-to-run `update-kubeconfig` command with the values provided during deployment.

```bash
eval "$(terraform output -raw configure_kubectl)"
kubectl get nodes
```

Other useful outputs: `cluster_name`, `region`, `node_iam_role_name`, and `model_bucket` (the model S3 bucket).

## GPU NodePools

Pick a strategy from the table, then follow the linked steps. The first two are driven by `var.nodepools` (Terraform provisions everything); the static pools are applied manually with `kubectl` because Terraform can't create a Capacity Block for a specific instance type/date. The `var.nodepools` strategies are mutually exclusive - enable at most one.

| Strategy                     | Use when…                                                          | How it's applied      | Steps                                                             |
| ---------------------------- | ------------------------------------------------------------------ | --------------------- | ----------------------------------------------------------------- |
| _(none, default)_            | You only want the cluster + monitoring, no GPU capacity or billing | `terraform apply`     | Nothing extra - this is the default                               |
| `spot-ondemand`              | On-demand GPU inference, no reservation; spot-first with overflow  | `terraform -var`      | [On-demand / spot pool](#on-demand--spot-pool)                    |
| `reserved-spot-ondemand`     | You want Terraform to create + manage an ODCR for you              | `terraform -var`      | [Reserved capacity](#reserved-capacity)                           |
| `b-200s-static`              | You already hold reservation / Capacity Block | `kubectl`      | [automode](auto-mode/nodepools/b-200s-static/README.md) / [karpenter](karpenter/nodepools/b-200s-static/README.md) |
| `b-200s-static-fsx` (karpenter only) | The above, plus an EFA-accelerated FSx for Lustre mount    | `kubectl`      | [karpenter](karpenter/nodepools/b-200s-static-fsx/README.md) |

> Some GPU pools can't be wired into `var.nodepools` - Terraform can't create a Capacity Block for a specific instance type/date - so they're applied manually with `kubectl` against a reservation or Capacity Block you already have.

### On-demand / spot pool

Enable the on-demand/spot pool with no reservation:

```bash
terraform apply -var 'nodepools={"spot-ondemand"={}}'
```

### Reserved capacity

The reserved strategies need a `reservation`. Terraform creates the On-Demand Capacity Reservation (ODCR) for you - you do not supply a reservation ID. The ODCR is tagged `nodepool=<strategy>` and the NodeClass selects it by that tag.

Use defaults (`g6e.4xlarge`, 1 instance, first cluster AZ):

```bash
terraform apply -var 'nodepools={"reserved-spot-ondemand"={reservation={}}}'
```

Pick the instance type, count, and AZ:

```bash
terraform apply -var 'nodepools={"reserved-spot-ondemand"={reservation={instance_type="g6e.4xlarge",instance_count=3,az="us-east-2a"}}}'
```

Notes:

- An ODCR **bills as soon as it is created** and keeps billing until destroyed, whether or not nodes are running on it.
- The reservation is a single block in **one AZ**. EC2 reserves all of `instance_count` in that AZ or fails with `InsufficientInstanceCapacity` - there is no automatic AZ fallback. If creation fails, set `reservation.az` to another AZ and re-apply.

## Elastic Fabric Adapter(EFA)

[Elastic Fabric Adapter](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html) gives EFA-capable instances (`p*` family, `g*.8xlarge`/`.16xlarge` and larger) a high-bandwidth RDMA path for multi-node training/inference and for FSx for Lustre. `var.enable_efa` (default `false`) installs the EFA device plugin and the self-referencing security-group rule EFA requires. On `auto-mode/` it's the only way to get the plugin, since Auto Mode doesn't bundle it.

Enable it when a NodePool actually uses EFA - either a NodeClass requesting `efa-only` interfaces (static capacity-block pools), or a pod requesting the `vpc.amazonaws.com/efa` resource:

```bash
terraform apply -var 'enable_efa=true'
```

It's an independent flag - combine it with any GPU strategy from the table above (e.g. `-var 'nodepools={"spot-ondemand"={}}'`). For the reserved strategy, override the default `reservation.instance_type` (`g6e.4xlarge` isn't EFA-capable) to `.8xlarge` or larger.

Enabling EFA also installs the [MPI Operator](https://github.com/kubeflow/mpi-operator) for distributed `MPIJob` resources (multi-node NCCL/EFA tests).

## Ingress (ALB)

Both variants ship a default `alb` `IngressClass`, so any `Ingress` with no `ingressClassName` gets an internet-facing Application Load Balancer automatically - always on, no flag. They differ only in plumbing: `auto-mode/` uses Auto Mode's built-in ALB controller (just an `IngressClass` + `IngressClassParams`), while `karpenter/` installs the full [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) (IAM role/policy, pod identity, Helm release) since it has none built in.

### Grafana

Both variants expose Grafana through an ALB `Ingress`. Access is gated by `var.my_cidr`, which defaults to `0.0.0.0/0` - **open to the world**. Restrict it to your own IP (re-apply any time to change it):

```bash
export MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
echo "$MY_CIDR"    # expect x.x.x.x/32

terraform apply -var "my_cidr=${MY_CIDR}"
```

Get the ALB hostname (created asynchronously - allow a minute or two) and open it in a browser:

```bash
echo "http://$(kubectl get ingress kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```

Log in as `admin` with the password from:

```bash
kubectl --namespace monitoring get secrets kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

## Clean up

To delete everything this stack created (cluster, VPC, monitoring, any ODCR):

```bash
terraform destroy
```