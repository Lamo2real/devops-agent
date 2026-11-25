import json
import urllib.error

import pytest

import config as c

EXAMPLE = (c.ROOT / "project.env.example").read_text()


def env(**overrides):
    values = c.parse_env_file(EXAMPLE)
    values.update({k: str(v) for k, v in overrides.items()})
    return values


def errors_of(values):
    with pytest.raises(c.ConfigError) as exc:
        c.load(values)
    return "\n".join(exc.value.errors)


def test_example_file_is_valid():
    cfg = c.load(env())
    assert cfg["AWS_REGION"] == "eu-north-1"
    assert cfg["ALARM_NAME_PREFIXES"] == ["symptom-"]
    assert cfg.state_bucket == "acme-orders-tfstate-123456789012"
    assert cfg.name_prefix == "acme-orders-pilot"
    assert cfg["AGENT_SPACE_DESCRIPTION"] == "Acme AB acme-orders (pilot)"


def test_every_schema_key_is_documented_in_example():
    documented = set(c.parse_env_file(EXAMPLE))
    assert documented == set(c.SCHEMA_BY_KEY)


def test_parser_handles_quotes_comments_and_export():
    parsed = c.parse_env_file('export A_B="x # y"\nC=v # note\n# c\n\nD=\'q\'\nE=http://x/#frag\nF="Acme AB" # comment\n')
    assert parsed == {"A_B": "x # y", "C": "v", "D": "q", "E": "http://x/#frag", "F": "Acme AB"}
    with pytest.raises(c.ConfigError, match="unterminated"):
        c.parse_env_file('A="x\n')
    with pytest.raises(c.ConfigError, match="after the closing quote"):
        c.parse_env_file('A="x" y\n')


def test_bom_is_ignored(tmp_path):
    f = tmp_path / "project.env"
    f.write_text(EXAMPLE, encoding="utf-8-sig")
    assert c.load_file(f)["PROJECT_NAME"] == "acme-orders"


def test_name_length_and_tag_characters():
    assert "36 or less" in errors_of(env(PROJECT_NAME="a" * 30, ENVIRONMENT="nonprod"))
    assert c.load(env(CUSTOMER_NAME="Åhléns Göteborg AB"))["CUSTOMER_NAME"] == "Åhléns Göteborg AB"
    assert "CUSTOMER_NAME" in errors_of(env(CUSTOMER_NAME="Acme & Co"))


def test_offline_render_needs_no_token():
    out = c.render_tfvars(c.load(env(GITHUB_MODE="token")), resolve_github=False, github_token=None)
    assert out["github_repositories"][0]["name"] == "orders-service"


def test_reserved_concurrency_default_is_no_reservation():
    assert c.render_tfvars(c.load(env()))["alarm_trigger_reserved_concurrency"] == -1
    assert c.render_tfvars(c.load(env(ALARM_TRIGGER_RESERVED_CONCURRENCY="5")))["alarm_trigger_reserved_concurrency"] == 5


def test_parser_rejects_duplicates_and_garbage():
    with pytest.raises(c.ConfigError):
        c.parse_env_file("A=1\nA=2\n")
    with pytest.raises(c.ConfigError):
        c.parse_env_file("not a line\n")
    with pytest.raises(c.ConfigError):
        c.parse_env_file("lower=1\n")


@pytest.mark.parametrize("secret", [
    "ghp_" + "a" * 36,
    "github_pat_" + "B" * 40,
    "AKIA" + "ABCDEFGHIJKLMNOP",
    "xoxb-1234567890-abc",
])
def test_secrets_are_refused(secret):
    assert "looks like a secret" in errors_of(env(CUSTOMER_NAME=secret))


def test_required_and_format_errors_are_all_reported():
    values = env(AWS_ACCOUNT_ID="123", PROJECT_NAME="Bad_Name")
    del values["CUSTOMER_NAME"]
    text = errors_of(values)
    assert "AWS_ACCOUNT_ID" in text and "PROJECT_NAME" in text and "CUSTOMER_NAME: required" in text


def test_unknown_key_is_an_error():
    assert "unknown setting" in errors_of(env(GITHUB_REPO="x"))


def test_cross_field_rules():
    assert "IDC_INSTANCE_ARN" in errors_of(env(OPERATOR_AUTH="idc"))
    assert "GITHUB_REPOS" in errors_of(env(GITHUB_MODE="app", GITHUB_REPOS=""))
    assert "duplicates" in errors_of(env(GITHUB_MODE="token", GITHUB_REPOS="a,a"))
    assert "DEDUP_WINDOW_MINUTES" in errors_of(env(DEDUP_WINDOW_MINUTES="0"))
    assert "monitoring account" in errors_of(env(SOURCE_ACCOUNT_ROLE_ARNS="arn:aws:iam::123456789012:role/x"))


def test_warnings_for_non_eu_region_and_directed_actions():
    cfg = c.load(env(AWS_REGION="us-east-1", DIRECTED_ACTIONS_ENABLED="true"))
    assert any("outside the EU" in w for w in cfg.warnings)
    assert any("DIRECTED_ACTIONS_ENABLED" in w for w in cfg.warnings)


