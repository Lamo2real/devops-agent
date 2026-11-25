#!/usr/bin/env python3
"""Load and validate project.env, and render Terraform inputs from it.

project.env is the single place a customer configures this template. This
script is the only code that reads it, so every rule about the configuration
lives here:

    python3 scripts/config.py validate
    python3 scripts/config.py get AWS_REGION
    python3 scripts/config.py backend   --out build/backend.hcl
    python3 scripts/config.py bootstrap --out build/bootstrap.tfvars.json
    python3 scripts/config.py tfvars    --out build/terraform.tfvars.json

Only the Python standard library is used, so it runs anywhere Python 3.10+ is
installed. The `tfvars` command may call the AWS CLI (to find an existing
GitHub registration) and the GitHub REST API (to turn repository names into
repository ids).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ENV_FILE = ROOT / "project.env"
GITHUB_TOKEN_ENV = "DEVOPS_AGENT_GITHUB_TOKEN"

# Values that look like credentials are refused: project.env is committed.
SECRET_PATTERNS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),  # GitHub classic tokens
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),  # GitHub fine-grained tokens
    re.compile(r"(?<![A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"),  # AWS access key ids
    re.compile(r"xox[abposr]-[A-Za-z0-9-]{10,}"),  # Slack tokens
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]

PRIORITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "MINIMAL")
EU_REGIONS = ("eu-north-1", "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3", "eu-south-1", "eu-south-2", "eu-central-2")


class ConfigError(Exception):
    """Raised with every problem found, so the user can fix them in one go."""

    def __init__(self, errors: list[str]):
        super().__init__("\n".join(errors))
        self.errors = errors


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #

def parse_env_file(text: str) -> dict[str, str]:
    """Parse KEY=value lines. Supports comments, blank lines, optional quotes
    and `export KEY=value`. Inline comments are only stripped when preceded by
    whitespace (`KEY=a # note`), so values such as URLs with # survive."""
    values: dict[str, str] = {}
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            raise ConfigError([f"project.env line {lineno}: expected KEY=value, got {raw!r}"])
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ConfigError([f"project.env line {lineno}: invalid key {key!r} (use UPPER_SNAKE_CASE)"])
        value = value.strip()
        if value[:1] in ("\"", "'"):
            quote = value[0]
            end = value.find(quote, 1)
            if end == -1:
                raise ConfigError([f"project.env line {lineno}: unterminated quote"])
            rest = value[end + 1:].strip()
            if rest and not rest.startswith("#"):
                raise ConfigError([f"project.env line {lineno}: unexpected text after the closing quote"])
            value = value[1:end]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        if key in values:
            raise ConfigError([f"project.env line {lineno}: {key} is set twice"])
        values[key] = value
    return values


