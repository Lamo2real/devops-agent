from datetime import datetime, timezone

import boto3
import pytest
from botocore.stub import Stubber

from devops_agent_lambdas import usage_guard as ug


@pytest.fixture(autouse=True)
def lambda_env(monkeypatch):
    monkeypatch.setenv("METRIC_NAMESPACE", "DevOpsAgent/Usage")
    monkeypatch.setenv("DIMENSION_VALUE", "acme-orders-pilot")


def test_publishes_usage_and_percent_of_limit(monkeypatch):
    agent = boto3.client("devops-agent", region_name="eu-north-1")
    cw = boto3.client("cloudwatch", region_name="eu-north-1")
    monkeypatch.setattr(ug, "_CLIENTS", {"devops-agent": agent, "cloudwatch": cw})
    usage = {
        "monthlyAccountInvestigationHours": {"limit": 100, "usage": 12.5},
        "monthlyAccountEvaluationHours": {"limit": 0, "usage": 1.0},
        "usagePeriodStartTime": datetime(2026, 11, 1, tzinfo=timezone.utc),
        "usagePeriodEndTime": datetime(2026, 12, 1, tzinfo=timezone.utc),
    }
    dims = [{"Name": "Deployment", "Value": "acme-orders-pilot"}]
    with Stubber(agent) as a, Stubber(cw) as c:
        a.add_response("get_account_usage", usage, {})
        c.add_response("put_metric_data", {}, {
            "Namespace": "DevOpsAgent/Usage",
            "MetricData": [
                {"MetricName": "InvestigationHours", "Dimensions": dims, "Value": 12.5, "Unit": "None"},
                {"MetricName": "InvestigationHoursPercentOfLimit", "Dimensions": dims, "Value": 12.5, "Unit": "Percent"},
                {"MetricName": "EvaluationHours", "Dimensions": dims, "Value": 1.0, "Unit": "None"},
            ],
        })
        result = ug.handler({})
    assert result["metrics"]["InvestigationHours"] == 12.5


def test_no_usage_publishes_nothing(monkeypatch):
    agent = boto3.client("devops-agent", region_name="eu-north-1")
    monkeypatch.setattr(ug, "_CLIENTS", {"devops-agent": agent, "cloudwatch": object()})
    with Stubber(agent) as a:
        a.add_response("get_account_usage", {
            "usagePeriodStartTime": datetime(2026, 11, 1, tzinfo=timezone.utc),
            "usagePeriodEndTime": datetime(2026, 12, 1, tzinfo=timezone.utc),
        }, {})
        assert ug.handler({}) == {"status": "ok", "metrics": {}}
