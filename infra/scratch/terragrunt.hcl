# Throwaway unit that exists only to prove the reaper works.
#
#   task guardrails:test    # applies this, reaps it, destroys it
#
# Never leave it applied. It is tagged as already expired, so the hourly reaper
# will terminate the instance on its own -- but the VPC and subnet would linger
# until someone runs destroy.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${get_repo_root()}/infra/modules//scratch"
}

inputs = {
  # Deliberately in the past: the instance is born expired.
  expires_at = "2000-01-01T00:00:00Z"

  default_tags = merge(local.root.locals.base_tags, {
    Component = "scratch"
    ExpiresAt = "2000-01-01T00:00:00Z"
  })
}
