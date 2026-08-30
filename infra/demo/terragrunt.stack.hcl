# The ephemeral demo environment.
#
#   task up      # ~20 minutes, mostly the EKS control plane
#   task down    # destroys all six units
#
# Everything here carries an ExpiresAt tag, which is what makes it reapable.
# The guards in infra/guardrails/ are deliberately NOT part of this stack: they
# have to outlive it to catch it. See docs/PLAN.md.
#
# Dependency order, resolved by Terragrunt from the dependency blocks in each
# unit rather than declared here:
#
#   network ──┬─→ database
#             └─→ cluster ──→ platform
#   queue, registry: independent

locals {
  units = "${get_repo_root()}/infra/units"
}

unit "network" {
  source = "${local.units}/network"
  path   = "network"
}

unit "queue" {
  source = "${local.units}/queue"
  path   = "queue"
}

unit "registry" {
  source = "${local.units}/registry"
  path   = "registry"
}

unit "database" {
  source = "${local.units}/database"
  path   = "database"
}

unit "cluster" {
  source = "${local.units}/cluster"
  path   = "cluster"
}

unit "platform" {
  source = "${local.units}/platform"
  path   = "platform"
}
