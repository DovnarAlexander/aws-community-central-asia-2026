include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${get_repo_root()}/infra/modules//database"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    vpc_cidr          = "10.42.0.0/16"
    public_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id     = dependency.network.outputs.vpc_id
  vpc_cidr   = dependency.network.outputs.vpc_cidr
  subnet_ids = dependency.network.outputs.public_subnet_ids

  default_tags = merge(local.root.locals.base_tags, {
    Component = "database"
    ExpiresAt = local.root.locals.expires_at
  })
}
