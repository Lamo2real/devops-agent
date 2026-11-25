# -----------------------------------------------------------------------------
# GitHub access (optional, GITHUB_MODE in project.env).
#
# How the agent reaches GitHub: AWS DevOps Agent does not use an AWS IAM role
# or OIDC to read GitHub. GitHub trusts either
#   * the AWS DevOps Agent GitHub App installed on the org/user (mode "app"),
#     limited to the repositories you select during installation, or
#   * a personal access token stored by the service (mode "token").
# The registration is account level (one per GitHub owner per AWS account).
# Repositories are then connected to this Agent Space one by one below, so the
# agent sees only the repositories listed in GITHUB_REPOS.
# -----------------------------------------------------------------------------

locals {
  github_enabled    = var.github_mode != "off"
  github_service_id = var.github_mode == "token" ? one(awscc_devopsagent_service.github_token[*].service_id) : var.github_service_id
}

# Mode "token": register GitHub for this account with a PAT. The token lives in
# the DevOps Agent service and in Terraform state (encrypted S3 bucket).
resource "awscc_devopsagent_service" "github_token" {
  count        = var.github_mode == "token" ? 1 : 0
  service_type = "github"
  name         = "${local.name_prefix}-github-${var.github_owner}"
  service_details = {
    git_hub = {
      direct_access = {
        organization_name = var.github_owner_type == "organization" ? var.github_owner : null
        token_value       = var.github_token
      }
    }
  }
  tags = [for k, v in var.tags : { key = k, value = v }]

  lifecycle {
    # The service cannot update a registered token: rotation is
    # deregister + register, which a token change triggers here.
    replace_triggered_by = [terraform_data.github_token_fingerprint]
  }
}

# Changes when the token changes, without putting the token itself in a
# non-sensitive attribute.
resource "terraform_data" "github_token_fingerprint" {
  count = var.github_mode == "token" ? 1 : 0
  input = sha256(var.github_token)
}

resource "awscc_devopsagent_association" "github" {
  for_each       = local.github_enabled ? { for r in var.github_repositories : r.name => r } : {}
  agent_space_id = local.agentspace_id
  service_id     = local.github_service_id
  configuration = {
    git_hub = {
      owner      = var.github_owner
      owner_type = var.github_owner_type
      repo_name  = each.value.name
      repo_id    = each.value.id
    }
  }
  depends_on = [awscc_devopsagent_association.monitor]
}
