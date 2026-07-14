locals {
  name = var.cluster_name

  module_addons = {
    eks-pod-identity-agent = {
      before_compute = true
      preserve       = false
    }

    vpc-cni = {
      before_compute = true
      preserve       = false
      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni.arn
        service_account = "aws-node"
      }]
    }

    kube-proxy = {
      before_compute = true
      preserve       = false
    }

    coredns = {
      preserve                    = false
      resolve_conflicts_on_create = "OVERWRITE"
      configuration_values = jsonencode({
        nodeSelector = {
          "node-role" = "system"
        }
      })
    }

    eks-node-monitoring-agent = {
      preserve = false
    }

    aws-ebs-csi-driver = {
      preserve = false
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
      configuration_values = jsonencode({
        controller = {
          nodeSelector = {
            "node-role" = "system"
          }
        }
      })
    }
  }

  standalone_addons = {
    metrics-server = {
      preserve                    = false
      resolve_conflicts_on_update = "PRESERVE"
      configuration_values = jsonencode({
        nodeSelector = {
          "node-role" = "system"
        }
      })
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

  addons = local.module_addons

  # System MNG hosts kube-system pods. Application workloads target Karpenter-launched nodes.
  eks_managed_node_groups = {
    system = {
      name           = "system"
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["m8g.xlarge"]

      subnet_ids = module.vpc.private_subnets

      min_size     = 2
      desired_size = 2
      max_size     = 5

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
          }
        }
      }

      node_repair_config = {
        enabled = true
      }

      labels = {
        "node-role" = "system"
      }

      taints = {
        critical_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      iam_role_attach_cni_policy = false
    }
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
# Pod Identity trust + IAM roles for addons
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

resource "aws_iam_role" "vpc_cni" {
  name               = "${local.name}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
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
  configuration_values        = try(each.value.configuration_values, null)

  depends_on = [module.eks]
}
