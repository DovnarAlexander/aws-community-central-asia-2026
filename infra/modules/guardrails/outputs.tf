output "reaper_function_name" {
  description = "Invoke manually with: aws lambda invoke --function-name <this> /dev/stdout"
  value       = aws_lambda_function.reaper.function_name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "project_tag" {
  description = "Tag every reapable resource with Project=<this> plus an ExpiresAt timestamp."
  value       = var.project
}

output "confirm_subscription" {
  description = "Reminder: the email subscription is inactive until confirmed."
  value       = "Check ${var.alert_email} and click the SNS confirmation link, or alarms go nowhere."
}
