# -----------------------------------------------------------------------------
# Agent Space, the IAM roles the agent uses, and the monitoring account
# association. Role names follow the AWS sample (DevOpsAgentRole-*) so they are
# easy to recognise in IAM, with the project prefix to keep them unique.
# -----------------------------------------------------------------------------

data "aws_partition" "current" {}

locals {
  name_prefix   = "${var.project_name}-${var.environment}"
  partition     = data.aws_partition.current.partition
  account_id    = var.aws_account_id
  agentspace_id = awscc_devopsagent_agent_space.this.agent_space_id
  # Trust is limited to Agent Spaces in this account and region.
  agentspace_arn_pattern = "arn:${local.partition}:aidevops:${var.aws_region}:${local.account_id}:agentspace/*"
  agentspace_arn         = awscc_devopsagent_agent_space.this.arn
  # Created by terraform/bootstrap; the deploy role can only create roles
  # that carry them.
  lambda_boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-lambda-boundary"
  agent_boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-agent-boundary"
}

# --- Investigation role: read-only access the agent uses in this account -----

data "aws_iam_policy_document" "agentspace_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.agentspace_arn_pattern]
    }
  }
}

resource "aws_iam_role" "agentspace" {
  name                 = "DevOpsAgentRole-AgentSpace-${local.name_prefix}"
  description          = "AWS DevOps Agent: read-only investigation role for ${local.name_prefix}"
  assume_role_policy   = data.aws_iam_policy_document.agentspace_trust.json
  permissions_boundary = local.agent_boundary_arn
}

resource "aws_iam_role_policy_attachment" "agentspace_access" {
  role       = aws_iam_role.agentspace.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AIDevOpsAgentAccessPolicy"
}

data "aws_iam_policy_document" "agentspace_inline" {
  statement {
    sid       = "AllowCreateResourceExplorerServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer"]
  }
}

resource "aws_iam_role_policy" "agentspace_inline" {
  name   = "AllowCreateServiceLinkedRoles"
  role   = aws_iam_role.agentspace.id
  policy = data.aws_iam_policy_document.agentspace_inline.json
}

# --- Operator web app role ------------------------------------------------------

data "aws_iam_policy_document" "operator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.agentspace_arn_pattern]
    }
  }
}

resource "aws_iam_role" "operator" {
  name                 = "DevOpsAgentRole-WebappAdmin-${local.name_prefix}"
  description          = "AWS DevOps Agent: operator web app role for ${local.name_prefix}"
  assume_role_policy   = data.aws_iam_policy_document.operator_trust.json
  permissions_boundary = local.agent_boundary_arn
}

resource "aws_iam_role_policy_attachment" "operator_access" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AIDevOpsOperatorAppAccessPolicy"
}

# The service validates the role trust policies when the Agent Space is
# created, which fails if IAM has not propagated yet.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"
  depends_on = [
    aws_iam_role.agentspace,
    aws_iam_role_policy_attachment.agentspace_access,
    aws_iam_role_policy.agentspace_inline,
    aws_iam_role.operator,
    aws_iam_role_policy_attachment.operator_access,
  ]
}

# --- Agent Space ------------------------------------------------------------------

resource "awscc_devopsagent_agent_space" "this" {
  name        = local.name_prefix
  description = var.agent_space_description
  locale      = var.agent_locale != "" ? var.agent_locale : null

  operator_app = var.operator_auth == "idc" ? {
    idc = {
      idc_instance_arn      = var.idc_instance_arn
      operator_app_role_arn = aws_iam_role.operator.arn
    }
    } : {
    iam = {
      operator_app_role_arn = aws_iam_role.operator.arn
    }
  }

  preferences = {
    elevated_actions_enabled = var.directed_actions_enabled
  }

  tags = [for k, v in var.tags : { key = k, value = v }]

  depends_on = [time_sleep.iam_propagation]
}

# --- Monitoring account association ------------------------------------------------

resource "awscc_devopsagent_association" "monitor" {
  agent_space_id = local.agentspace_id
  service_id     = "aws"
  configuration = {
    aws = {
      account_id         = local.account_id
      account_type       = "monitor"
      assumable_role_arn = aws_iam_role.agentspace.arn
      resources          = []
    }
  }
}

# --- Extra accounts (roles created with modules/secondary-account-role) -----------

resource "awscc_devopsagent_association" "source_accounts" {
  for_each       = toset(var.source_account_role_arns)
  agent_space_id = local.agentspace_id
  service_id     = "aws"
  configuration = {
    source_aws = {
      account_id         = split(":", each.value)[4]
      account_type       = "source"
      assumable_role_arn = each.value
    }
  }
  depends_on = [awscc_devopsagent_association.monitor]
}
