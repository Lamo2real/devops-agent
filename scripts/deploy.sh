#!/usr/bin/env bash
# Deploy (or plan) the main stack from project.env.
#   scripts/deploy.sh          plan + apply (asks for confirmation)
#   PLAN_ONLY=1 scripts/deploy.sh
#   AUTO_APPROVE=1 scripts/deploy.sh   (CI)
source "$(dirname "$0")/lib.sh"
need terraform
"${CONFIG[@]}" validate
check_aws_account

if [[ "$(cfg GITHUB_MODE)" == "token" ]]; then
  if [[ -z "${DEVOPS_AGENT_GITHUB_TOKEN:-}" && -n "${PLAN_ONLY:-}" && -n "${CI:-}" ]]; then
    # Pull requests never get the token, and the plan role cannot read the
    # state that holds it. The deploy job plans and applies instead.
    log "GITHUB_MODE=token: pull request plan skipped (the deploy job plans with the token)"
    exit 0
  fi
  [[ -n "${DEVOPS_AGENT_GITHUB_TOKEN:-}" ]] || die "GITHUB_MODE=token: export DEVOPS_AGENT_GITHUB_TOKEN"
  export TF_VAR_github_token="$DEVOPS_AGENT_GITHUB_TOKEN"
fi

"$ROOT/scripts/build_lambda.sh"
mkdir -p "$BUILD"
"${CONFIG[@]}" backend --out "$BUILD/backend.hcl"
"${CONFIG[@]}" tfvars  --out "$BUILD/terraform.tfvars.json"

bucket="$(cfg STATE_BUCKET)"
aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 \
  || die "state bucket $bucket not found. Run: make bootstrap"

TF=(terraform -chdir="$ROOT/terraform/main")
"${TF[@]}" init -input=false -reconfigure -backend-config="$BUILD/backend.hcl"
"${TF[@]}" plan -input=false -var-file="$BUILD/terraform.tfvars.json" -out="$BUILD/main.tfplan"

if [[ -n "${PLAN_ONLY:-}" ]]; then
  log "plan only, nothing applied"
  exit 0
fi
if [[ -z "${AUTO_APPROVE:-}" ]]; then
  read -r -p "Apply this plan? (yes/no) " answer
  [[ "$answer" == "yes" ]] || die "aborted"
fi
"${TF[@]}" apply -input=false "$BUILD/main.tfplan"
"${TF[@]}" output
