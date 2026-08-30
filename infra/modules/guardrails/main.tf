data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-reaper"
  account_id = data.aws_caller_identity.current.account_id
}

# ── where the alarms land ────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── the reaper ───────────────────────────────────────────────────────────────

data "archive_file" "reaper" {
  type        = "zip"
  source_file = "${path.module}/lambda/reaper.py"
  output_path = "${path.module}/.build/reaper.zip"
}

resource "aws_iam_role" "reaper" {
  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "reaper_logs" {
  role       = aws_iam_role.reaper.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Reading is unconditional; every destructive verb is fenced behind the Project
# tag. The reaper is therefore incapable of touching anything that is not part
# of this demo, whatever a future edit to reaper.py might say.
data "aws_iam_policy_document" "reaper" {
  statement {
    sid = "Discover"
    actions = [
      "ec2:DescribeInstances",
      "eks:ListClusters",
      "eks:DescribeCluster",
      "eks:ListNodegroups",
      "eks:DescribeNodegroup",
      "rds:DescribeDBInstances",
      "rds:ListTagsForResource",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "TerminateTaggedInstances"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid       = "ScaleDownTaggedNodegroups"
    actions   = ["eks:UpdateNodegroupConfig"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid       = "StopTaggedDatabases"
    actions   = ["rds:StopDBInstance"]
    resources = ["arn:aws:rds:${var.region}:${local.account_id}:db:*"]

    condition {
      test     = "StringEquals"
      variable = "rds:db-tag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid       = "Report"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "reaper" {
  name   = local.name
  role   = aws_iam_role.reaper.id
  policy = data.aws_iam_policy_document.reaper.json
}

resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "reaper" {
  function_name = local.name
  role          = aws_iam_role.reaper.arn
  handler       = "reaper.handler"
  runtime       = "python3.13"
  timeout       = 120
  description   = "Shuts down ${var.project} resources whose ExpiresAt tag has passed."

  filename         = data.archive_file.reaper.output_path
  source_code_hash = data.archive_file.reaper.output_base64sha256

  environment {
    variables = {
      PROJECT_TAG   = var.project
      DRY_RUN       = tostring(var.reaper_dry_run)
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [
    aws_iam_role_policy.reaper,
    aws_cloudwatch_log_group.reaper,
  ]
}

# ── the hourly heartbeat ─────────────────────────────────────────────────────

resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.name}-scheduler"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.reaper.arn
    }]
  })
}

resource "aws_scheduler_schedule" "reaper" {
  name        = local.name
  description = "Hourly dead-man switch for ${var.project}."

  schedule_expression          = var.reaper_schedule
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }

  target {
    arn      = aws_lambda_function.reaper.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

# ── budgets ──────────────────────────────────────────────────────────────────

# Activating the tag as a cost allocation dimension is what lets the monthly
# budget below filter on it. AWS takes up to 24 hours to start populating it,
# so the daily account-wide budget is the guard that works from day one.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_budgets_budget" "daily_guard" {
  name         = "${var.project}-daily-guard"
  budget_type  = "COST"
  limit_amount = tostring(var.daily_budget_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  # Account-wide and untagged on purpose. The failure this catches is
  # infrastructure that escaped its tags, which a tag-filtered budget by
  # definition cannot see.

  # AWS only accepts ACTUAL notifications on a DAILY budget -- FORECASTED is
  # rejected outright. Two actual thresholds instead: one that means "something
  # is running that you forgot", one that means "it has been running a while".
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 30
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_budgets_budget" "monthly_project" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.project}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  depends_on = [aws_ce_cost_allocation_tag.project]
}

# SNS accepts budget notifications only if its policy says so.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid     = "AllowBudgets"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
