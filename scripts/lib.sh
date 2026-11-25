#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Source it, do not run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
PY="${PYTHON:-python3}"
CONFIG=("$PY" "$ROOT/scripts/config.py")

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

cfg() { "${CONFIG[@]}" get "$1"; }

# Make sure the AWS credentials in use belong to the configured account.
# With AWS_PROFILE (SSO, MFA or assume-role profiles), the CLI resolves the
# session once and Terraform gets plain temporary credentials, because the
# Terraform AWS provider cannot prompt for MFA or reuse the CLI cache.
check_aws_account() {
  need aws
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    # An explicit profile wins: drop credentials left in the shell environment
    # (they would otherwise take precedence over AWS_PROFILE).
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
    local creds
    creds="$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>/dev/null)" \
      || die "cannot get credentials for profile $AWS_PROFILE (run: aws sts get-caller-identity --profile $AWS_PROFILE)"
    eval "$creds"
    unset AWS_PROFILE
  fi
  local expected actual
  expected="$(cfg AWS_ACCOUNT_ID)"
  actual="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "no valid AWS credentials (set AWS_PROFILE or run aws sso login)"
  [[ "$actual" == "$expected" ]] \
    || die "credentials are for account $actual but project.env says AWS_ACCOUNT_ID=$expected"
  export AWS_REGION="$(cfg AWS_REGION)"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  log "AWS account $actual, region $AWS_REGION"
}
