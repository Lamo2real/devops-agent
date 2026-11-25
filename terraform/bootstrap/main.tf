# -----------------------------------------------------------------------------
# Bootstrap stack: run once per ENVIRONMENT by an administrator
# (`make bootstrap`). It creates what the main stack and CI need first:
#   * an S3 bucket for Terraform state (shared by all environments of the
#     project in this account; created by the first environment)
#   * the GitHub Actions OIDC provider (or reuses the account's existing one)
#   * two permissions boundaries that cap every role the main stack creates
#   * a deploy role and a plan role that GitHub Actions assumes through OIDC
#
# scripts/bootstrap.sh stores this stack's own state in the bucket
# (bootstrap/<project>-<environment>.tfstate) right after the first apply.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = var.tags
  }
}

data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  partition   = data.aws_partition.current.partition
  account     = var.aws_account_id
  iam         = "arn:${local.partition}:iam::${local.account}"
  oidc_url    = "https://token.actions.githubusercontent.com"
  oidc_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  bucket_arn       = "arn:${local.partition}:s3:::${var.state_bucket_name}"
  main_state_key   = "devops-agent/${local.name_prefix}.tfstate"
  lambda_role_glob = "${local.iam}:role/${local.name_prefix}-fn-*"
  agent_role_glob  = "${local.iam}:role/DevOpsAgentRole-*-${local.name_prefix}"
  ci_role_glob     = "${local.iam}:role/${local.name_prefix}-github-*"

  # Names are fixed so the main stack can compute the ARNs (scripts/config.py).
  lambda_boundary_name = "${local.name_prefix}-lambda-boundary"
  agent_boundary_name  = "${local.name_prefix}-agent-boundary"
  lambda_boundary_arn  = "${local.iam}:policy/${local.lambda_boundary_name}"
  agent_boundary_arn   = "${local.iam}:policy/${local.agent_boundary_name}"

  # Only these AWS managed policies may be attached to project roles.
  allowed_managed_policies = [
    "arn:${local.partition}:iam::aws:policy/AIDevOpsAgentAccessPolicy",
    "arn:${local.partition}:iam::aws:policy/AIDevOpsOperatorAppAccessPolicy",
  ]
}

# --- Terraform state bucket (first environment of the project creates it) -------

resource "aws_s3_bucket" "state" {
  count  = var.manage_state_bucket ? 1 : 0
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  count  = var.manage_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = var.manage_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count                   = var.manage_state_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  count  = var.manage_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  count  = var.manage_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  count      = var.manage_state_bucket ? 1 : 0
  bucket     = aws_s3_bucket.state[0].id
  policy     = data.aws_iam_policy_document.state_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --- GitHub Actions OIDC provider --------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = local.oidc_url
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate with its own trust store; the
  # thumbprint is only kept for compatibility.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = local.oidc_url
}

# --- Permissions boundaries for every role the main stack creates -----------------
# The deploy role may only create roles that carry these boundaries, so code
# pushed to the deploy branch cannot mint a role with more power than this.

