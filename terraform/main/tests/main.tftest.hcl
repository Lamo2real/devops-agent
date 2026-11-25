# Plan-level tests with mocked providers: no AWS credentials needed.
# Run: make test   (builds build/lambda first)

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  # Realistic ARNs so `command = apply` runs pass the provider's ARN validation.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:eu-north-1:123456789012:mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-north-1:123456789012:mock", url = "https://sqs.eu-north-1.amazonaws.com/123456789012/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:eu-north-1:123456789012:function:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:eu-north-1:123456789012:rule/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-north-1:123456789012:log-group:mock" }
  }
}

mock_provider "awscc" {
  mock_resource "awscc_devopsagent_agent_space" {
    defaults = {
      agent_space_id = "space-123"
      arn            = "arn:aws:aidevops:eu-north-1:123456789012:agentspace/space-123"
    }
  }
  mock_resource "awscc_devopsagent_association" {
    defaults = { association_id = "assoc-123" }
  }
  mock_resource "awscc_devopsagent_service" {
    defaults = { service_id = "svc-github-123" }
  }
  mock_resource "awscc_devopsagent_asset" {
    defaults = { asset_id = "asset-123" }
  }
}

mock_provider "time" {}
mock_provider "archive" {}

variables {
  project_name            = "acme-orders"
  environment             = "pilot"
  aws_account_id          = "123456789012"
  aws_region              = "eu-north-1"
  agent_space_description = "Acme AB acme-orders (pilot)"
  alarm_name_prefixes     = ["symptom-"]
  tags                    = { Project = "acme-orders" }
}

run "defaults_pilot" {
  command = plan

  assert {
    condition     = awscc_devopsagent_agent_space.this.name == "acme-orders-pilot"
    error_message = "Agent Space name must be <project>-<environment>."
  }
  assert {
    condition     = awscc_devopsagent_agent_space.this.preferences.elevated_actions_enabled == false
    error_message = "Directed actions must be off by default (pilot is read only)."
  }
  assert {
    condition     = awscc_devopsagent_agent_space.this.operator_app.iam != null
    error_message = "Default operator auth is IAM."
  }
  assert {
    condition     = awscc_devopsagent_association.monitor.configuration.aws.account_type == "monitor"
    error_message = "Monitoring account must be associated as monitor."
  }
  assert {
    condition     = length(awscc_devopsagent_association.github) == 0 && length(awscc_devopsagent_service.github_token) == 0
    error_message = "No GitHub resources when github_mode = off."
  }
  assert {
    condition     = aws_iam_role.agentspace.name == "DevOpsAgentRole-AgentSpace-acme-orders-pilot"
    error_message = "Unexpected Agent Space role name."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.agentspace_access.policy_arn == "arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy"
    error_message = "Agent Space role needs AIDevOpsAgentAccessPolicy."
  }
  assert {
    condition     = aws_iam_role.alarm_trigger.name == "acme-orders-pilot-fn-alarm-trigger" && aws_iam_role.alarm_trigger.permissions_boundary == "arn:aws:iam::123456789012:policy/acme-orders-pilot-lambda-boundary"
    error_message = "Lambda roles must use the fn- prefix and the Lambda boundary (required by the deploy role)."
  }
  assert {
    condition     = aws_iam_role.agentspace.permissions_boundary == "arn:aws:iam::123456789012:policy/acme-orders-pilot-agent-boundary" && aws_iam_role.operator.permissions_boundary == aws_iam_role.agentspace.permissions_boundary
    error_message = "Agent roles must use the agent boundary."
  }
  assert {
    condition     = aws_lambda_function.alarm_trigger.reserved_concurrent_executions == -1
    error_message = "No reserved concurrency by default (works on accounts with a quota of 10)."
  }
  assert {
    condition     = aws_lambda_function.alarm_trigger.runtime == "python3.13"
    error_message = "Unexpected Lambda runtime."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.alarm_state.event_pattern).detail.alarmName[0].prefix == "symptom-"
    error_message = "EventBridge rule must match alarm name prefixes."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.alarm_state.event_pattern).detail.state.value == ["ALARM"]
    error_message = "Only ALARM transitions may start investigations."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.smoke_test[0].alarm_name == "symptom-acme-orders-pilot-smoke-test"
    error_message = "Smoke alarm must match the first prefix so it reaches the Lambda."
  }
  assert {
    condition     = length(awscc_devopsagent_asset.skill) == 2 && length(awscc_devopsagent_asset.agents_md) == 1
    error_message = "Both example skills and AGENTS.md must be uploaded."
  }
  assert {
    condition     = jsondecode(awscc_devopsagent_asset.skill["incident-investigation"].metadata).agent_types == ["GENERIC"]
    error_message = "Skills must carry agent_types."
  }
  assert {
    condition     = startswith(jsondecode(awscc_devopsagent_asset.skill["incident-investigation"].metadata).description, "Step-by-step")
    error_message = "Skill description must come from SKILL.md frontmatter."
  }
  assert {
    condition     = length(awscc_devopsagent_trigger.weekly_report) == 0
    error_message = "Weekly report is off by default."
  }
}

