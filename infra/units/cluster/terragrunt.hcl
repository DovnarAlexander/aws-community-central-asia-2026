include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${get_repo_root()}/infra/modules//cluster"

  # The control plane takes about twelve minutes to create and roughly as long
  # to delete. A slow destroy that trips a lock timeout leaves a half-removed
  # cluster that still bills.
  extra_arguments "eks_patience" {
    commands  = ["apply", "destroy"]
    arguments = ["-lock-timeout=20m"]
  }
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "database" {
  config_path = "../database"

  mock_outputs = {
    security_group_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  cluster_name         = local.root.locals.cluster_name
  vpc_id               = dependency.network.outputs.vpc_id
  subnet_ids           = dependency.network.outputs.public_subnet_ids
  db_security_group_id = dependency.database.outputs.security_group_id

  default_tags = merge(local.root.locals.base_tags, {
    Component = "cluster"
    ExpiresAt = local.root.locals.expires_at
  })
}
