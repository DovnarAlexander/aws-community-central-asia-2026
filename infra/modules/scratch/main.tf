# A deliberately doomed instance, for proving the reaper actually reaps.
#
# The guards are the one part of this repository that must not be taken on
# trust: an untested dead-man switch is worse than none, because it buys the
# confidence without the cover. So we create something cheap, tag it as already
# expired, and check that the Lambda kills it.
#
# Everything here is free except the instance, which is a t4g.nano at roughly
# half a cent an hour. Destroy it as soon as the test passes.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type = string
}

variable "project" {
  type = string
}

variable "expires_at" {
  description = "RFC3339. Set it in the past to make the instance immediately reapable."
  type        = string
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_availability_zones" "available" {
  state = "available"
}

# This account has no default VPC, so the test brings its own. Nothing in here
# bills: no internet gateway, no NAT, no elastic IP. The instance never needs to
# reach the network -- it only needs to exist long enough to be killed.
resource "aws_vpc" "scratch" {
  cidr_block = "10.99.0.0/16"

  tags = {
    Name      = "${var.project}-scratch"
    ExpiresAt = var.expires_at
  }
}

resource "aws_subnet" "scratch" {
  vpc_id            = aws_vpc.scratch.id
  cidr_block        = "10.99.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name      = "${var.project}-scratch"
    ExpiresAt = var.expires_at
  }
}

resource "aws_instance" "doomed" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = "t4g.nano"
  subnet_id     = aws_subnet.scratch.id

  tags = {
    Name = "${var.project}-scratch-doomed"

    # The two tags the reaper looks for. Project says "this is ours to kill",
    # ExpiresAt in the past says "kill it now".
    ExpiresAt = var.expires_at
  }
}

output "instance_id" {
  value = aws_instance.doomed.id
}

output "expires_at" {
  value = var.expires_at
}
