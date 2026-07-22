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
```

Flags worth setting on this first apply, since they're easiest to get right upfront:

- **Recommended:** `var.my_cidr` restricts the Grafana ALB Ingress to just your IP, instead of the
  default `0.0.0.0/0` (open to the world). See [Ingress (ALB)](#ingress-alb).
- **Optional:** `var.enable_efa` installs the EFA device plugin, only needed if you're running
  EFA-capable GPU workloads. See [EFA](#efa).
- **Optional:** `var.availability_zones_count` (default `3`) controls how many AZs the VPC and
  cluster spread across - the subnet CIDRs are computed to fit, so this scales cleanly with the
  region. If the region has fewer usable AZs (some regions have as few as 2 after excluding AZs
  that don't support the EKS control plane), the region's max is used instead.

```bash
export MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
echo $MY_CIDR
```

Expected output: `x.x.x.x/32`

```bash
terraform apply -var 'region=us-west-2' -var "my_cidr=${MY_CIDR}" -var 'enable_efa=true' -var 'availability_zones_count=4'
```

Drop any of `-var 'enable_efa=true'`, `-var 'region=...'`, or `-var 'availability_zones_count=...'`
you don't need - `region` defaults to `us-east-2` and `availability_zones_count` to `3`.

When it finishes, configure `kubectl` (the same command regardless of variant, since the cluster
name is fixed - match `--region` to whatever you passed to `-var 'region=...'` above, or
`us-east-2` if you didn't set one):

```bash
aws eks update-kubeconfig --region us-west-2 --name ai-eks-docs --alias ai-eks-docs
```

The outputs also include the node IAM role name and the model S3 bucket.

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

### Grafana Ingress

`auto-mode/` also exposes Grafana through its own ALB `Ingress`, restricted by `var.my_cidr`
(default `0.0.0.0/0` - open to the world). Restrict it to just your own IP:

```bash
export MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
echo $MY_CIDR
```

Expected output: `x.x.x.x/32`

```bash
terraform apply -var "my_cidr=${MY_CIDR}"
```

Retrieve the ALB hostname. The load balancer is created asynchronously, so allow a minute or two:

```bash
echo "http://$(kubectl get ingress kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```

Open the hostname in your browser. Log in with username `admin` and the password from the following command:

```bash
kubectl --namespace monitoring get secrets kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

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

### Manually-applied static pool (existing reservation)

Both variants have a `nodepools/b-200s-static/` folder: a static, reservation-backed
`p6-b200.48xlarge` NodePool with EFA networking, plus an NCCL test. Unlike the strategies above,
it's **not** wired into `var.nodepools` - Terraform can't create a Capacity Block for a specific
instance type/date, so this is applied manually with `kubectl` against a reservation or Capacity
Block you already have.

- [`auto-mode/nodepools/b-200s-static/README.md`](auto-mode/nodepools/b-200s-static/README.md)
- [`karpenter/nodepools/b-200s-static/README.md`](karpenter/nodepools/b-200s-static/README.md)

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
