# ML on EKS - cluster setup (Terraform)

Terraform for the cluster used in [ML on EKS](https://docs.aws.amazon.com/eks/latest/userguide/ml-on-eks.html).
Two variants are provided; pick one:

- `auto-mode/` - EKS Auto Mode manages the compute.
- `karpenter/` - self-managed Karpenter manages the compute.

Each builds the same thing: a VPC, an EKS cluster, GPU NodePools for inference, and the
monitoring stack (Amazon Managed Prometheus, DCGM exporter, Grafana).

## Defaults

The cluster is named `ai-eks-docs` and lands in `us-east-2`. **Leave the name as-is** so the
copy/paste commands in the user guide keep working.

## Deploy

```bash
cd auto-mode   # or: cd karpenter
terraform init
terraform apply
```

When it finishes, configure `kubectl` (the same command regardless of variant, since the cluster
name and region are fixed):

```bash
aws eks update-kubeconfig --region us-east-2 --name ai-eks-docs --alias ai-eks-docs
```

The outputs also include the node IAM role name and the model S3 bucket.

## GPU NodePools

`var.nodepools` selects the GPU inference strategy. It defaults to `{}` (no GPU NodePools), so a
plain `terraform apply` provisions the cluster and monitoring stack only, with no GPU capacity and
no GPU billing. Opt in to a strategy with `-var`; the two strategies are mutually exclusive (each
is a complete solution for the inference workload), so enable at most one.

| Strategy                 | What you get                                                            |
| ------------------------ | ----------------------------------------------------------------------- |
| _(none, default)_        | No GPU NodePool. Cluster and monitoring stack only.                     |
| `spot-ondemand`          | On-demand GPU pool, spot-first with on-demand overflow. No reservation. |
| `reserved-spot-ondemand` | Reserved GPU pool backed by an ODCR, with spot/on-demand overflow.      |

Enable the on-demand/spot pool with no reservation:

```bash
terraform apply -var 'nodepools={"spot-ondemand"={}}'
```

### Reserved capacity

The reserved strategies need a `reservation`. Terraform creates the
On-Demand Capacity Reservation (ODCR) for you - you do not supply a reservation ID. The ODCR is
tagged `nodepool=<strategy>` and the NodeClass selects it by that tag.

Use defaults (`g6e.4xlarge`, 1 instance, first cluster AZ):

```bash
terraform apply -var 'nodepools={"reserved-spot-ondemand"={reservation={}}}'
```

Pick the instance type, count, and AZ:

```bash
terraform apply -var 'nodepools={"reserved-spot-ondemand"={reservation={instance_type="g6e.4xlarge",instance_count=3,az="us-east-2a"}}}'
```

Notes:

- An ODCR **bills as soon as it is created** and keeps billing until destroyed, whether or not
  nodes are running on it.
- The reservation is a single block in **one AZ**. EC2 reserves all of `instance_count` in that AZ
  or fails with `InsufficientInstanceCapacity` - there is no automatic AZ fallback. If creation
  fails, set `reservation.az` to another AZ and re-apply.

## Clean up

To remove GPU NodePools while keeping the cluster running, drop the strategy by applying back to
the default (no `-var 'nodepools=...'`). If a strategy had a reservation, this also destroys its
ODCR; the cluster and monitoring stack stay up:

```bash
terraform apply
```

To delete everything this stack created (cluster, VPC, monitoring, any ODCR):

```bash
terraform destroy
```
