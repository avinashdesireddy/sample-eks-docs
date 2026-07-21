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

## EFA

The EFA device plugin is needed if you're on an EFA-capable instance size (`g*.8xlarge`/`.16xlarge`
and larger, `p*` family) and want to use EFA for inter-instance networking or with FSx for Lustre.
`var.enable_efa` (default `false`) installs the plugin plus a shared SG self-referencing rule EFA
requires. Turn it on if either:

- A NodeClass requests EFA network interfaces for **static** capacity (e.g. `networkInterfaces`
  with `interfaceType: efa-only` on a capacity-block pool), or
- A pod requests the `vpc.amazonaws.com/efa` extended resource for **dynamic** capacity:

  ```yaml
  resources:
    limits:
      vpc.amazonaws.com/efa: 8
    requests:
      vpc.amazonaws.com/efa: 8
  ```

Leave `enable_efa` off if neither applies.

```bash
terraform apply -var 'enable_efa=true'
```

Combine with a GPU NodePool:

```bash
terraform apply -var 'enable_efa=true' -var 'nodepools={"spot-ondemand"={}}'
```

Or with a reservation - note the default `reservation.instance_type` (`g6e.4xlarge`) isn't
EFA-capable, so override it to `.8xlarge` or larger:

```bash
terraform apply -var 'enable_efa=true' -var 'nodepools={"reserved-spot-ondemand"={reservation={instance_type="g6e.8xlarge",instance_count=1}}}'
```

`var.enable_efa` also installs the [MPI Operator](https://github.com/kubeflow/mpi-operator)
(Kubeflow), which manages distributed `MPIJob` resources - useful for running multi-node NCCL/EFA
tests. It's not installed when `enable_efa` is `false`.

## Ingress (ALB)

Both variants set up a default `alb` `IngressClass` so an `Ingress` resource with no
`ingressClassName` gets an Application Load Balancer automatically. What each variant installs
differs:

- `auto-mode/`: EKS Auto Mode has an ALB controller built into the control plane already, so this
  is just an `IngressClass` + `IngressClassParams` (`scheme: internet-facing`) - no Helm install,
  no IAM policy.
- `karpenter/`: self-managed Karpenter has no built-in load balancer controller, so this installs
  the full [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
  (IAM role/policy, pod identity association, Helm release) plus the `IngressClass`.

Both are always on (no switch) - create an `Ingress` and an ALB is provisioned for you.

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
