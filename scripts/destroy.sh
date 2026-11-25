#!/usr/bin/env bash
# Remove the main stack (Agent Space, roles, Lambdas, alarms).
# The bootstrap stack (state bucket, OIDC roles) is left in place.
source "$(dirname "$0")/lib.sh"
need terraform
"${CONFIG[@]}" validate
check_aws_account

if [[ "$(cfg GITHUB_MODE)" == "token" ]]; then
  # Any value passes validation; destroy does not send it anywhere.
  export TF_VAR_github_token="${DEVOPS_AGENT_GITHUB_TOKEN:-placeholder_for_destroy}"
fi
[[ -d "$BUILD/lambda" ]] || "$ROOT/scripts/build_lambda.sh"
mkdir -p "$BUILD"
"${CONFIG[@]}" backend --out "$BUILD/backend.hcl"
"${CONFIG[@]}" tfvars --offline --out "$BUILD/terraform.tfvars.json"

TF=(terraform -chdir="$ROOT/terraform/main")
"${TF[@]}" init -input=false -reconfigure -backend-config="$BUILD/backend.hcl"
warn "this permanently deletes the Agent Space $(cfg NAME_PREFIX) and its investigations"
"${TF[@]}" destroy -input=false -var-file="$BUILD/terraform.tfvars.json" ${AUTO_APPROVE:+-auto-approve}
