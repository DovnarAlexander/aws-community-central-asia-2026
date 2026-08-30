include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${get_repo_root()}/infra/modules//registry"
}

inputs = {
  default_tags = merge(local.root.locals.base_tags, {
    Component = "registry"
    ExpiresAt = local.root.locals.expires_at
  })
}
