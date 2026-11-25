# AWS DevOps Agent: serverless template for Swedish B2B customers

A forkable template that sets up [AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent.html)
in a customer's own AWS account. You configure one file (`project.env`) and deploy with
one command or from GitHub Actions through OIDC. There are no servers: only managed AWS services,
two small Python Lambdas and Terraform.

It follows the pilot design: **investigate first** (read only), symptom alarms start
investigations, code fixes go through Git, and data and inference stay in the EU.

```
CloudWatch symptom alarm ──► EventBridge rule ──► Lambda alarm-trigger ──► AWS DevOps Agent
  (name starts with "symptom-")    (state = ALARM)      (dedup + idempotent)     investigation
                                                                                     │
       GitHub repos (App or token) ◄── reads code, commits, deployments ───────────┤
       EKS (view only), CloudWatch, CloudTrail, other accounts ◄── reads ──────────┘
                                                                                     ▼
                          Operators read the root cause in the web app; fixes become GitHub issues

EventBridge (hourly) ──► Lambda usage-guard ──► CloudWatch metrics ──► alarm ──► SNS e-mail
Failures ──► SQS dead-letter queue ──► alarm ──► SNS e-mail
```

## What gets created

| Stack | Resources | Purpose |
| --- | --- | --- |
| `terraform/bootstrap` (once per environment) | S3 state bucket (shared per project), GitHub OIDC provider (or reuse), two permissions boundaries, `<prefix>-github-deploy` and `<prefix>-github-plan` roles | Terraform state, guard rails and keyless CI deploys |
| `terraform/main` | Agent Space, monitoring account association, `DevOpsAgentRole-AgentSpace-*` (read only), `DevOpsAgentRole-WebappAdmin-*` (operator web app) | The agent itself |
| | GitHub registration (token mode) and one association per repository | Code access, only the listed repositories |
| | EventBridge rule, `alarm-trigger` Lambda, SQS DLQ | Alarms start investigations |
| | `usage-guard` Lambda, CloudWatch alarms, SNS topic | Cost and failure alerts |
| | AGENTS.md, skills, weekly report agent + trigger | Knowledge managed as code |
| | EKS access entries, extra account associations (optional) | Kubernetes and multi-account read access |
| `terraform/modules/secondary-account-role` | Read-only role in another account | Multi-account monitoring |

## Quick start

