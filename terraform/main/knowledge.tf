# -----------------------------------------------------------------------------
# Knowledge for the agent, managed as code:
#   knowledge/AGENTS.md           standing instructions for every task
#   knowledge/skills/<n>/SKILL.md one skill per folder (frontmatter: name, description)
#   knowledge/agents/weekly-report/AGENT.md  custom agent for the weekly report
# -----------------------------------------------------------------------------

locals {
  agents_md_path = "${var.knowledge_dir}/AGENTS.md"
  skill_files    = var.skills_enabled ? fileset(var.knowledge_dir, "skills/*/SKILL.md") : toset([])
  skills = {
    for f in local.skill_files : basename(dirname(f)) => {
      content = file("${var.knowledge_dir}/${f}")
      # Description from the SKILL.md frontmatter, as the service expects.
      description = trimspace(try(
        regex("(?m)^description:\\s*(.+)$", file("${var.knowledge_dir}/${f}"))[0],
        "Skill ${basename(dirname(f))}"
      ))
    }
  }
}

resource "awscc_devopsagent_asset" "agents_md" {
  count          = fileexists(local.agents_md_path) ? 1 : 0
  agent_space_id = local.agentspace_id
  asset_type     = "agents_md"
  metadata       = jsonencode({ agent_type = "GENERIC" })
  files = [{
    path         = "AGENTS.md"
    content_text = file(local.agents_md_path)
  }]
}

resource "awscc_devopsagent_asset" "skill" {
  for_each       = local.skills
  agent_space_id = local.agentspace_id
  asset_type     = "skill"
  metadata = jsonencode({
    name        = each.key
    description = substr(each.value.description, 0, 1024)
    agent_types = ["GENERIC"]
  })
  files = [{
    path         = "SKILL.md"
    content_text = each.value.content
  }]

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$", each.key))
      error_message = "Skill folder knowledge/skills/${each.key}: use lowercase letters, digits and -, max 64 characters."
    }
  }
}

# --- Weekly operations report --------------------------------------------------------

resource "awscc_devopsagent_asset" "weekly_report_agent" {
  count          = var.weekly_report_enabled ? 1 : 0
  agent_space_id = local.agentspace_id
  asset_type     = "custom_agent"
  metadata = jsonencode({
    name   = "weekly-ops-report"
    skills = [for s in awscc_devopsagent_asset.skill : s.asset_id]
  })
  files = [{
    path         = "AGENT.md"
    content_text = file("${var.knowledge_dir}/agents/weekly-report/AGENT.md")
  }]
}

resource "awscc_devopsagent_trigger" "weekly_report" {
  count          = var.weekly_report_enabled ? 1 : 0
  agent_space_id = local.agentspace_id
  type           = "TIME_BASED"
  condition = {
    schedule = {
      expression = "rate(7 days)"
    }
  }
  action = jsonencode({
    actionType = "create:task"
    task = {
      agent = "custom:${awscc_devopsagent_asset.weekly_report_agent[0].asset_id}"
    }
  })
  status = "Active"
}