def split_list(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_bool(value: str) -> bool:
    lowered = value.strip().lower()
    if lowered in ("true", "yes", "1", "on"):
        return True
    if lowered in ("false", "no", "0", "off", ""):
        return False
    raise ValueError(f"expected true or false, got {value!r}")


# --------------------------------------------------------------------------- #
# Schema
# --------------------------------------------------------------------------- #

@dataclass
class Var:
    key: str
    kind: str = "str"  # str | bool | int | list
    default: str | None = None  # None means required
    choices: tuple[str, ...] = ()
    pattern: str | None = None  # applied to str values and each list item
    help: str = ""


SCHEMA: list[Var] = [
    Var("PROJECT_NAME", pattern=r"[a-z][a-z0-9-]{1,30}[a-z0-9]", help="lowercase letters, digits and -, 3 to 32 characters"),
    # Used as an AWS tag value: letters (åäö too), digits, spaces and _ . : / = + - @
    Var("CUSTOMER_NAME", pattern=r"[\w .:/=+\-@]{1,100}", help="letters, digits, spaces and _ . : / = + - @"),
    Var("AWS_ACCOUNT_ID", pattern=r"\d{12}", help="12 digits"),
    Var("AWS_REGION", default="eu-north-1", pattern=r"[a-z]{2}(-[a-z]+)+-\d"),
    Var("ENVIRONMENT", default="pilot", pattern=r"[a-z][a-z0-9-]{0,15}"),
    Var("TF_STATE_BUCKET", default="", pattern=r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]"),
    Var("DEPLOY_GITHUB_REPOSITORY", default="", pattern=r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", help="owner/repo"),
    Var("DEPLOY_GITHUB_BRANCH", default="main", pattern=r"[A-Za-z0-9._/-]+"),
    Var("CREATE_GITHUB_OIDC_PROVIDER", kind="bool", default="true"),
    # Optional override; `make bootstrap` detects it with the gh CLI.
    Var("DEPLOY_GITHUB_OIDC_SUB_PREFIX", default="", pattern=r"repo:[^:\s]+", help="repo:owner/repo or repo:owner@id/repo@id"),
    Var("AGENT_SPACE_DESCRIPTION", default=""),
    Var("OPERATOR_AUTH", default="iam", choices=("iam", "idc")),
    Var("IDC_INSTANCE_ARN", default="", pattern=r"arn:aws:sso:::instance/(sso)?ins-[a-zA-Z0-9-.]{16}"),
    Var("DIRECTED_ACTIONS_ENABLED", kind="bool", default="false"),
    Var("AGENT_LOCALE", default="", pattern=r"[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*", help="BCP 47, e.g. sv-SE"),
    Var("GITHUB_MODE", default="off", choices=("off", "app", "token")),
    Var("GITHUB_OWNER", default="", pattern=r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})"),
    Var("GITHUB_OWNER_TYPE", default="organization", choices=("organization", "user")),
    Var("GITHUB_REPOS", kind="list", default="", pattern=r"[A-Za-z0-9_.-]{1,100}(:\d{1,20})?", help="name or name:repo_id"),
    Var("GITHUB_SERVICE_ID", default="", pattern=r"[A-Za-z0-9_-]{1,255}"),
    Var("ALARM_NAME_PREFIXES", kind="list", default="symptom-", pattern=r"[^,\s][^,]{0,254}"),
    Var("DEDUP_WINDOW_MINUTES", kind="int", default="60"),
    Var("INVESTIGATION_PRIORITY", default="HIGH", choices=PRIORITIES),
    Var("CREATE_SMOKE_TEST_ALARM", kind="bool", default="true"),
    Var("ALARM_TRIGGER_RESERVED_CONCURRENCY", kind="int", default="0"),
    Var("ALERT_EMAILS", kind="list", default="", pattern=r"[^@\s,]+@[^@\s,]+\.[^@\s,]+"),
    Var("MONTHLY_INVESTIGATION_HOURS_ALERT", kind="int", default="20"),
    Var("EKS_CLUSTER_NAMES", kind="list", default="", pattern=r"[0-9A-Za-z][A-Za-z0-9_-]{0,99}"),
    Var("SOURCE_ACCOUNT_ROLE_ARNS", kind="list", default="", pattern=r"arn:aws:iam::\d{12}:role/[\w+=,.@/-]{1,512}"),
    Var("SKILLS_ENABLED", kind="bool", default="true"),
    Var("WEEKLY_REPORT_ENABLED", kind="bool", default="false"),
]
SCHEMA_BY_KEY = {v.key: v for v in SCHEMA}


@dataclass
class Config:
    values: dict[str, Any]
    warnings: list[str] = field(default_factory=list)

    def __getitem__(self, key: str) -> Any:
        return self.values[key]

    @property
    def state_bucket(self) -> str:
        return self["TF_STATE_BUCKET"] or f"{self['PROJECT_NAME']}-tfstate-{self['AWS_ACCOUNT_ID']}"

    @property
    def name_prefix(self) -> str:
        return f"{self['PROJECT_NAME']}-{self['ENVIRONMENT']}"


def load(env: dict[str, str]) -> Config:
    """Validate raw values against SCHEMA and the cross-field rules."""
    errors: list[str] = []
    warnings: list[str] = []
    values: dict[str, Any] = {}

    unknown = sorted(set(env) - set(SCHEMA_BY_KEY))
    for key in unknown:
        errors.append(f"{key}: unknown setting (typo? see project.env.example)")

    for key, raw in env.items():
        for pattern in SECRET_PATTERNS:
            if pattern.search(raw):
                errors.append(
                    f"{key}: looks like a secret. project.env is committed to git; "
                    f"pass secrets as environment variables or CI secrets instead"
                )
                break

    for var in SCHEMA:
        raw = env.get(var.key)
        if raw is None or (raw == "" and var.default is not None):
            if var.default is None:
                errors.append(f"{var.key}: required" + (f" ({var.help})" if var.help else ""))
                continue
            raw = var.default
        elif raw == "" and var.default is None:
            errors.append(f"{var.key}: required" + (f" ({var.help})" if var.help else ""))
            continue

        try:
            if var.kind == "bool":
                values[var.key] = parse_bool(raw)
                continue
            if var.kind == "int":
                number = int(raw)
                if number < 0:
                    raise ValueError("must be 0 or more")
                values[var.key] = number
                continue
            items = split_list(raw) if var.kind == "list" else ([raw] if raw else [])
        except ValueError as exc:
            errors.append(f"{var.key}: {exc}")
            continue

        bad = False
        for item in items:
            if var.choices and item not in var.choices:
                errors.append(f"{var.key}: {item!r} is not one of {', '.join(var.choices)}")
                bad = True
            elif var.pattern and not re.fullmatch(var.pattern, item):
                hint = f" ({var.help})" if var.help else ""
                errors.append(f"{var.key}: {item!r} has an invalid format{hint}")
                bad = True
        if not bad:
            values[var.key] = items if var.kind == "list" else raw

    if errors:
        raise ConfigError(errors)

    # Cross-field rules.
    prefix = f"{values['PROJECT_NAME']}-{values['ENVIRONMENT']}"
    if len(prefix) > 36:
        errors.append(
            f"PROJECT_NAME + ENVIRONMENT: '{prefix}' is {len(prefix)} characters; keep it at 36 or less "
            "(IAM role names such as DevOpsAgentRole-WebappAdmin-<name> are limited to 64)"
        )
    if values["ALARM_TRIGGER_RESERVED_CONCURRENCY"] > 1000:
        errors.append("ALARM_TRIGGER_RESERVED_CONCURRENCY: must be between 0 (no reservation) and 1000")
    if values["OPERATOR_AUTH"] == "idc" and not values["IDC_INSTANCE_ARN"]:
        errors.append("IDC_INSTANCE_ARN: required when OPERATOR_AUTH=idc")
    if values["GITHUB_MODE"] != "off":
        if not values["GITHUB_OWNER"]:
            errors.append(f"GITHUB_OWNER: required when GITHUB_MODE={values['GITHUB_MODE']}")
        if not values["GITHUB_REPOS"]:
            errors.append(f"GITHUB_REPOS: list at least one repository when GITHUB_MODE={values['GITHUB_MODE']}")
        names = [repo_name(r) for r in values["GITHUB_REPOS"]]
        if len(set(names)) != len(names):
            errors.append("GITHUB_REPOS: contains duplicates")
    if values["GITHUB_MODE"] != "app" and values["GITHUB_SERVICE_ID"]:
        warnings.append("GITHUB_SERVICE_ID is ignored unless GITHUB_MODE=app")
    if not 1 <= values["DEDUP_WINDOW_MINUTES"] <= 10080:
        errors.append("DEDUP_WINDOW_MINUTES: must be between 1 and 10080 (one week)")
    if values["MONTHLY_INVESTIGATION_HOURS_ALERT"] < 1:
        errors.append("MONTHLY_INVESTIGATION_HOURS_ALERT: must be at least 1")
    if not values["ALARM_NAME_PREFIXES"]:
        errors.append("ALARM_NAME_PREFIXES: list at least one prefix")
    if values["DIRECTED_ACTIONS_ENABLED"]:
        warnings.append(
            "DIRECTED_ACTIONS_ENABLED=true: the agent may change AWS resources after an operator approves. "
            "Recommended only after the pilot."
        )
    if values["AWS_REGION"] not in EU_REGIONS:
        warnings.append(
            f"AWS_REGION={values['AWS_REGION']} is outside the EU. Swedish customers normally need eu-north-1, "
            "eu-central-1 or eu-west-1 to keep data and inference in the EU."
        )
    for arn in values["SOURCE_ACCOUNT_ROLE_ARNS"]:
        if arn.split(":")[4] == values["AWS_ACCOUNT_ID"]:
            errors.append(f"SOURCE_ACCOUNT_ROLE_ARNS: {arn} is in the monitoring account; it is associated automatically")
    if len(set(values["SOURCE_ACCOUNT_ROLE_ARNS"])) != len(values["SOURCE_ACCOUNT_ROLE_ARNS"]):
        errors.append("SOURCE_ACCOUNT_ROLE_ARNS: contains duplicates")
    if not values["AGENT_SPACE_DESCRIPTION"]:
        values["AGENT_SPACE_DESCRIPTION"] = f"{values['CUSTOMER_NAME']} {values['PROJECT_NAME']} ({values['ENVIRONMENT']})"

    if errors:
        raise ConfigError(errors)
    return Config(values=values, warnings=warnings)


def load_file(path: Path) -> Config:
    if not path.exists():
        raise ConfigError([f"{path.name} not found. Run: cp project.env.example project.env"])
    return load(parse_env_file(path.read_text(encoding="utf-8-sig")))


# --------------------------------------------------------------------------- #
# GitHub resolution (only for the main stack)
# --------------------------------------------------------------------------- #

HttpGet = Callable[[str, dict[str, str]], Any]
AwsCli = Callable[[list[str]], Any]


def _http_get_json(url: str, headers: dict[str, str]) -> Any:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:  # noqa: S310 (fixed https host)
        return json.loads(response.read().decode("utf-8"))


def _aws_cli_json(args: list[str]) -> Any:
    result = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"aws {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return json.loads(result.stdout or "{}")


def repo_name(entry: str) -> str:
    return entry.split(":", 1)[0]


def resolve_repo_ids(owner: str, repos: list[str], token: str | None, http_get: HttpGet = _http_get_json) -> dict[str, str]:
    """Return {repo_name: numeric_repo_id}. Entries written as name:id are used
    as is; the others are looked up with the GitHub REST API."""
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "devops-agent-template"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    ids: dict[str, str] = {}
    errors: list[str] = []
    for entry in repos:
        repo = repo_name(entry)
        if ":" in entry:
            ids[repo] = entry.split(":", 1)[1]
            continue
        try:
            data = http_get(f"https://api.github.com/repos/{owner}/{repo}", headers)
            ids[repo] = str(data["id"])
        except urllib.error.HTTPError as exc:
            hint = (
                f" (private repository? set {GITHUB_TOKEN_ENV}, or write it as {repo}:<repo id>; "
                f"find the id with: gh api repos/{owner}/{repo} --jq .id)"
            )
            errors.append(f"GITHUB_REPOS: cannot read {owner}/{repo}: HTTP {exc.code}{hint}")
        except (urllib.error.URLError, KeyError, ValueError) as exc:
            errors.append(f"GITHUB_REPOS: cannot read {owner}/{repo}: {exc}")
    if errors:
        raise ConfigError(errors)
    return ids


def find_github_service_id(owner: str, region: str, aws_cli: AwsCli = _aws_cli_json) -> str:
    """Find the account-level GitHub registration for `owner`."""
    services: list[dict[str, Any]] = []
    token: str | None = None
    while True:
        args = ["devops-agent", "list-services", "--filter-service-type", "github", "--region", region]
        if token:
            args += ["--next-token", token]
        page = aws_cli(args)
        services.extend(page.get("services", []))
        token = page.get("nextToken")
        if not token:
            break
    matches = [
        s["serviceId"]
        for s in services
        if (s.get("additionalServiceDetails", {}).get("github", {}) or {}).get("owner", "").lower() == owner.lower()
    ]
    if len(matches) == 1:
        return matches[0]
    found = ", ".join(sorted({(s.get("additionalServiceDetails", {}).get("github", {}) or {}).get("owner", "?") for s in services})) or "none"
    if not matches:
        raise ConfigError([
            f"GITHUB_MODE=app: no GitHub registration for owner {owner!r} in {region} (found: {found}). "
            "Register GitHub once in the AWS DevOps Agent console (Capability providers > GitHub), "
            "or set GITHUB_MODE=token."
        ])
    raise ConfigError([f"GITHUB_MODE=app: several registrations for {owner!r}; set GITHUB_SERVICE_ID to one of {', '.join(matches)}"])


# --------------------------------------------------------------------------- #
# Renderers
# --------------------------------------------------------------------------- #

def common_tags(cfg: Config) -> dict[str, str]:
    return {
        "Project": cfg["PROJECT_NAME"],
        "Customer": cfg["CUSTOMER_NAME"],
        "Environment": cfg["ENVIRONMENT"],
        "ManagedBy": "terraform",
        "Template": "aws-devops-agent-serverless",
    }


def render_backend(cfg: Config) -> str:
    return "\n".join([
        f'bucket       = "{cfg.state_bucket}"',
        f'key          = "devops-agent/{cfg.name_prefix}.tfstate"',
        f'region       = "{cfg["AWS_REGION"]}"',
        "encrypt      = true",
        "use_lockfile = true",
        "",
    ])


def render_bootstrap_tfvars(cfg: Config) -> dict[str, Any]:
    if not cfg["DEPLOY_GITHUB_REPOSITORY"]:
        raise ConfigError(["DEPLOY_GITHUB_REPOSITORY: required for `make bootstrap` (owner/repo of your fork)"])
    return {
        "project_name": cfg["PROJECT_NAME"],
        "environment": cfg["ENVIRONMENT"],
        "aws_account_id": cfg["AWS_ACCOUNT_ID"],
        "aws_region": cfg["AWS_REGION"],
        "state_bucket_name": cfg.state_bucket,
        "github_repository": cfg["DEPLOY_GITHUB_REPOSITORY"],
        "create_github_oidc_provider": cfg["CREATE_GITHUB_OIDC_PROVIDER"],
        "github_token_mode": cfg["GITHUB_MODE"] == "token",
        "github_oidc_sub_prefix": cfg["DEPLOY_GITHUB_OIDC_SUB_PREFIX"],
        "tags": common_tags(cfg),
    }


def render_tfvars(
    cfg: Config,
    *,
    resolve_github: bool = True,
    github_token: str | None = None,
    http_get: HttpGet = _http_get_json,
    aws_cli: AwsCli = _aws_cli_json,
) -> dict[str, Any]:
    mode = cfg["GITHUB_MODE"]
    repos: list[dict[str, str]] = []
    service_id = ""
    if mode != "off":
        if mode == "token" and not github_token and resolve_github:
            raise ConfigError([f"GITHUB_MODE=token: set the {GITHUB_TOKEN_ENV} environment variable (CI: repository secret)"])
        if resolve_github:
            ids = resolve_repo_ids(cfg["GITHUB_OWNER"], cfg["GITHUB_REPOS"], github_token, http_get)
            repos = [{"name": repo_name(e), "id": ids[repo_name(e)]} for e in cfg["GITHUB_REPOS"]]
            if mode == "app":
                service_id = cfg["GITHUB_SERVICE_ID"] or find_github_service_id(cfg["GITHUB_OWNER"], cfg["AWS_REGION"], aws_cli)
        else:  # offline rendering (tests, plan without network)
            repos = [{"name": repo_name(e), "id": e.split(":", 1)[1] if ":" in e else "0"} for e in cfg["GITHUB_REPOS"]]
            service_id = cfg["GITHUB_SERVICE_ID"] or ("offline" if mode == "app" else "")

    return {
        "project_name": cfg["PROJECT_NAME"],
        "environment": cfg["ENVIRONMENT"],
        "aws_account_id": cfg["AWS_ACCOUNT_ID"],
        "aws_region": cfg["AWS_REGION"],
        "agent_space_description": cfg["AGENT_SPACE_DESCRIPTION"],
        "agent_locale": cfg["AGENT_LOCALE"],
        "operator_auth": cfg["OPERATOR_AUTH"],
        "idc_instance_arn": cfg["IDC_INSTANCE_ARN"],
        "directed_actions_enabled": cfg["DIRECTED_ACTIONS_ENABLED"],
        "github_mode": mode,
        "github_owner": cfg["GITHUB_OWNER"],
        "github_owner_type": cfg["GITHUB_OWNER_TYPE"],
        "github_repositories": repos,
        "github_service_id": service_id,
        "alarm_name_prefixes": cfg["ALARM_NAME_PREFIXES"],
        "dedup_window_minutes": cfg["DEDUP_WINDOW_MINUTES"],
        "investigation_priority": cfg["INVESTIGATION_PRIORITY"],
        "create_smoke_test_alarm": cfg["CREATE_SMOKE_TEST_ALARM"],
        "alarm_trigger_reserved_concurrency": cfg["ALARM_TRIGGER_RESERVED_CONCURRENCY"] or -1,
        "alert_emails": cfg["ALERT_EMAILS"],
        "monthly_investigation_hours_alert": cfg["MONTHLY_INVESTIGATION_HOURS_ALERT"],
        "eks_cluster_names": cfg["EKS_CLUSTER_NAMES"],
        "source_account_role_arns": cfg["SOURCE_ACCOUNT_ROLE_ARNS"],
        "skills_enabled": cfg["SKILLS_ENABLED"],
        "weekly_report_enabled": cfg["WEEKLY_REPORT_ENABLED"],
        "tags": common_tags(cfg),
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _write(path: str | None, content: str) -> None:
    if not path:
        sys.stdout.write(content)
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    try:
        target.chmod(0o600)
    except OSError:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", default=os.environ.get("PROJECT_ENV_FILE", str(DEFAULT_ENV_FILE)))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    get = sub.add_parser("get")
    get.add_argument("key")
    for name in ("backend", "bootstrap", "tfvars"):
        p = sub.add_parser(name)
        p.add_argument("--out")
        if name == "tfvars":
            p.add_argument("--offline", action="store_true", help="do not call GitHub or AWS (placeholder repo ids)")
    args = parser.parse_args(argv)

    try:
        cfg = load_file(Path(args.env_file))
        for warning in cfg.warnings:
            print(f"warning: {warning}", file=sys.stderr)
        if args.command == "validate":
            print(f"{Path(args.env_file).name} is valid ({cfg.name_prefix}, {cfg['AWS_REGION']})", file=sys.stderr)
        elif args.command == "get":
            if args.key == "STATE_BUCKET":
                print(cfg.state_bucket)
            elif args.key == "NAME_PREFIX":
                print(cfg.name_prefix)
            elif args.key in cfg.values:
                value = cfg[args.key]
                print(",".join(value) if isinstance(value, list) else str(value).lower() if isinstance(value, bool) else value)
            else:
                raise ConfigError([f"unknown key {args.key}"])
        elif args.command == "backend":
            _write(args.out, render_backend(cfg))
        elif args.command == "bootstrap":
            _write(args.out, json.dumps(render_bootstrap_tfvars(cfg), indent=2) + "\n")
        elif args.command == "tfvars":
            token = os.environ.get(GITHUB_TOKEN_ENV) or os.environ.get("GITHUB_TOKEN") or None
            if cfg["GITHUB_MODE"] == "token":
                token = os.environ.get(GITHUB_TOKEN_ENV) or None
            rendered = render_tfvars(cfg, resolve_github=not args.offline, github_token=token)
            _write(args.out, json.dumps(rendered, indent=2) + "\n")
    except ConfigError as exc:
        print(f"Configuration error in {Path(args.env_file).name}:", file=sys.stderr)
        for error in exc.errors:
            print(f"  - {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