def test_bool_parsing():
    assert c.load(env(SKILLS_ENABLED="no"))["SKILLS_ENABLED"] is False
    assert "expected true or false" in errors_of(env(SKILLS_ENABLED="maybe"))


def test_backend_render():
    text = c.render_backend(c.load(env(TF_STATE_BUCKET="my-bucket")))
    assert 'bucket       = "my-bucket"' in text
    assert 'key          = "devops-agent/acme-orders-pilot.tfstate"' in text
    assert "use_lockfile = true" in text


def test_tfvars_github_off_needs_no_network():
    def boom(*_):
        raise AssertionError("no network expected")
    out = c.render_tfvars(c.load(env()), http_get=boom, aws_cli=boom)
    assert out["github_mode"] == "off" and out["github_repositories"] == []
    assert out["tags"]["Customer"] == "Acme AB"
    json.dumps(out)


def test_tfvars_token_mode_resolves_repo_ids():
    calls = []

    def http_get(url, headers):
        calls.append((url, headers.get("Authorization")))
        return {"id": 1000 + len(calls)}

    out = c.render_tfvars(c.load(env(GITHUB_MODE="token")), github_token="tkn", http_get=http_get)
    assert out["github_repositories"] == [
        {"name": "orders-service", "id": "1001"},
        {"name": "platform-infra", "id": "1002"},
    ]
    assert calls[0] == ("https://api.github.com/repos/acme-ab/orders-service", "Bearer tkn")
    assert out["github_service_id"] == ""  # created by Terraform


def test_tfvars_token_mode_requires_token():
    with pytest.raises(c.ConfigError, match="DEVOPS_AGENT_GITHUB_TOKEN"):
        c.render_tfvars(c.load(env(GITHUB_MODE="token")), github_token=None)


def test_tfvars_app_mode_finds_registration():
    def aws_cli(args):
        assert args[:2] == ["devops-agent", "list-services"]
        return {"services": [
            {"serviceId": "svc-other", "serviceType": "github", "additionalServiceDetails": {"github": {"owner": "someone"}}},
            {"serviceId": "svc-1", "serviceType": "github", "additionalServiceDetails": {"github": {"owner": "Acme-AB"}}},
        ]}

    out = c.render_tfvars(c.load(env(GITHUB_MODE="app")), http_get=lambda u, h: {"id": 7}, aws_cli=aws_cli)
    assert out["github_service_id"] == "svc-1"


def test_tfvars_app_mode_without_registration_explains_next_step():
    with pytest.raises(c.ConfigError, match="Register GitHub once"):
        c.render_tfvars(c.load(env(GITHUB_MODE="app")), http_get=lambda u, h: {"id": 7}, aws_cli=lambda a: {"services": []})


def test_repo_lookup_errors_hint_at_token():
    def http_get(url, headers):
        raise urllib.error.HTTPError(url, 404, "nf", {}, None)

    with pytest.raises(c.ConfigError, match="private repository"):
        c.resolve_repo_ids("o", ["r"], None, http_get)


def test_bootstrap_requires_deploy_repository():
    with pytest.raises(c.ConfigError, match="DEPLOY_GITHUB_REPOSITORY"):
        c.render_bootstrap_tfvars(c.load(env(DEPLOY_GITHUB_REPOSITORY="")))
    out = c.render_bootstrap_tfvars(c.load(env()))
    assert out["github_repository"] == "acme-ab/devops-agent"
    assert out["create_github_oidc_provider"] is True
    assert out["github_token_mode"] is False
    assert c.render_bootstrap_tfvars(c.load(env(GITHUB_MODE="token")))["github_token_mode"] is True


def test_cli_get_and_validate(tmp_path, capsys):
    f = tmp_path / "project.env"
    f.write_text(EXAMPLE)
    assert c.main(["--env-file", str(f), "validate"]) == 0
    assert c.main(["--env-file", str(f), "get", "ALARM_NAME_PREFIXES"]) == 0
    assert c.main(["--env-file", str(f), "get", "CREATE_SMOKE_TEST_ALARM"]) == 0
    assert capsys.readouterr().out.splitlines() == ["symptom-", "true"]
    assert c.main(["--env-file", str(tmp_path / "missing.env"), "validate"]) == 2


def test_repo_entries_with_ids_skip_lookup():
    def http_get(url, headers):
        assert url.endswith("/platform-infra")
        return {"id": 55}

    out = c.render_tfvars(c.load(env(GITHUB_MODE="app", GITHUB_SERVICE_ID="svc", GITHUB_REPOS="orders-service:123,platform-infra")),
                          http_get=http_get)
    assert out["github_repositories"] == [{"name": "orders-service", "id": "123"}, {"name": "platform-infra", "id": "55"}]
    assert "duplicates" in errors_of(env(GITHUB_MODE="app", GITHUB_REPOS="a:1,a:2"))
