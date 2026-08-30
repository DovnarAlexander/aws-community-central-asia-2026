# The EKS control plane, one small node group for system components, and the
# IAM plumbing Karpenter needs before it can buy anything.
#
# The split is deliberate. Karpenter cannot manage the nodes it runs on, so
# there is exactly one managed node group -- big enough for CoreDNS, the
# Karpenter controller and the KEDA operator, and nothing else. Every workload
# the demo deploys lands on Karpenter capacity, which is what makes the node
# counter on stage mean something.
#
# Helm releases and Kubernetes objects live in the platform unit, not here: a
# single apply that both creates a cluster and talks to its API is the classic
# chicken-and-egg that breaks on the first destroy.

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
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "db_security_group_id" { type = string }

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "system_instance_type" {
  description = <<-EOT
    On-demand, and it counts against the account's 8 vCPU on-demand quota. One
    t4g.large leaves six vCPU spare there, and the whole spot quota free for
    Karpenter, which draws on a separate limit. Graviton throughout: the app is
    Go, the laptop that builds it is Apple Silicon, and arm64 is cheaper.
  EOT
  type        = string
  default     = "t4g.large"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # The driver runs from a laptop, so the API has to be reachable from outside
  # the VPC. There is no private-only path that also works from a stage.
  endpoint_public_access                   = true
  endpoint_private_access                  = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Only the control-plane logs worth having during a rehearsal. Every enabled
  # type is CloudWatch ingest we pay for and never read.
  enabled_log_types = ["api", "authenticator"]

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 7

  # No KMS key: envelope-encrypting demo secrets costs $1/month for a cluster
  # that lives in hours, and there is nothing in it worth protecting.
  #
  # It has to be null, not {} -- the module gates the whole feature on
  # `encryption_config != null`, and an empty object still satisfies that,
  # producing a config block with no key and a plan-time error.
  create_kms_key           = false
  encryption_config        = null
  attach_encryption_policy = false

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = [var.system_instance_type]
      capacity_type  = "ON_DEMAND"

      # The module defaults to the x86 AMI, which EKS rejects outright for a
      # Graviton instance type rather than picking the obvious alternative.
      ami_type = "AL2023_ARM_64_STANDARD"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      # The reaper scales this to zero when ExpiresAt passes, which also strands
      # the Karpenter controller -- so the nodes it owns stay dead once they are
      # terminated instead of being helpfully replaced.
      labels = {
        role = "system"
      }
    }
  }

  tags = {
    # Karpenter's own discovery, matching the subnet tags in the network unit.
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# Karpenter's IAM: a controller role, a node role and instance profile for the
# instances it launches, and an SQS queue that receives spot interruption
# notices so a reclaimed node drains instead of vanishing mid-demo.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = module.eks.cluster_name

  enable_spot_termination         = true
  create_pod_identity_association = true

  # Karpenter's controller policy is larger than the 6144-byte ceiling AWS puts
  # on a managed policy, so creating it fails outright. An inline role policy
  # gets 10240 and fits.
  enable_inline_policy = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

# Karpenter nodes get their own security group from the node class, so the
# cluster's node security group is what needs a path to Postgres. Both the
# system group and Karpenter capacity use it.
resource "aws_security_group_rule" "nodes_to_db" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = var.db_security_group_id
  description              = "Postgres on RDS"
}

output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_certificate_authority_data" { value = module.eks.cluster_certificate_authority_data }
output "cluster_version" { value = module.eks.cluster_version }
output "node_security_group_id" { value = module.eks.node_security_group_id }
output "cluster_primary_security_group_id" { value = module.eks.cluster_primary_security_group_id }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }

output "karpenter_queue_name" { value = module.karpenter.queue_name }
output "karpenter_node_iam_role_name" { value = module.karpenter.node_iam_role_name }
output "karpenter_service_account" { value = module.karpenter.service_account }
output "karpenter_namespace" { value = module.karpenter.namespace }
