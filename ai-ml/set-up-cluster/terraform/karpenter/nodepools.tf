# GPU NodePools, selected by var.nodepools. See ../README.md for usage (strategies, reserved capacity).
#
# Also provisions a general-purpose, untainted NodePool/NodeClass for non-GPU workloads so they
# don't need to tolerate the GPU NodePools' taint or the system MNG's CriticalAddonsOnly taint.
# Named to match EKS Auto Mode's built-in "general-purpose" node pool, which this Karpenter
# variant otherwise lacks.

resource "kubectl_manifest" "general_purpose_nodeclass" {
  yaml_body = templatefile("${path.module}/nodepools/general-purpose/nodeclass-general-purpose.yml", {
    cluster_name       = local.name
    node_iam_role_name = module.karpenter.node_iam_role_name
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "general_purpose_nodepool" {
  yaml_body = file("${path.module}/nodepools/general-purpose/nodepool-general-purpose.yml")

  depends_on = [kubectl_manifest.general_purpose_nodeclass, module.eks]
}

locals {
  nodepools_dir = "${path.module}/nodepools"

  # Flatten every enabled strategy folder to { filename => { path, strategy } }. Keying by filename
  # (not folder) keeps each pool's address stable.
  manifests = merge([
    for strategy in keys(var.nodepools) : {
      for file in fileset("${local.nodepools_dir}/${strategy}", "*.yml") :
      file => { path = "${local.nodepools_dir}/${strategy}/${file}", strategy = strategy }
    }
  ]...)

  nodeclass_files = { for f, m in local.manifests : f => m if startswith(f, "nodeclass-") }
  nodepool_files  = { for f, m in local.manifests : f => m if startswith(f, "nodepool-") }
}

# One ODCR per strategy that sets `reservation`, tagged nodepool=<key> so the matching NodeClass
# selects it by tag. Single AZ, no fallback; bills until destroyed. See ../README.md.
resource "aws_ec2_capacity_reservation" "gpu" {
  for_each = { for strategy, cfg in var.nodepools : strategy => cfg.reservation if cfg.reservation != null }

  instance_type           = each.value.instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = coalesce(each.value.az, local.azs[0])
  instance_count          = each.value.instance_count
  instance_match_criteria = "open"
  end_date_type           = "unlimited"

  tags = {
    Name     = "${local.name}-${each.key}"
    nodepool = each.key
  }
}

resource "kubectl_manifest" "nodeclasses" {
  for_each = local.nodeclass_files

  yaml_body = templatefile(each.value.path, {
    cluster_name       = local.name
    node_iam_role_name = module.karpenter.node_iam_role_name
  })

  depends_on = [module.eks, aws_ec2_capacity_reservation.gpu]
}

resource "kubectl_manifest" "nodepools" {
  for_each = local.nodepool_files

  yaml_body = file(each.value.path)

  depends_on = [kubectl_manifest.nodeclasses, module.eks]
}
