# Two public subnets and nothing else.
#
# Hand-rolled rather than pulled from a module, because the interesting thing
# about this VPC is what it does NOT contain: no private subnets, no NAT
# gateway, no VPC endpoints. A NAT gateway is $32/month whether or not anything
# uses it, and it is the resource most likely to survive a forgotten teardown
# unnoticed. For an ephemeral demo cluster, public subnets with a tight security
# group are the right trade.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "project" { type = string }
variable "cluster_name" { type = string }

variable "cidr" {
  type    = string
  default = "10.42.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS worker nodes will not join without this

  tags = { Name = var.project }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.project }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.cidr, 4, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${local.azs[count.index]}"

    # How Karpenter finds where it is allowed to launch nodes. The EC2NodeClass
    # in the platform unit selects on exactly this tag.
    "karpenter.sh/discovery" = var.cluster_name

    # Lets EKS place public load balancers here, if a later phase needs one.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = aws_vpc.this.cidr_block }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "azs" { value = local.azs }
