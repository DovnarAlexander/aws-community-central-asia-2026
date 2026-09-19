# Root configuration every unit includes.
#
# Included as:
#
#   include "root" {
#     path = find_in_parent_folders("root.hcl")
#   }
#
# It owns the three things no unit should repeat: where state lives, how the AWS
# provider is configured, and which transient failures are worth retrying.
#
# Nothing here creates infrastructure. Units live in infra/<name>/terragrunt.hcl,
# the Terraform they run lives in infra/modules/<name>/, and the ephemeral demo
# environment is composed in infra/demo/terragrunt.stack.hcl.

locals {
  account_id = "250295255927"
  region     = "eu-central-1"
  project    = "probes-demo"

  # Pre-existing bucket on this account, versioning already enabled.
  state_bucket = "${local.account_id}-${local.region}-terraform-states"

  # Applied to every resource through the generated provider's default_tags.
  # Units extend this; only the demo environment adds ExpiresAt, which is what
  # makes a resource reapable. See infra/modules/guardrails/lambda/reaper.py.
  base_tags = {
    Project   = local.project
    ManagedBy = "terragrunt"
    Repo      = "aws-community-central-asia-2026"
  }

  # Optional gitignored overrides, so nobody has to export env vars to run a
  # plan. infra/local.hcl is a plain `locals { ... }` file.
  local_overrides = fileexists("${get_parent_terragrunt_dir()}/local.hcl") ? read_terragrunt_config("${get_parent_terragrunt_dir()}/local.hcl").locals : {}

  # The tag that makes a resource reapable. `task up` exports PROBES_EXPIRES_AT
  # so every unit in a run agrees on one instant; a bare terragrunt invocation
  # gets eight hours from now. Units in the demo stack merge it into their tags;
  # infra/guardrails deliberately does not.
  expires_at = run_cmd("--terragrunt-quiet", "${get_repo_root()}/scripts/expires-at.sh")

  cluster_name = local.project
}

# ── state ────────────────────────────────────────────────────────────────────
# S3 native locking: Terraform 1.10+ and OpenTofu 1.10+ hold the lock in the
# bucket itself, so there is no DynamoDB table to create, pay for, or forget.

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket = local.state_bucket
    # Units generated from a stack sit under .terragrunt-stack/; stripping it
    # keeps state keys readable and stable if the stack layout is refactored.
    key          = "${local.project}/${replace(path_relative_to_include(), "demo/.terragrunt-stack/", "")}/tofu.tfstate"
    region       = local.region
    encrypt      = true
    use_lockfile = true
  }
}

# ── provider ─────────────────────────────────────────────────────────────────
# default_tags comes in as a variable rather than being baked into the generated
# string, so a unit can extend the tag set through plain `inputs` instead of
# regenerating the provider block.

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-HCL
    variable "default_tags" {
      description = "Tags applied to every resource this unit creates."
      type        = map(string)
      default     = {}
    }

    provider "aws" {
      region = "${local.region}"

      # A wrong-account apply is the one mistake that is genuinely expensive to
      # undo. Fail before touching anything instead.
      allowed_account_ids = ["${local.account_id}"]

      default_tags {
        tags = var.default_tags
      }
    }
  HCL
}

# ── retries ──────────────────────────────────────────────────────────────────
# The modern `errors` block, which replaced the old top-level retryable_errors.
# Scoped tightly: eventual consistency and throttling are worth another attempt,
# an IAM denial or a quota refusal is not.

errors {
  retry "aws_transient" {
    retryable_errors = [
      "(?s).*RequestError: send request failed.*",
      "(?s).*ThrottlingException.*",
      "(?s).*Throttling: Rate exceeded.*",
      "(?s).*RequestLimitExceeded.*",
      "(?s).*operation error .*: Throttling.*",
      "(?s).*connection reset by peer.*",
      "(?s).*TLS handshake timeout.*",
    ]
    max_attempts       = 3
    sleep_interval_sec = 8
  }
}

inputs = {
  region       = local.region
  project      = local.project
  default_tags = local.base_tags
}