data "aws_iam_policy_document" "lambda_boundary" {
  statement {
    sid = "LambdaWorkload"
    actions = [
      "aidevops:CreateBacklogTask",
      "aidevops:ListBacklogTasks",
      "aidevops:GetAccountUsage",
      "cloudwatch:PutMetricData",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "sqs:SendMessage",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_boundary" {
  name        = local.lambda_boundary_name
  description = "Permissions boundary for the ${local.name_prefix} Lambda roles"
  policy      = data.aws_iam_policy_document.lambda_boundary.json
}

data "aws_iam_policy_document" "agent_boundary" {
  # The agent roles are assumed only by the AWS DevOps Agent service. Their
  # real permissions come from the AWS managed AIDevOps* policies; this
  # boundary removes identity and account administration on top of that.
  statement {
    sid       = "AllowServicePolicies"
    actions   = ["*"]
    resources = ["*"]
  }
  statement {
    # Every IAM write except creating the Resource Explorer service-linked
    # role (handled by the next statement).
    sid    = "DenyIamWrites"
    effect = "Deny"
    actions = [
      "iam:CreateRole", "iam:CreateUser", "iam:CreateGroup", "iam:CreatePolicy", "iam:CreatePolicyVersion",
      "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:CreateInstanceProfile", "iam:CreateOpenIDConnectProvider",
      "iam:CreateSAMLProvider", "iam:Delete*", "iam:Put*", "iam:Attach*", "iam:Detach*", "iam:Update*", "iam:Add*",
      "iam:Remove*", "iam:Tag*", "iam:Untag*", "iam:PassRole", "iam:Set*", "iam:Upload*", "iam:Enable*",
      "iam:Deactivate*", "iam:Change*", "iam:Reset*", "iam:Resync*",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "DenyOtherServiceLinkedRoles"
    effect    = "Deny"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringNotLike"
      variable = "iam:AWSServiceName"
      values   = ["resource-explorer-2.amazonaws.com"]
    }
  }
  statement {
    sid       = "DenyAccountAndIdentity"
    effect    = "Deny"
    actions   = ["organizations:*", "account:*", "sts:AssumeRole", "sts:AssumeRoleWithSAML", "sts:AssumeRoleWithWebIdentity", "sso:*", "identitystore:*"]
    resources = ["*"]
  }
  statement {
    sid       = "DenyTerraformState"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*"]
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "agent_boundary" {
  name        = local.agent_boundary_name
  description = "Permissions boundary for the ${local.name_prefix} AWS DevOps Agent roles"
  policy      = data.aws_iam_policy_document.agent_boundary.json
}

# --- Deploy role (GitHub environment only) -----------------------------------------

data "aws_iam_policy_document" "deploy_trust" {
  # The sub claim of a job that uses a GitHub environment is
  # repo:<owner>/<repo>:environment:<name>. Restrict that environment to the
  # deploy branch in GitHub (scripts/github_setup.sh does it).
  statement {
    sid     = "GitHubActionsDeployEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name_prefix}-github-deploy"
  description          = "GitHub Actions (${var.github_repository}, environment ${var.environment}) deploys the AWS DevOps Agent stack"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/${local.main_state_key}", "${local.bucket_arn}/${local.main_state_key}.tflock"]
  }
  statement {
    sid       = "DevOpsAgent"
    actions   = ["aidevops:*"]
    resources = ["*"]
  }
  statement {
    sid = "CloudControl"
    actions = [
      "cloudformation:CreateResource", "cloudformation:DeleteResource", "cloudformation:UpdateResource",
      "cloudformation:GetResource", "cloudformation:ListResources", "cloudformation:GetResourceRequestStatus",
    ]
    resources = ["*"]
  }

  # Roles: creating or changing one requires the matching boundary.
  statement {
    sid       = "LambdaRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:PutRolePermissionsBoundary"]
    resources = [local.lambda_role_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.lambda_boundary_arn]
    }
  }
  statement {
    sid       = "AgentRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:PutRolePermissionsBoundary"]
    resources = [local.agent_role_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.agent_boundary_arn]
    }
  }
  statement {
    sid       = "AttachOnlyDevOpsAgentManagedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.agent_role_glob]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = local.allowed_managed_policies
    }
  }
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:GetRole", "iam:UpdateRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
    ]
    resources = [local.lambda_role_glob, local.agent_role_glob]
  }
  statement {
    sid       = "PassLambdaRoles"
    actions   = ["iam:PassRole"]
    resources = [local.lambda_role_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
  statement {
    sid       = "PassAgentRoles"
    actions   = ["iam:PassRole"]
    resources = [local.agent_role_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["aidevops.amazonaws.com"]
    }
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.iam}:role/aws-service-role/*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["aidevops.amazonaws.com", "resource-explorer-2.amazonaws.com", "lambda.amazonaws.com"]
    }
  }
  statement {
    sid       = "IamRead"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListRoles", "iam:GetOpenIDConnectProvider"]
    resources = ["*"]
  }

  statement {
    sid       = "ProjectLambdas"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:${var.aws_region}:${local.account}:function:${local.name_prefix}-*"]
  }
  statement {
    sid     = "ProjectEventsLogsQueuesTopicsAlarms"
    actions = ["events:*", "logs:*", "sqs:*", "sns:*", "cloudwatch:*"]
    resources = [
      "arn:${local.partition}:events:${var.aws_region}:${local.account}:rule/${local.name_prefix}-*",
      "arn:${local.partition}:logs:${var.aws_region}:${local.account}:log-group:/aws/lambda/${local.name_prefix}-*",
      "arn:${local.partition}:sqs:${var.aws_region}:${local.account}:${local.name_prefix}-*",
      "arn:${local.partition}:sns:${var.aws_region}:${local.account}:${local.name_prefix}-*",
      "arn:${local.partition}:cloudwatch:${var.aws_region}:${local.account}:alarm:*${local.name_prefix}-*",
    ]
  }
  statement {
    sid = "DescribeOnly"
    actions = [
      "logs:DescribeLogGroups", "logs:ListTagsForResource", "cloudwatch:DescribeAlarms", "sns:ListTopics",
      "sqs:ListQueues", "events:ListRules", "lambda:ListFunctions", "lambda:GetAccountSettings",
      "sts:GetCallerIdentity", "kms:DescribeKey", "eks:DescribeCluster", "eks:ListClusters",
    ]
    resources = ["*"]
  }
  statement {
    sid = "EksAccessEntriesForAgentRole"
    actions = [
      "eks:CreateAccessEntry", "eks:DeleteAccessEntry", "eks:DescribeAccessEntry", "eks:UpdateAccessEntry",
      "eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy", "eks:ListAssociatedAccessPolicies",
      "eks:TagResource", "eks:UntagResource",
    ]
    resources = ["*"]
  }

  # Hard stops: never touch the CI roles, the boundaries or boundary removal.
  statement {
    sid       = "DenyCiRolesAndBoundaries"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [local.ci_role_glob, local.lambda_boundary_arn, local.agent_boundary_arn]
  }
  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-devops-agent"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# --- Plan role (pull requests only, read only) ---------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    sid     = "GitHubActionsPullRequestPlan"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${local.name_prefix}-github-plan"
  description          = "GitHub Actions pull requests in ${var.github_repository} run a read-only terraform plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "StateRead"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "StateObject"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/${local.main_state_key}"]
  }
  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/${local.main_state_key}.tflock"]
  }
  statement {
    sid = "RefreshReadOnly"
    actions = [
      "aidevops:Get*", "aidevops:List*", "aidevops:Describe*",
      "cloudformation:GetResource", "cloudformation:ListResources", "cloudformation:GetResourceRequestStatus",
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetPolicy",
      "iam:GetPolicyVersion", "iam:GetOpenIDConnectProvider", "iam:ListRoleTags",
      "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetPolicy", "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig", "lambda:GetFunctionEventInvokeConfig", "lambda:GetFunctionConcurrency",
      "lambda:ListTags", "lambda:GetRuntimeManagementConfig", "lambda:GetFunctionRecursionConfig",
      "events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource",
      "logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
      "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueueTags",
      "sns:GetTopicAttributes", "sns:ListTagsForResource", "sns:GetSubscriptionAttributes", "sns:ListSubscriptionsByTopic",
      "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
      "eks:DescribeAccessEntry", "eks:ListAssociatedAccessPolicies", "eks:DescribeCluster",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
  dynamic "statement" {
    # In token mode the GitHub token is in the state; pull requests must not read it.
    for_each = var.github_token_mode ? [1] : []
    content {
      sid       = "DenyStateWithSecret"
      effect    = "Deny"
      actions   = ["s3:GetObject"]
      resources = ["${local.bucket_arn}/${local.main_state_key}"]
    }
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}
