#!/usr/bin/env bash
# One-time setup per environment: state bucket, permissions boundaries and the
# GitHub Actions OIDC roles. Run with administrator credentials.
#
# The bootstrap state itself lives in the state bucket under
# bootstrap/<project>-<environment>.tfstate, so re-running from a fresh clone
# or another machine is safe, and every environment has its own state.
source "$(dirname "$0")/lib.sh"
need terraform
"${CONFIG[@]}" validate
check_aws_account

mkdir -p "$BUILD"
"${CONFIG[@]}" bootstrap --out "$BUILD/bootstrap.tfvars.json"

DIR="$ROOT/terraform/bootstrap"
TF=(terraform -chdir="$DIR")
OVERRIDE="$DIR/backend_override.tf"   # gitignored (*_override.tf)
bucket="$(cfg STATE_BUCKET)"
key="bootstrap/$(cfg NAME_PREFIX).tfstate"
region="$(cfg AWS_REGION)"

use_s3_backend() {
  cat > "$OVERRIDE" <<HCL
terraform {
  backend "s3" {}
}
HCL
  "${TF[@]}" init -input=false "$@" \
    -backend-config="bucket=$bucket" -backend-config="key=$key" -backend-config="region=$region" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true"
}

if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  log "state bucket $bucket exists, using s3://$bucket/$key"
  if [[ -f "$DIR/terraform.tfstate" && ! -f "$OVERRIDE" ]]; then
    # An earlier first run stopped after creating the bucket: keep its state.
    use_s3_backend -migrate-state -force-copy
    rm -f "$DIR/terraform.tfstate" "$DIR/terraform.tfstate.backup"
  else
    use_s3_backend -reconfigure
  fi
  if "${TF[@]}" state list 2>/dev/null | grep -q '^aws_s3_bucket.state\[0\]$'; then
    manage=true    # this environment created the bucket
  else
    manage=false   # another environment of the project owns the bucket
  fi
else
  log "creating state bucket $bucket (first environment of this project)"
  rm -f "$OVERRIDE"
  "${TF[@]}" init -input=false -reconfigure
  manage=true
fi

"${TF[@]}" apply -input=false -var-file="$BUILD/bootstrap.tfvars.json" \
  -var="manage_state_bucket=$manage" ${AUTO_APPROVE:+-auto-approve}

if [[ ! -f "$OVERRIDE" ]]; then
  log "moving the bootstrap state into s3://$bucket/$key"
  use_s3_backend -migrate-state -force-copy
  rm -f "$DIR/terraform.tfstate" "$DIR/terraform.tfstate.backup"
fi

deploy_role="$("${TF[@]}" output -raw deploy_role_arn)"
plan_role="$("${TF[@]}" output -raw plan_role_arn)"
cat >&2 <<MSG

Bootstrap done.
  AWS_DEPLOY_ROLE_ARN = $deploy_role
  AWS_PLAN_ROLE_ARN   = $plan_role

Next: connect GitHub Actions in $(cfg DEPLOY_GITHUB_REPOSITORY):
  make github-setup      (uses the gh CLI; or follow README.md by hand)
MSG