Prerequisites: Terraform 1.10 or later, Python 3.10 or later (3.13 recommended), AWS CLI v2,
`make`, and administrator credentials for the customer account the first time.
[uv](https://docs.astral.sh/uv/) is used when installed.

1. **Fork** this repository into the customer's (or your) GitHub organization.
2. **Configure:**
   ```bash
   cp project.env.example project.env
   ```
   Edit `project.env`: at minimum `PROJECT_NAME`, `CUSTOMER_NAME`, `AWS_ACCOUNT_ID`,
   `AWS_REGION` and `DEPLOY_GITHUB_REPOSITORY`. Then check it:
   ```bash
   make config
   ```
3. **Bootstrap** (once per environment, with admin credentials; SSO and MFA profiles work):
   ```bash
   AWS_PROFILE=customer-admin make bootstrap
   ```
   Then connect GitHub Actions (needs `gh auth login` with admin rights on the fork):
   ```bash
   make github-setup
   ```
4. **Deploy** from your machine:
   ```bash
   make deploy
   ```
   or commit `project.env` and push to `main` to deploy with GitHub Actions (see below).
5. **Prove it works:**
   ```bash
   make smoke-test
   ```
   This forces the test alarm into ALARM, checks that an investigation starts, fires it
   again to prove that duplicates are skipped, and resets the alarm. It runs one short
   investigation (a few US dollars).
6. **Open the operator web app** from the Agent Space in the AWS console
   (`terraform -chdir=terraform/main output agent_space_console_url`).

`make help` lists every target. `make test` runs all checks without AWS access.

## Configuration: project.env

`project.env.example` documents every setting. The rules:

- `project.env` is the single place you configure. It is gitignored: `make github-setup`
  uploads it to the repository variable `PROJECT_ENV`, and the pipeline recreates the file
  from it, so a public repository never shows your account id. Rerun `make github-setup`
  after editing it. (In a private fork you may commit it instead; remove it from `.gitignore`.)
- It must not hold secrets; the validator refuses values that look like GitHub, AWS or
  Slack tokens and private keys.
- Unknown keys, wrong formats and missing required values are all reported at once.
- `scripts/config.py` is the only code that reads the file. It renders
  `build/backend.hcl` and `build/terraform.tfvars.json` (both gitignored) for Terraform.

The most important settings:

| Setting | Default | Notes |
| --- | --- | --- |
| `AWS_REGION` | `eu-north-1` | Stockholm. Frankfurt or Ireland as alternatives. EU Agent Spaces keep inference in EU regions. |
| `OPERATOR_AUTH` | `iam` | `idc` for IAM Identity Center (Entra ID or Okta with MFA), recommended for production. |
| `DIRECTED_ACTIONS_ENABLED` | `false` | Keep off in the pilot. When on, each change still needs operator approval. |
| `AGENT_LOCALE` | service default | Language of answers, e.g. `sv-SE`. |
| `GITHUB_MODE` | `off` | `app` or `token`, see the next section. |
| `ALARM_NAME_PREFIXES` | `symptom-` | Only alarms with these name prefixes start investigations. |
| `DEDUP_WINDOW_MINUTES` | `60` | Flapping protection per alarm. |
| `MONTHLY_INVESTIGATION_HOURS_ALERT` | `20` | About USD 600 at USD 30 per agent hour. |

## GitHub access

**How the agent gets access.** AWS DevOps Agent does not use an AWS IAM role or OIDC to
read GitHub; GitHub does not accept AWS identities. GitHub trusts one of two things, and
the template supports both through `GITHUB_MODE`:

| Mode | How GitHub trusts the agent | Set up | Webhooks (deploy events, PR reviews) |
| --- | --- | --- | --- |
| `app` (recommended) | The AWS DevOps Agent GitHub App installed on the org, limited to selected repositories | Once per AWS account in the console: AWS DevOps Agent > Capability providers > GitHub > Register. Choose **Read-only** permissions for the pilot. | Yes |
| `token` | A fine-grained personal access token stored by the service | Fully in Terraform. Export the token as `DEVOPS_AGENT_GITHUB_TOKEN` (CI: repository secret). | No |

In both modes Terraform connects **only the repositories listed in `GITHUB_REPOS`** to the
Agent Space, so the agent sees nothing else, even if the app or token could.

Least-privilege GitHub permissions:

- **App:** choose *Read-only* during registration and *Only select repositories* during
  installation. *Read and write* is only needed for directed actions on GitHub (phase 2).
- **Fine-grained token:** resource owner = the organization, only the needed repositories,
  repository permissions *Contents: Read-only* and *Metadata: Read-only*, organization
  permission *Members: Read-only*. Set an expiry; rotating means changing the secret and
  redeploying (the template re-registers automatically when the token changes).

Repository ids are looked up through the GitHub API at deploy time. For private
repositories without a token, write entries as `name:id`
(`gh api repos/OWNER/REPO --jq .id`).

## AWS roles and permissions

| Role | Trusted by | Permissions | Created by |
| --- | --- | --- | --- |
| `DevOpsAgentRole-AgentSpace-<prefix>` | `aidevops.amazonaws.com`, only this account's Agent Spaces | `AIDevOpsAgentAccessPolicy` (read only) + create the Resource Explorer service-linked role | main |
| `DevOpsAgentRole-WebappAdmin-<prefix>` | `aidevops.amazonaws.com` (AssumeRole, TagSession) | `AIDevOpsOperatorAppAccessPolicy` | main |
| `DevOpsAgentRole-SecondaryAccount-<suffix>` | Exactly this Agent Space ARN | `AIDevOpsAgentAccessPolicy` | module, per extra account |
| `<prefix>-fn-alarm-trigger` | Lambda | `aidevops:CreateBacklogTask`, `aidevops:ListBacklogTasks` on this Agent Space only | main |
| `<prefix>-fn-usage-guard` | Lambda | `aidevops:GetAccountUsage`, `cloudwatch:PutMetricData` in its namespace | main |
| `<prefix>-github-deploy` | GitHub OIDC, only jobs in the GitHub environment `ENVIRONMENT` of your fork (limited to `DEPLOY_GITHUB_BRANCH`) | Scoped deploy permissions, see below | bootstrap |
| `<prefix>-github-plan` | GitHub OIDC, only pull requests of your fork | Read-only refresh of the stack's own resources + state lock | bootstrap |

**Guard rails against privilege escalation.** Code pushed to the deploy branch runs with
the deploy role, so the role is built so that it cannot hand out more than the stack needs:

- It can create roles only with a **permissions boundary**: `<prefix>-fn-*` roles must carry
  `<prefix>-lambda-boundary` (only the seven API actions the Lambdas use), and
  `DevOpsAgentRole-*-<prefix>` roles must carry `<prefix>-agent-boundary` (no IAM writes,
  Organizations, account, SSO or AssumeRole, and no access to the Terraform state).
- It can attach only `AIDevOpsAgentAccessPolicy` and `AIDevOpsOperatorAppAccessPolicy`, can
  pass agent roles only to the DevOps Agent service and Lambda roles only to Lambda.
- An explicit deny stops it from changing the CI roles, the boundaries or removing a boundary.
- In `GITHUB_MODE=token` the plan role is denied the state file (it contains the token), and
  pull request plans are skipped.

## GitHub Actions (OIDC, no stored AWS keys)

1. Run `make bootstrap`, then `make github-setup`. The second one creates the **GitHub
   environment** named like `ENVIRONMENT`, allows deployments from `DEPLOY_GITHUB_BRANCH`
   only, and sets the repository variables `AWS_DEPLOY_ROLE_ARN` and `AWS_PLAN_ROLE_ARN`.
   Without `gh`, do the same by hand in Settings > Environments and Settings > Secrets and
   variables > Actions. The branch restriction is required: the AWS role trusts the environment.
2. Optional: add required reviewers to the environment for a manual approval before deploys.
3. Token mode only: add the environment secret `DEVOPS_AGENT_GITHUB_TOKEN`.
4. Branch model: `main` is production. Work on feature branches and open pull requests;
   `make github-setup` adds a ruleset so `main` only changes through pull requests with
   passing tests. Pull requests run tests and a read-only `terraform plan`;
   pushes to `DEPLOY_GITHUB_BRANCH` run tests and deploy infrastructure and application
   (the Lambda code is built in the pipeline and published by Terraform when it changes).
5. Optional: set the repository variable `RUN_SMOKE_TEST=true` to run `make smoke-test`
   after every deploy (`RUN_SMOKE_TEST=true make github-setup` sets it).

If the account already has a GitHub OIDC provider, set `CREATE_GITHUB_OIDC_PROVIDER=false`.

## Knowledge as code

- `knowledge/AGENTS.md`: standing instructions for every task (ground rules, escalation,
  answer format, platform facts). Fill in the platform section per customer.
- `knowledge/skills/<name>/SKILL.md`: one skill per folder. The folder name is the skill
  name; `description:` in the frontmatter tells the agent when to use it. Add a folder and
  redeploy to add a skill.
- `knowledge/agents/weekly-report/AGENT.md`: the weekly operations report custom agent
  (`WEEKLY_REPORT_ENABLED=true`).

## Alarms that start investigations

Only symptom alarms should start investigations: user impact (ALB 5xx, no healthy targets,
application errors, pods not ready), and flap-safe (several consecutive periods, one alarm
per problem). Name them with the prefix, for example `symptom-orders-5xx`. In the lab a
flapping alarm caused 7 to 12 extra incidents; the Lambda also skips a new investigation
while one for the same alarm is open (`DEDUP_WINDOW_MINUTES`). Close investigations when
the incident is solved, so a new incident gets its own investigation.

## Operations

| Activity | Frequency |
| --- | --- |
| Review investigations and duplicates | Weekly in the pilot, then monthly |
| Agent hours against budget (`<prefix>-investigation-hours` alarm) | Automatic, e-mail via `ALERT_EMAILS` |
| Dead-letter queue (`<prefix>-automation-failures` alarm) | Automatic |
| Tune noisy or flapping alarms | Monthly |
| Review IAM roles and EKS access | Quarterly |
| Update AGENTS.md and skills | On change, through pull requests |

Cost: about USD 0.0083 per second of active agent work (about USD 30 per agent hour), no
fixed fee. The serverless parts cost cents per month.

## Remove

```bash
make destroy
```

This deletes the Agent Space with its investigations, plus everything else in the main
stack. The bootstrap stack (state bucket, boundaries, CI roles) stays. Its state is in the
bucket under `bootstrap/<prefix>.tfstate`; destroy it with Terraform from
`terraform/bootstrap` before emptying the bucket. An account-level GitHub App registration
is removed in the console.

## Repository layout

```
project.env.example        all settings, documented
Makefile                   entry point (make help)
scripts/config.py          validates project.env, renders Terraform inputs
scripts/*.sh               build, bootstrap, deploy, destroy
scripts/smoke_test.py      end-to-end test against a deployed stack
src/devops_agent_lambdas/  alarm_trigger.py, usage_guard.py
terraform/bootstrap/       state bucket + GitHub OIDC roles
terraform/main/            the agent stack (+ tests/ with mocked providers)
terraform/modules/         secondary-account-role
knowledge/                 AGENTS.md, skills, custom agents
tests/                     pytest (API calls validated against the real API model)
.github/workflows/         ci.yml (test + plan), deploy.yml (deploy via OIDC)
```

## Limits and open points

- GitHub App registration (`GITHUB_MODE=app`) is a one-time browser step per AWS account;
  AWS does not offer it through an API. Token mode is fully automated.
- The operator web app is public HTTPS; private access is not documented by AWS. Use
  IAM Identity Center with MFA.
- Agents do not filter personal data from logs. Mask PII in application logs.
- Private EKS API endpoints: verify that the agent can reach them, or add a private connection.
