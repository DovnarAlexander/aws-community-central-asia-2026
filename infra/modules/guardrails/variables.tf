variable "region" {
  description = "Region the demo runs in. The reaper only sweeps this one."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Value of the Project tag that marks demo resources as reapable."
  type        = string
  default     = "probes-demo"
}

variable "alert_email" {
  description = <<-EOT
    Where budget alarms and reaper reports go. Required: a guard nobody hears
    is not a guard. The SNS subscription needs one confirmation click in your
    inbox before it delivers anything.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = <<-EOT
      alert_email is unset or malformed. Set it one of two ways:
        export PROBES_ALERT_EMAIL=you@example.com
      or create the gitignored infra/local.hcl containing:
        locals { alert_email = "you@example.com" }
    EOT
  }
}

variable "daily_budget_usd" {
  description = <<-EOT
    Account-wide daily spend that should never be reached. The demo burns about
    $0.40/hour, so a full working day is under $10; a cluster left up overnight
    lands near $10/day. The account's pre-existing budget alerts at $45/day,
    which is far too high to catch that -- this one exists to catch it.
  EOT
  type        = number
  default     = 15
}

variable "monthly_budget_usd" {
  description = "Project-tagged monthly ceiling. The whole project is estimated at ~$25."
  type        = number
  default     = 40
}

variable "reaper_schedule" {
  description = "How often the dead-man switch runs."
  type        = string
  default     = "rate(1 hour)"
}

variable "reaper_dry_run" {
  description = <<-EOT
    When true the reaper reports what it would shut down and touches nothing.
    Useful for the first run; leave it false in normal operation.
  EOT
  type        = bool
  default     = false
}
