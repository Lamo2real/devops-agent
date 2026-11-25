#!/usr/bin/env bash
# Connect the fork's GitHub Actions to the bootstrap roles with the gh CLI:
#   * environment <ENVIRONMENT>, deployable only from DEPLOY_GITHUB_BRANCH
#     (the AWS deploy role trusts only this environment)
#   * repository variables AWS_DEPLOY_ROLE_ARN, AWS_PLAN_ROLE_ARN and
#     PROJECT_ENV (the contents of project.env; rerun after editing it)
#   * a ruleset on DEPLOY_GITHUB_BRANCH: changes only through pull requests
#     that pass the tests (feature branch -> PR -> merge = production deploy)
# Needs: gh auth login with admin rights on the repository.
source "$(dirname "$0")/lib.sh"
need gh
"${CONFIG[@]}" validate

repo="$(cfg DEPLOY_GITHUB_REPOSITORY)"
env_name="$(cfg ENVIRONMENT)"
branch="$(cfg DEPLOY_GITHUB_BRANCH)"
account="$(cfg AWS_ACCOUNT_ID)"
prefix="$(cfg NAME_PREFIX)"
deploy_role="${AWS_DEPLOY_ROLE_ARN:-arn:aws:iam::$account:role/$prefix-github-deploy}"
plan_role="${AWS_PLAN_ROLE_ARN:-arn:aws:iam::$account:role/$prefix-github-plan}"

log "environment '$env_name' in $repo, deployments only from branch '$branch'"
gh api -X PUT "repos/$repo/environments/$env_name" --input - >/dev/null <<JSON
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
existing="$(gh api "repos/$repo/environments/$env_name/deployment-branch-policies" --jq '.branch_policies[] | "\(.id) \(.name) \(.type // "branch")"')"
while read -r id name type; do
  [[ -z "${id:-}" ]] && continue
  if [[ "$name" != "$branch" || "$type" != "branch" ]]; then
    log "removing deployment branch policy '$name'"
    gh api -X DELETE "repos/$repo/environments/$env_name/deployment-branch-policies/$id" >/dev/null
  fi
done <<< "$existing"
if ! grep -q " $branch branch$" <<< "$existing"; then
  gh api -X POST "repos/$repo/environments/$env_name/deployment-branch-policies" \
    -f name="$branch" -f type=branch >/dev/null
fi

log "repository variables"
gh variable set AWS_DEPLOY_ROLE_ARN --repo "$repo" --body "$deploy_role"
gh variable set AWS_PLAN_ROLE_ARN --repo "$repo" --body "$plan_role"
gh variable set PROJECT_ENV --repo "$repo" < "$ROOT/project.env"
if [[ -n "${RUN_SMOKE_TEST:-}" ]]; then
  gh variable set RUN_SMOKE_TEST --repo "$repo" --body "$RUN_SMOKE_TEST"
fi

log "ruleset on '$branch': pull requests with passing tests only"
ruleset_name="production-branch"
ruleset_id="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$ruleset_name\") | .id")"
ruleset_body="$(cat <<JSON
{
  "name": "$ruleset_name",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/$branch"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [{"context": "Tests (no AWS)"}]
    }}
  ]
}
JSON
)"
if [[ -n "$ruleset_id" ]]; then
  gh api -X PUT "repos/$repo/rulesets/$ruleset_id" --input - >/dev/null <<< "$ruleset_body"
else
  gh api -X POST "repos/$repo/rulesets" --input - >/dev/null <<< "$ruleset_body"
fi

cat >&2 <<MSG

GitHub Actions is connected.
  Work on feature branches and open pull requests to '$branch': tests and a
  read-only plan run on the PR, and merging deploys to production.
  Optional: required reviewers on the '$env_name' environment (manual approval
  before each deploy) or required approvals in the '$ruleset_name' ruleset.
MSG
if [[ "$(cfg GITHUB_MODE)" == "token" ]]; then
  echo "  GITHUB_MODE=token: add the secret with: gh secret set DEVOPS_AGENT_GITHUB_TOKEN --repo $repo --env $env_name" >&2
fi
