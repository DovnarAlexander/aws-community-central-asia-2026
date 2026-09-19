# The work queue the demo's workers consume, and the dead letter queue that
# catches what they fail to process.
#
# Queue depth is the signal KEDA scales on, so it is also the number the
# audience watches climb while throughput sits at zero. SQS is effectively free
# at demo volumes.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "project" { type = string }

variable "visibility_timeout_seconds" {
  description = <<-EOT
    How long a message stays invisible after a worker picks it up. Must exceed
    the worst-case processing time, or a slow worker's message reappears and
    gets processed twice -- which during act 2, when everything is slow, would
    inflate the queue on its own and muddy the story we are telling.
  EOT
  type        = number
  default     = 60
}

variable "max_receive_count" {
  description = "Deliveries before a message is parked in the DLQ."
  type        = number
  default     = 5
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "work" {
  name                       = "${var.project}-work"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = 3600 # an hour: nothing here outlives a rehearsal
  sqs_managed_sse_enabled    = true

  # Long polling. Without it every idle worker burns API calls and CPU spinning
  # on empty receives, which shows up as noise in exactly the panel the audience
  # is meant to be reading.
  receive_wait_time_seconds = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.work.arn]
  })
}

output "work_queue_url" { value = aws_sqs_queue.work.url }
output "work_queue_arn" { value = aws_sqs_queue.work.arn }
output "work_queue_name" { value = aws_sqs_queue.work.name }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
output "dlq_arn" { value = aws_sqs_queue.dlq.arn }
