# Standalone private subnet in a specific AZ for FSx for Lustre + the GPU nodes that mount it.
#
# FSx for Lustre is single-AZ and must sit in the SAME AZ as the GPU nodes (EFA requires same AZ,
# and even the TCP mount wants AZ locality). When GPU capacity comes from a Capacity Block / ODCR
# pinned to one AZ, that AZ may not be one of the three the VPC module created. This adds a private
# subnet in var.fsx_az on the module's VPC without disturbing the module-managed subnets, routed
# through the same regional NAT gateway (aws_nat_gateway.regional in vpc.tf) and tagged for
# Karpenter discovery so both the NodePool and the FSx capacity probe can select it.
#
# Only created when var.fsx_az is set. Example (us-west-2d, matching a p6-b200 Capacity Block):
#   terraform apply -var 'enable_fsx=true' -var 'fsx_az=us-west-2d' \
#     -var 'fsx_subnet_cidr=10.0.96.0/20' -var 'subnet_id=<the id this creates>'

variable "fsx_az" {
  description = <<-EOT
    Availability Zone for a dedicated private subnet to host FSx for Lustre and its GPU clients,
    when that AZ is not among the ones the VPC module created (e.g. a Capacity Block AZ). Empty
    disables it. Must be an AZ in var.region.
  EOT
  type        = string
  default     = ""
}

variable "fsx_subnet_cidr" {
  description = <<-EOT
    CIDR for the var.fsx_az private subnet. Must be inside the VPC CIDR (10.0.0.0/16) and not
    overlap the module subnets. The VPC module consumes /20 indices [0, 2*az_count): public takes
    [0, az_count), private takes [az_count, 2*az_count). For a 4-AZ region (e.g. us-west-2) that is
    public 10.0.0/16/32/48.0 and private 10.0.64/80/96/112.0, so the default 10.0.128.0/20 (/20
    index 8) is the next free block. In a region with more AZs, bump this past the private range.
  EOT
  type        = string
  default     = "10.0.128.0/20"
}

resource "aws_subnet" "fsx" {
  count = var.fsx_az != "" ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  availability_zone = var.fsx_az
  cidr_block        = var.fsx_subnet_cidr

  tags = {
    Name                              = "${local.name}-private-${var.fsx_az}"
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }
}

resource "aws_route_table" "fsx" {
  count = var.fsx_az != "" ? 1 : 0

  vpc_id = module.vpc.vpc_id
  tags   = { Name = "${local.name}-private-${var.fsx_az}" }
}

resource "aws_route" "fsx_ngw" {
  count = var.fsx_az != "" ? 1 : 0

  route_table_id         = aws_route_table.fsx[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.regional.id
}

resource "aws_route_table_association" "fsx" {
  count = var.fsx_az != "" ? 1 : 0

  subnet_id      = aws_subnet.fsx[0].id
  route_table_id = aws_route_table.fsx[0].id
}

output "fsx_subnet_id" {
  description = "ID of the dedicated FSx/GPU subnet (empty when var.fsx_az is unset). Pass as -var subnet_id=... to place FSx here."
  value       = one(aws_subnet.fsx[*].id)
}
