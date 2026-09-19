include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${get_repo_root()}/infra/modules//platform"
}

dependency "cluster" {
  config_path = "../cluster"

  mock_outputs = {
    cluster_name                       = "mock"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
    karpenter_queue_name               = "mock"
    karpenter_node_iam_role_name       = "mock"
    karpenter_namespace                = "kube-system"
    karpenter_service_account          = "karpenter"
    node_security_group_id             = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "queue" {
  config_path = "../queue"

  mock_outputs = {
    work_queue_arn = "arn:aws:sqs:eu-central-1:000000000000:mock"
    dlq_arn        = "arn:aws:sqs:eu-central-1:000000000000:mock-dlq"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Helm needs cluster credentials, which only exist once the cluster unit has
# applied. Generating the provider here rather than in root.hcl keeps that
# dependency where it belongs and out of every other unit.
generate "helm_provider" {
  path      = "helm_provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-HCL
    provider "helm" {
      kubernetes = {
        host                   = "${dependency.cluster.outputs.cluster_endpoint}"
        cluster_ca_certificate = base64decode("${dependency.cluster.outputs.cluster_certificate_authority_data}")

        exec = {
          api_version = "client.authentication.k8s.io/v1beta1"
          command     = "aws"
          args        = ["eks", "get-token", "--cluster-name", "${dependency.cluster.outputs.cluster_name}", "--region", "${local.root.locals.region}"]
        }
      }
    }
  HCL
}

inputs = {
  cluster_name = dependency.cluster.outputs.cluster_name
  expires_at   = local.root.locals.expires_at

  karpenter_queue_name         = dependency.cluster.outputs.karpenter_queue_name
  karpenter_node_iam_role_name = dependency.cluster.outputs.karpenter_node_iam_role_name
  karpenter_namespace          = dependency.cluster.outputs.karpenter_namespace
  karpenter_service_account    = dependency.cluster.outputs.karpenter_service_account
  node_security_group_id       = dependency.cluster.outputs.node_security_group_id

  work_queue_arn = dependency.queue.outputs.work_queue_arn
  dlq_arn        = dependency.queue.outputs.dlq_arn

  default_tags = merge(local.root.locals.base_tags, {
    Component = "platform"
    ExpiresAt = local.root.locals.expires_at
  })
}
