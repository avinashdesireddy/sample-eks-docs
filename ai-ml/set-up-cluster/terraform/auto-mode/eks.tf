locals {
  name = var.cluster_name

  # Auto Mode bundles vpc-cni, kube-proxy, coredns, ebs-csi, pod-identity-agent, eks-node-monitoring-agent.
  # metrics-server isn't bundled and is installed as a standalone addon.
  standalone_addons = {
    metrics-server = {
      preserve                    = false
      resolve_conflicts_on_update = "PRESERVE"
    }
  }
}

#---------------------------------------------------------------
# EKS Cluster
#---------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.20.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.vpc.vpc_id
  control_plane_subnet_ids = module.vpc.private_subnets

  # Skip the module's extra SGs.
  # Covered by mutual-ingress rules between the cluster primary SG and the shared SG.
  create_security_group      = false
  create_node_security_group = false

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.allowed_cidrs

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  encryption_config = {
    resources = ["secrets"]
  }

  # Enable Auto Mode built-in NodePools.
  # `system` (CriticalAddonsOnly tainted, both amd64 and arm64) for cluster-critical workloads.
  # `general-purpose` (amd64, untainted) for general workloads.
  compute_config = {
    enabled    = true
    node_pools = ["system", "general-purpose"]
  }

  # Authenticate to public ECR (public.ecr.aws) so image pulls aren't anonymous and rate-limited.
  node_iam_role_additional_policies = {
    AmazonElasticContainerRegistryPublicReadOnly = "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicReadOnly"
  }
}

#---------------------------------------------------------------
# Mutual SG ingress between cluster primary SG and shared SG
#---------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "cluster_from_shared" {
  description                  = "Allow shared SG to reach the cluster primary SG"
  security_group_id            = module.eks.cluster_primary_security_group_id
  referenced_security_group_id = aws_security_group.shared.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "shared_from_cluster" {
  description                  = "Allow cluster primary SG to reach the shared SG"
  security_group_id            = aws_security_group.shared.id
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
  ip_protocol                  = "-1"
}

#---------------------------------------------------------------
# Pod Identity trust (used by monitoring + s3 IAM roles)
#---------------------------------------------------------------

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

#---------------------------------------------------------------
# Standalone addons
#---------------------------------------------------------------

resource "aws_eks_addon" "standalone" {
  for_each = local.standalone_addons

  cluster_name                = module.eks.cluster_name
  addon_name                  = each.key
  preserve                    = each.value.preserve
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update

  depends_on = [module.eks]
}
