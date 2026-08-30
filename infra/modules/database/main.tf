# The shared dependency the probes are wrong about.
#
# Two settings carry the whole second act and neither is an accident:
#
#   max_connections   pinned low, so that replicas x POOL_MAX can exceed it on
#                     stage in front of an audience rather than in production
#                     six months later.
#   instance class    non-burstable. A t4g would be cheaper, but burstable CPU
#                     credits run out partway through the cascade and the
#                     failure stops being reproducible. Determinism is worth
#                     more than the saving -- roughly $6 across the project.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "project" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "subnet_ids" { type = list(string) }

variable "instance_class" {
  type    = string
  default = "db.m6g.large"

  validation {
    condition     = !startswith(var.instance_class, "db.t")
    error_message = "Burstable classes break act 2: CPU credits run out mid-cascade and the failure stops reproducing."
  }
}

variable "max_connections" {
  description = <<-EOT
    The wall. Act 2 exceeds it deliberately: 16 replicas x POOL_MAX 4 = 64
    against 60, minus the 3 RDS keeps back for the superuser -- which is also
    what lets the psql panel keep reporting while everything else is locked out.
  EOT
  type        = number
  default     = 60
}

variable "engine_version" {
  type    = string
  default = "16"
}

variable "snapshot_identifier" {
  description = <<-EOT
    Restore from a snapshot instead of starting empty, which skips re-seeding
    2M rows. Take one with `task db:snapshot` after the seed job has run.
  EOT
  type        = string
  default     = null
}

resource "random_password" "master" {
  length = 32
  # RDS rejects several punctuation characters in master passwords, and the DSN
  # ends up in a URL. Letters and digits sidestep both problems.
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = var.project
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "Postgres, reachable only from inside the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres from the cluster"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.project}-db" }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.project}-pg${var.engine_version}"
  family = "postgres${var.engine_version}"

  parameter {
    name         = "max_connections"
    value        = tostring(var.max_connections)
    apply_method = "pending-reboot"
  }

  # Every readiness probe that reaches the database shows up here, which is how
  # we prove on stage that the probe -- not the traffic -- is the load.
  parameter {
    name         = "log_min_duration_statement"
    value        = "500"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.project
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.snapshot_identifier == null ? "demo" : null
  username = var.snapshot_identifier == null ? "postgres" : null
  password = var.snapshot_identifier == null ? random_password.master.result : null

  snapshot_identifier = var.snapshot_identifier

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  multi_az                     = false
  backup_retention_period      = 0 # no automated backups: nothing here is precious
  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = false
  deletion_protection          = false
  apply_immediately            = true

  # Snapshots are taken deliberately with `task db:snapshot`, not as a side
  # effect of teardown: a final snapshot on every destroy would collide on the
  # identifier during a day of rehearsals.
  skip_final_snapshot = true
}

# Free, unlike Secrets Manager, and the seed job and the application read it the
# same way. The value is a full DSN so nothing downstream has to assemble one.
resource "aws_ssm_parameter" "dsn" {
  name        = "/${var.project}/database/dsn"
  description = "Postgres DSN for the demo application"
  type        = "SecureString"
  value       = "postgres://postgres:${random_password.master.result}@${aws_db_instance.this.address}:5432/demo?sslmode=require"
}

output "endpoint" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "identifier" { value = aws_db_instance.this.identifier }
output "security_group_id" { value = aws_security_group.db.id }
output "max_connections" { value = var.max_connections }
output "dsn_parameter_name" { value = aws_ssm_parameter.dsn.name }

output "dsn" {
  value     = aws_ssm_parameter.dsn.value
  sensitive = true
}
