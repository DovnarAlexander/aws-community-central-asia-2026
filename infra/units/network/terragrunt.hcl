include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${get_repo_root()}/infra/modules//network"
}

inputs = {
  cluster_name = local.root.locals.cluster_name

  default_tags = merge(local.root.locals.base_tags, {
    Component = "network"
    ExpiresAt = local.root.locals.expires_at
  })
}
