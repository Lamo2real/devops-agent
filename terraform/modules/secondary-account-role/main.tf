# -----------------------------------------------------------------------------
# Read-only role in an EXTRA AWS account (service/workload account) that the
# Agent Space in the monitoring account may assume. Apply it with credentials
# for that account, then add the output role ARN to SOURCE_ACCOUNT_ROLE_ARNS in
# project.env and redeploy the main stack.
#
#   module "devops_agent_reader" {
#     source          = "github.com/<you>/<fork>//terraform/modules/secondary-account-role"
#     agent_space_arn = "arn:aws:aidevops:eu-north-1:111111111111:agentspace/abc"
#     name_suffix     = "acme-orders-pilot"
#   }
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

variable "agent_space_arn" {
  type        = string
  description = "ARN of the Agent Space (output agent_space_arn of the main stack)."
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:aidevops:[a-z0-9-]+:[0-9]{12}:agentspace/.+$", var.agent_space_arn))
    error_message = "agent_space_arn must be an Agent Space ARN."
  }
}

variable "name_suffix" {
  type        = string
  description = "Suffix for the role name, e.g. the project prefix."
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  monitoring_account = split(":", var.agent_space_arn)[4]
}

data "aws_iam_policy_document" "trust" {
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
      values   = [local.monitoring_account]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.agent_space_arn]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "DevOpsAgentRole-SecondaryAccount-${var.name_suffix}"
  description        = "Read-only access for the AWS DevOps Agent Space ${var.agent_space_arn}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "access" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AIDevOpsAgentAccessPolicy"
}

resource "aws_iam_role_policy" "slr" {
  name = "AllowCreateServiceLinkedRoles"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowCreateResourceExplorerServiceLinkedRole"
      Effect   = "Allow"
      Action   = "iam:CreateServiceLinkedRole"
      Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer"
    }]
  })
}

output "role_arn" {
  description = "Add this to SOURCE_ACCOUNT_ROLE_ARNS in project.env."
  value       = aws_iam_role.this.arn
}
