# What runs inside the cluster before any demo workload does: Karpenter, KEDA,
# the node pool they scale onto, and the IAM the workers need to reach SQS.
#
# The Karpenter NodePool and EC2NodeClass ship as a tiny local Helm chart rather
# than as kubernetes_manifest resources. Those resources look up a CRD's schema
# at plan time, and on a first apply the Karpenter CRDs do not exist yet, so the
# plan fails before it can install them. Helm has no such opinion.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

variable "project" { type = string }
variable "cluster_name" { type = string }
variable "expires_at" { type = string }

variable "karpenter_queue_name" { type = string }
variable "karpenter_node_iam_role_name" { type = string }
variable "karpenter_namespace" { type = string }
variable "karpenter_service_account" { type = string }
variable "node_security_group_id" { type = string }

variable "work_queue_arn" { type = string }
variable "dlq_arn" { type = string }

variable "karpenter_version" {
  type    = string
  default = "1.14.1"
}

variable "keda_version" {
  type    = string
  default = "2.20.2"
}

variable "node_instance_types" {
  description = <<-EOT
    Small on purpose. The pods are tiny -- 16 replicas at 100m is 1.6 vCPU --
    so what the audience watches is the node *count*, and small instances make
    more of them appear for the same amount of work.
  EOT
  type        = list(string)
  default     = ["t4g.small", "t4g.medium"]
}

variable "node_cpu_limit" {
  description = "Ceiling on Karpenter capacity. Matches the account's 8 vCPU spot quota."
  type        = number
  default     = 8
}

data "aws_caller_identity" "current" {}

locals {
  system_selector = { role = "system" }
}

# ── Karpenter ────────────────────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  create_namespace = true

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  # Karpenter must not run on capacity Karpenter owns: evicting its own
  # controller mid-scale is a deadlock that only shows up under load, which is
  # exactly when the demo needs it working.
  values = [yamlencode({
    serviceAccount = { name = var.karpenter_service_account }
    nodeSelector   = local.system_selector

    settings = {
      clusterName       = var.cluster_name
      interruptionQueue = var.karpenter_queue_name
    }

    controller = {
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    # One replica. The default of two cannot schedule on a single system node
    # because the chart spreads replicas across hosts.
    replicas = 1
  })]
}

resource "helm_release" "nodepool" {
  name      = "karpenter-nodepool"
  namespace = var.karpenter_namespace
  chart     = "${path.module}/charts/karpenter-nodepool"

  values = [yamlencode({
    clusterName     = var.cluster_name
    nodeRole        = var.karpenter_node_iam_role_name
    securityGroupId = var.node_security_group_id
    instanceTypes   = var.node_instance_types
    cpuLimit        = tostring(var.node_cpu_limit)

    # Tags on every instance Karpenter launches. Without these the reaper cannot
    # see the nodes -- they are created by a controller, not by Terraform, so
    # the provider's default_tags never touch them.
    tags = {
      Project   = var.project
      ExpiresAt = var.expires_at
      ManagedBy = "karpenter"
    }
  })]

  depends_on = [helm_release.karpenter]
}

# ── KEDA ─────────────────────────────────────────────────────────────────────

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true

  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.keda_version

  values = [yamlencode({
    nodeSelector = local.system_selector

    resources = {
      operator = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  # The association has to exist before the pod does. Pod Identity injects
  # credentials at pod creation, so an operator started first comes up with no
  # AWS access at all and reports "no EC2 IMDS role found" until someone
  # restarts it -- a failure that looks like a broken trigger rather than a
  # broken ordering.
  depends_on = [aws_eks_pod_identity_association.keda]
}

# KEDA polls SQS for the queue depth it scales on, so the operator needs to read
# queue attributes. Pod Identity rather than IRSA: no OIDC trust policy to get
# wrong, and it survives the cluster being recreated.
data "aws_iam_policy_document" "keda_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda" {
  name               = "${var.project}-keda"
  assume_role_policy = data.aws_iam_policy_document.keda_assume.json
}

resource "aws_iam_role_policy" "keda" {
  name = "${var.project}-keda"
  role = aws_iam_role.keda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      Resource = [var.work_queue_arn, var.dlq_arn]
    }]
  })
}

# Deliberately does not depend on the Helm release -- the dependency runs the
# other way, see the release above. An association can be created for a service
# account that does not exist yet.
resource "aws_eks_pod_identity_association" "keda" {
  cluster_name    = var.cluster_name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda.arn
}

# ── the application's own SQS access ─────────────────────────────────────────
# The role exists here rather than in a later phase because it is infrastructure
# the workloads assume, not something a manifest can create for itself.

resource "aws_iam_role" "app" {
  name               = "${var.project}-app"
  assume_role_policy = data.aws_iam_policy_document.keda_assume.json
}

resource "aws_iam_role_policy" "app" {
  name = "${var.project}-app"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:SendMessageBatch",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:DeleteMessageBatch",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = [var.work_queue_arn, var.dlq_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = var.cluster_name
  namespace       = "demo"
  service_account = "demo"
  role_arn        = aws_iam_role.app.arn
}

output "app_role_arn" { value = aws_iam_role.app.arn }
output "keda_role_arn" { value = aws_iam_role.keda.arn }
