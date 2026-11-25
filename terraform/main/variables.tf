# Every variable is rendered from project.env by scripts/config.py; edit
# project.env, not this file. Validation here is a second line of defence for
# people who call Terraform directly.

variable "project_name" {
  type        = string
  description = "Short lowercase project name, used as a resource prefix."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name: lowercase letters, digits and -, 3 to 32 characters."
  }
}

variable "environment" {
  type        = string
  description = "Environment label (pilot, prod, nonprod)."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.environment)) && length("${var.project_name}-${var.environment}") <= 36
    error_message = "environment: lowercase, max 16 characters, and project_name-environment max 36 characters (IAM role names are limited to 64)."
  }
}

variable "aws_account_id" {
  type        = string
  description = "Monitoring account id. Terraform refuses to run against any other account."
}

variable "aws_region" {
  type        = string
  description = "Region of the Agent Space."
}

variable "agent_space_description" {
  type        = string
  description = "Agent Space description."
}

variable "agent_locale" {
  type        = string
  description = "BCP 47 language of agent answers (e.g. sv-SE). Empty for the service default."
  default     = ""
}

variable "operator_auth" {
  type        = string
  description = "Operator web app sign-in: iam or idc."
  default     = "iam"
  validation {
    condition     = contains(["iam", "idc"], var.operator_auth)
    error_message = "operator_auth must be iam or idc."
  }
}

variable "idc_instance_arn" {
  type        = string
  description = "IAM Identity Center instance ARN, required when operator_auth = idc."
  default     = ""
  validation {
    condition     = var.operator_auth != "idc" || var.idc_instance_arn != ""
    error_message = "idc_instance_arn is required when operator_auth = idc."
  }
}

variable "directed_actions_enabled" {
  type        = bool
  description = "Let the agent change AWS resources after operator approval. Keep false in the pilot."
  default     = false
}

variable "github_mode" {
  type        = string
  description = "off, app (reuse a console GitHub registration) or token (register with a PAT)."
  default     = "off"
  validation {
    condition     = contains(["off", "app", "token"], var.github_mode)
    error_message = "github_mode must be off, app or token."
  }
}

variable "github_owner" {
  type        = string
  description = "GitHub organization or user owning the repositories."
  default     = ""
}

variable "github_owner_type" {
  type        = string
  description = "organization or user."
  default     = "organization"
  validation {
    condition     = contains(["organization", "user"], var.github_owner_type)
    error_message = "github_owner_type must be organization or user."
  }
}

variable "github_repositories" {
  type = list(object({
    name = string
    id   = string
  }))
  description = "Repositories to connect: name and numeric GitHub id (resolved by scripts/config.py)."
  default     = []
}

variable "github_service_id" {
  type        = string
  description = "Existing GitHub registration (github_mode = app)."
  default     = ""
  validation {
    condition     = var.github_mode != "app" || var.github_service_id != ""
    error_message = "github_service_id is required when github_mode = app."
  }
}

variable "github_token" {
  type        = string
  description = "GitHub PAT for github_mode = token. Passed as TF_VAR_github_token, never in a file."
  default     = ""
  sensitive   = true
  validation {
    condition     = var.github_mode != "token" || var.github_token != ""
    error_message = "github_token (env DEVOPS_AGENT_GITHUB_TOKEN) is required when github_mode = token."
  }
}

variable "alarm_name_prefixes" {
  type        = list(string)
  description = "CloudWatch alarms whose name starts with one of these start an investigation."
  validation {
    condition     = length(var.alarm_name_prefixes) > 0
    error_message = "List at least one alarm name prefix."
  }
}

variable "dedup_window_minutes" {
  type        = number
  description = "Skip a new investigation while one for the same alarm, started within this window, is open."
  default     = 60
}

variable "investigation_priority" {
  type        = string
  description = "Priority of alarm investigations."
  default     = "HIGH"
  validation {
    condition     = contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "MINIMAL"], var.investigation_priority)
    error_message = "investigation_priority must be CRITICAL, HIGH, MEDIUM, LOW or MINIMAL."
  }
}

variable "create_smoke_test_alarm" {
  type        = bool
  description = "Create a test alarm used by `make smoke-test`."
  default     = true
}

variable "alarm_trigger_reserved_concurrency" {
  type        = number
  description = "Reserved concurrency for the alarm-trigger Lambda. -1 = no reservation."
  default     = -1
  validation {
    condition     = var.alarm_trigger_reserved_concurrency == -1 || (var.alarm_trigger_reserved_concurrency >= 1 && var.alarm_trigger_reserved_concurrency <= 1000)
    error_message = "alarm_trigger_reserved_concurrency must be -1 or between 1 and 1000."
  }
}

variable "alert_emails" {
  type        = list(string)
  description = "E-mail addresses subscribed to the alert topic."
  default     = []
}

variable "monthly_investigation_hours_alert" {
  type        = number
  description = "Alert when monthly investigation hours reach this value."
  default     = 20
}

variable "eks_cluster_names" {
  type        = list(string)
  description = "EKS clusters the agent may read."
  default     = []
}

variable "source_account_role_arns" {
  type        = list(string)
  description = "Roles in other accounts that trust this Agent Space."
  default     = []
}

variable "skills_enabled" {
  type        = bool
  description = "Upload knowledge/skills/*/SKILL.md as skills."
  default     = true
}

variable "weekly_report_enabled" {
  type        = bool
  description = "Create the weekly report custom agent and its trigger."
  default     = false
}

variable "lambda_source_dir" {
  type        = string
  description = "Directory with the Lambda code and its dependencies (made by scripts/build_lambda.sh)."
  default     = "../../build/lambda"
}

variable "knowledge_dir" {
  type        = string
  description = "Directory with AGENTS.md, skills/ and agents/."
  default     = "../../knowledge"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
  default     = {}
}
