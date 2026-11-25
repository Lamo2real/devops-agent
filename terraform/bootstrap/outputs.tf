output "state_bucket" {
  description = "S3 bucket holding Terraform state."
  value       = var.state_bucket_name
}

output "deploy_role_arn" {
  description = "GitHub Actions variable AWS_DEPLOY_ROLE_ARN in your fork."
  value       = aws_iam_role.deploy.arn
}

output "plan_role_arn" {
  description = "GitHub Actions variable AWS_PLAN_ROLE_ARN in your fork."
  value       = aws_iam_role.plan.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider used by the roles."
  value       = local.oidc_arn
}

output "lambda_permissions_boundary_arn" {
  description = "Boundary required on the main stack's Lambda roles."
  value       = aws_iam_policy.lambda_boundary.arn
}

output "agent_permissions_boundary_arn" {
  description = "Boundary required on the main stack's agent roles."
  value       = aws_iam_policy.agent_boundary.arn
}

output "github_oidc_sub_prefix" {
  description = "Subject prefix the deploy and plan roles trust (deploy: <prefix>:environment:<env>, plan: <prefix>:pull_request)."
  value       = local.sub_prefix
}
