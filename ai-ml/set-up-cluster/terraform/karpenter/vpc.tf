data "aws_availability_zones" "available" {
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  vpc_cidr = "10.0.0.0/16"

  # AZs that don't support the EKS control plane. AZ IDs are stable across accounts — AZ names are
  # randomized per-account, so filtering by name silently misses the constraint.
  # See https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html#network-requirements-subnets.
  excluded_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]

  available_azs = [
    for i, name in data.aws_availability_zones.available.names :
    name if !contains(local.excluded_zone_ids, data.aws_availability_zones.available.zone_ids[i])
  ]

  # Use every usable AZ the region has. Capped at 8 as a safety limit on the CIDR math below (no
  # AWS region currently has more than 6 AZs), not a user-facing setting.
  az_count = min(length(local.available_azs), 8)
  azs      = slice(local.available_azs, 0, local.az_count)

  # /20 subnets computed from the VPC /16 CIDR — 16 possible /20s total, public taking indexes
  # [0, az_count) and private taking [az_count, 2*az_count).
  public_subnets_cidrs  = [for i in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, i)]
  private_subnets_cidrs = [for i in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, local.az_count + i)]
}

# VPC module doesn't yet support regional NGW via `availability_mode = "regional"`.
# Disable the module's NGW and create an explicit one below.
# See https://github.com/terraform-aws-modules/terraform-aws-vpc/pull/1270.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = local.name
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets_cidrs
  private_subnets = local.private_subnets_cidrs

  enable_nat_gateway = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }
}

resource "aws_nat_gateway" "regional" {
  vpc_id            = module.vpc.vpc_id
  availability_mode = "regional"
  tags              = { Name = "${local.name}-ngw" }

  depends_on = [module.vpc]
}

resource "aws_route" "private_ngw" {
  count                  = length(local.private_subnets_cidrs)
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.regional.id
}

resource "aws_security_group" "shared" {
  name        = "${local.name}-shared"
  description = "Intra-VPC shared SG; self-ingress + all egress."
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name                                           = "${local.name}-shared"
    "karpenter.sh/discovery"                       = local.name
    "kubernetes.io/cluster/${local.name}" = "owned"
  }
}

resource "aws_vpc_security_group_ingress_rule" "shared_self" {
  description                  = "Self-ingress, all protocols"
  security_group_id            = aws_security_group.shared.id
  referenced_security_group_id = aws_security_group.shared.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "shared_all" {
  description       = "Allow all egress"
  security_group_id = aws_security_group.shared.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# EFA requires the security group to explicitly allow all traffic to/from itself (self-referencing
# both directions), not just a same-VPC or 0.0.0.0/0 egress rule. Gated by var.enable_efa.
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-security
resource "aws_vpc_security_group_egress_rule" "shared_self" {
  count = var.enable_efa ? 1 : 0

  description                  = "Self-egress, all protocols (required for EFA)"
  security_group_id            = aws_security_group.shared.id
  referenced_security_group_id = aws_security_group.shared.id
  ip_protocol                  = "-1"
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.6.1"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [aws_security_group.shared.id]

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${local.name}-s3" }
    }

    guardduty_data = {
      service             = "guardduty-data"
      service_type        = "Interface"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${local.name}-guardduty-data" }
    }
  }
}