run "github_app_mode" {
  command = plan
  variables {
    github_mode       = "app"
    github_owner      = "acme-ab"
    github_service_id = "svc-existing"
    github_repositories = [
      { name = "orders-service", id = "101" },
      { name = "platform-infra", id = "102" },
    ]
  }
  assert {
    condition     = length(awscc_devopsagent_association.github) == 2
    error_message = "One association per repository."
  }
  assert {
    condition     = awscc_devopsagent_association.github["orders-service"].service_id == "svc-existing"
    error_message = "App mode must reuse the existing registration."
  }
  assert {
    condition     = awscc_devopsagent_association.github["orders-service"].configuration.git_hub.repo_id == "101"
    error_message = "Repository id must be passed through."
  }
  assert {
    condition     = length(awscc_devopsagent_service.github_token) == 0
    error_message = "App mode must not register a token."
  }
}

run "github_token_mode" {
  command = apply
  variables {
    github_mode         = "token"
    github_owner        = "acme-ab"
    github_token        = "test_token_not_real"
    github_repositories = [{ name = "orders-service", id = "101" }]
  }
  assert {
    condition     = awscc_devopsagent_service.github_token[0].service_type == "github"
    error_message = "Token mode registers GitHub."
  }
  assert {
    condition     = awscc_devopsagent_association.github["orders-service"].service_id == "svc-github-123"
    error_message = "Repositories must use the registration created in token mode."
  }
}

run "github_token_mode_requires_token" {
  command = plan
  variables {
    github_mode  = "token"
    github_owner = "acme-ab"
  }
  expect_failures = [var.github_token]
}

run "idc_and_options" {
  command = plan
  variables {
    operator_auth            = "idc"
    idc_instance_arn         = "arn:aws:sso:::instance/ssoins-1234567890abcdef"
    directed_actions_enabled = true
    agent_locale             = "sv-SE"
    eks_cluster_names        = ["eks-prod"]
    source_account_role_arns = ["arn:aws:iam::210987654321:role/DevOpsAgentRole-SecondaryAccount-x"]
    alert_emails             = ["ops@example.com"]
    weekly_report_enabled    = true
    create_smoke_test_alarm  = false
  }
  assert {
    condition     = awscc_devopsagent_agent_space.this.operator_app.idc.idc_instance_arn == "arn:aws:sso:::instance/ssoins-1234567890abcdef"
    error_message = "IDC config must be set."
  }
  assert {
    condition     = awscc_devopsagent_agent_space.this.locale == "sv-SE"
    error_message = "Locale must be passed."
  }
  assert {
    condition     = aws_eks_access_policy_association.agent_view["eks-prod"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "EKS access must be view only."
  }
  assert {
    condition     = awscc_devopsagent_association.source_accounts["arn:aws:iam::210987654321:role/DevOpsAgentRole-SecondaryAccount-x"].configuration.source_aws.account_id == "210987654321"
    error_message = "Source account id must come from the role ARN."
  }
  assert {
    condition     = length(aws_sns_topic_subscription.alerts_email) == 1
    error_message = "One subscription per e-mail."
  }
  assert {
    condition     = length(awscc_devopsagent_trigger.weekly_report) == 1
    error_message = "Weekly report trigger expected."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.smoke_test) == 0
    error_message = "Smoke alarm must be optional."
  }
}

run "name_too_long" {
  command = plan
  variables {
    project_name = "a-very-long-project-name-tests"
    environment  = "nonprod"
  }
  expect_failures = [var.environment]
}

run "idc_requires_instance" {
  command = plan
  variables {
    operator_auth = "idc"
  }
  expect_failures = [var.idc_instance_arn]
}
