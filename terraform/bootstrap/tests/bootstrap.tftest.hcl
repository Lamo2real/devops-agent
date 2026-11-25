mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  project_name      = "acme-orders"
  environment       = "pilot"
  aws_account_id    = "123456789012"
  aws_region        = "eu-north-1"
  state_bucket_name = "acme-orders-tfstate-123456789012"
  github_repository = "acme-ab/devops-agent"
}

run "creates_provider_and_roles" {
  command = plan
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "OIDC provider expected by default."
  }
  assert {
    condition     = aws_iam_role.deploy.name == "acme-orders-pilot-github-deploy"
    error_message = "Unexpected deploy role name."
  }
  assert {
    condition     = aws_s3_bucket_versioning.state[0].versioning_configuration[0].status == "Enabled"
    error_message = "State bucket must be versioned."
  }
  assert {
    condition     = aws_iam_policy.lambda_boundary.name == "acme-orders-pilot-lambda-boundary" && aws_iam_policy.agent_boundary.name == "acme-orders-pilot-agent-boundary"
    error_message = "Boundary names must match what the main stack computes."
  }
}

run "second_environment_shares_bucket" {
  command = plan
  variables {
    environment         = "prod"
    manage_state_bucket = false
  }
  assert {
    condition     = length(aws_s3_bucket.state) == 0
    error_message = "Second environment must not recreate the shared bucket."
  }
}

run "default_subject_prefix" {
  command = plan
  assert {
    condition     = output.github_oidc_sub_prefix == "repo:acme-ab/devops-agent"
    error_message = "Default prefix is repo:<owner>/<repo>."
  }
}

run "reuses_existing_provider" {
  command = plan
  variables {
    create_github_oidc_provider = false
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "Existing provider must be reused."
  }
}

run "immutable_subject_prefix" {
  command = plan
  variables {
    github_oidc_sub_prefix = "repo:acme-ab@143636021/devops-agent@1471741576"
  }
  assert {
    condition     = output.github_oidc_sub_prefix == "repo:acme-ab@143636021/devops-agent@1471741576"
    error_message = "Trust must use the immutable subject prefix."
  }
}

run "rejects_bad_repository" {
  command = plan
  variables {
    github_repository = "not-a-repo"
  }
  expect_failures = [var.github_repository]
}
