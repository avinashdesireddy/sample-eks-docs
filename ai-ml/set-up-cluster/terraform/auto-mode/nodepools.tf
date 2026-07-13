# GPU NodePools, selected by var.nodepools. See ../README.md for usage (strategies, reserved capacity).

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

  # Reservations Terraform must create: strategies with a `reservation` block but no existing
  # `id`. Strategies that point at an existing ODCR/Capacity Block (`reservation.id` set) are
  # excluded here since Terraform doesn't create or manage those.
  new_reservations = {
    for strategy, cfg in var.nodepools : strategy => cfg.reservation
    if cfg.reservation != null && try(cfg.reservation.id, "") == ""
  }

  # Effective capacity reservation ID per strategy: the user-supplied existing ID, or the one
  # Terraform just created. Empty string for strategies with no `reservation` at all.
  capacity_reservation_ids = {
    for strategy, cfg in var.nodepools : strategy => (
      cfg.reservation == null ? "" :
      try(cfg.reservation.id, "") != "" ? cfg.reservation.id :
      aws_ec2_capacity_reservation.gpu[strategy].id
    )
  }
}

# One ODCR per strategy that sets `reservation` without an existing `id`. The matching NodeClass
# selects it by ID (resolved via local.capacity_reservation_ids); the nodepool=<key> tag is for
# identification only. Single AZ, no fallback; bills until destroyed. To use an existing ODCR or a
# Capacity Block for ML instead, set `reservation.id` and Terraform skips creating one here. See
# ../README.md.
resource "aws_ec2_capacity_reservation" "gpu" {
  for_each = local.new_reservations

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

# Dynamic Auto Mode pools reference the managed `default` NodeClass (no nodeclass file), so this is
# empty unless a strategy ships its own custom NodeClass (e.g. reserved-spot-ondemand).
resource "kubectl_manifest" "nodeclasses" {
  for_each = local.nodeclass_files

  yaml_body = templatefile(each.value.path, {
    cluster_name       = local.name
    node_iam_role_name = module.eks.node_iam_role_name
    # Every strategy that ships a nodeclass file sets `reservation`, so this always resolves to
    # either the user-supplied existing ODCR/Capacity Block ID or the one Terraform just created.
    capacity_reservation_id = local.capacity_reservation_ids[each.value.strategy]
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
