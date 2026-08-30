# The guards. Persistent by design.
#
# This unit is deliberately NOT part of infra/demo/terragrunt.stack.hcl: it is
# what catches that stack when a destroy is forgotten, so it has to outlive it.
# It carries no ExpiresAt tag -- the reaper would otherwise eventually shut down
# its own alarms.
#
#   task guardrails:apply
#
# Cost: a Lambda invoked hourly, an SNS topic, two budgets. Effectively zero.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  root = read_terragrunt_config(find_in_parent_folders("root.hcl"))

  # Where alarms land. Either export PROBES_ALERT_EMAIL, or drop it into the
  # gitignored infra/local.hcl as `locals { alert_email = "..." }`.
  alert_email = get_env(
    "PROBES_ALERT_EMAIL",
    lookup(local.root.locals.local_overrides, "alert_email", "")
  )
}

terraform {
  source = "${get_repo_root()}/infra/modules//guardrails"
}

inputs = {
  alert_email = local.alert_email

  default_tags = merge(local.root.locals.base_tags, {
    Component = "guardrails"

    # Read by scripts/cost-check.sh and by anyone wondering why the reaper
    # never touches these resources.
    Persistent = "true"
  })
}
