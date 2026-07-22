## AI/ML on EKS

Code samples for the [Machine Learning on EKS](https://docs.aws.amazon.com/eks/latest/userguide/ml-on-eks.html) section of the EKS User Guide.

### Contents

- [`set-up-cluster/terraform/`](set-up-cluster/terraform/) - Terraform to stand up a GPU-ready EKS cluster, with [EKS Auto Mode](set-up-cluster/terraform/auto-mode/) and [Karpenter](set-up-cluster/terraform/karpenter/) variants.
- [`manifests/inference/`](manifests/inference/) - Kubernetes manifests for loading, serving, and autoscaling a model on the cluster.
- [`manifests/fsx-lustre/`](manifests/fsx-lustre/) - Provision and test a shared FSx for Lustre file system for GPU workloads on the Auto Mode cluster.
