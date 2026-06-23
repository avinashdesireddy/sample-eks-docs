# GPU NodePools, controlled by var.nodepools (a map keyed by folder name under nodepools/).
# Defaults to { "dynamic-spot-on-demand" = {} }.
#
# Usage:
#   terraform apply
#       -> dynamic-spot-on-demand only (default)
#   terraform apply -var 'nodepools={"reserved-capacity-spot-overflow"={reservation={}}}'
#       -> reserved gpu-inf pool (reserved-first, spot/on-demand overflow). reservation={} makes Terraform
#          create a tagged ODCR with defaults (g6e.4xlarge, 1 instance, first cluster AZ); the NodeClass
#          selects it by tag (nodepool=reserved-capacity-spot-overflow).
#   terraform apply -var 'nodepools={"static-capacity-dynamic-overflow"={reservation={instance_type="g6e.xlarge",instance_count=3}}}'
#       -> always-on reserved pool (gpu-static, replicas = instance_count) backed by an ODCR, plus a
#          gpu-dynamic spot/on-demand overflow pool.
#   reservation overrides instance_type / instance_count / az, e.g. {reservation={instance_type="g6e.4xlarge",instance_count=2,az="us-east-2a"}}
#
# Notes:
#   - dynamic-spot-on-demand, reserved-capacity-spot-overflow, and static-capacity-dynamic-overflow are
#     mutually exclusive GPU inference strategies; enable at most one (enforced by a validation).
#   - Each strategy with a `reservation` gets its own ODCR tagged nodepool=<key>.

locals {
  nodepools_dir = "${path.module}/nodepools"

  # Flatten every enabled strategy folder to { filename => { path, strategy } }. Keying by filename
  # (not folder) keeps each pool's address stable; carrying the strategy lets templates pull that
  # strategy's reservation config (e.g. static replicas = ODCR instance_count).
  manifests = merge([
    for strategy in keys(var.nodepools) : {
      for file in fileset("${local.nodepools_dir}/${strategy}", "*.yml") :
      file => { path = "${local.nodepools_dir}/${strategy}/${file}", strategy = strategy }
    }
  ]...)

  nodeclass_files = { for f, m in local.manifests : f => m if startswith(f, "nodeclass-") }
  nodepool_files  = { for f, m in local.manifests : f => m if startswith(f, "nodepool-") }
}

# One ODCR per strategy that sets `reservation`, tagged nodepool=<key> so the matching NodeClass can
# select it by tag. Bills immediately until destroyed.
#
# The reservation is a single atomic block in one AZ (reservation.az, default the first cluster AZ):
# EC2 either reserves all instance_count in that AZ or fails with InsufficientInstanceCapacity. There
# is no automatic AZ fallback — if creation fails, set reservation.az to another AZ and re-apply.
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

  yaml_body = templatefile(each.value.path, {
    # Static pools size their replicas to the ODCR instance count; ignored by pools that don't use it.
    replicas = try(var.nodepools[each.value.strategy].reservation.instance_count, 1)
  })

  depends_on = [kubectl_manifest.nodeclasses, module.eks]
}
