variable "project_name" {
  type        = string
  description = "PROJECT_NAME from project.env."
}

variable "environment" {
  type        = string
  description = "ENVIRONMENT from project.env. Also the GitHub environment allowed to deploy."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.environment)) && length("${var.project_name}-${var.environment}") <= 36
    error_message = "environment: lowercase, max 16 characters, and project_name-environment max 36 characters (IAM name limits)."
  }
}

variable "aws_account_id" {
  type        = string
  description = "Account the stack is deployed to. Terraform refuses to run against any other account."
}

variable "aws_region" {
  type        = string
  description = "Region for the state bucket and the main stack."
}

variable "state_bucket_name" {
  type        = string
  description = "Name of the S3 bucket for Terraform state."
}

variable "manage_state_bucket" {
  type        = bool
  description = "Create and manage the state bucket. false when another environment of the project already created it."
  default     = true
}

variable "github_repository" {
  type        = string
  description = "owner/repo of the fork that deploys this template."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be owner/repo."
  }
}

variable "create_github_oidc_provider" {
  type        = bool
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  default     = true
}

variable "github_token_mode" {
  type        = bool
  description = "GITHUB_MODE=token: the main state holds the GitHub token, so the plan role may not read it."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
  default     = {}
}
