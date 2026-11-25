output "agent_space_id" {
  description = "AWS DevOps Agent Space id."
  value       = local.agentspace_id
}

output "agent_space_arn" {
  description = "Agent Space ARN. Needed by modules/secondary-account-role in other accounts."
  value       = local.agentspace_arn
}

output "agent_space_console_url" {
  description = "Open the Agent Space in the AWS console (operator web app is linked from there)."
  value       = "https://${var.aws_region}.console.aws.amazon.com/aidevops/home?region=${var.aws_region}#/agentspaces/${local.agentspace_id}"
}

output "agentspace_role_arn" {
  description = "Read-only investigation role assumed by the agent."
  value       = aws_iam_role.agentspace.arn
}

output "operator_role_arn" {
  description = "Operator web app role."
  value       = aws_iam_role.operator.arn
}

output "monitor_association_id" {
  description = "Association of the monitoring account."
  value       = awscc_devopsagent_association.monitor.association_id
}

output "github_repositories" {
  description = "Connected GitHub repositories and their association ids."
  value       = { for name, a in awscc_devopsagent_association.github : name => a.association_id }
}

output "alarm_trigger_function" {
  description = "Lambda that starts investigations from alarms."
  value       = aws_lambda_function.alarm_trigger.function_name
}

output "alerts_topic_arn" {
  description = "SNS topic for automation and cost alerts."
  value       = aws_sns_topic.alerts.arn
}

output "dead_letter_queue_url" {
  description = "Events that could not start an investigation."
  value       = aws_sqs_queue.dlq.url
}

output "smoke_test_alarm_name" {
  description = "Alarm used by `make smoke-test` (empty when disabled)."
  value       = var.create_smoke_test_alarm ? local.smoke_alarm_name : ""
}

output "skills" {
  description = "Skill name to asset id."
  value       = { for name, s in awscc_devopsagent_asset.skill : name => s.asset_id }
}
