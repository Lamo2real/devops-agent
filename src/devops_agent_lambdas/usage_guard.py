"""Publish AWS DevOps Agent account usage as CloudWatch metrics.

Runs every hour. GetAccountUsage returns the hours used this month per usage
type, plus the account limits. A CloudWatch alarm (Terraform) on
InvestigationHours notifies the alert topic before the bill surprises anyone.
The agent is billed per second of active work (about USD 30 per agent hour).
"""

from __future__ import annotations

import logging
import os
from typing import Any

import boto3
from botocore.config import Config

LOG = logging.getLogger(__name__)
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

USAGE_FIELDS = {
    "monthlyAccountInvestigationHours": "InvestigationHours",
    "monthlyAccountEvaluationHours": "EvaluationHours",
    "monthlyAccountSystemLearningHours": "SystemLearningHours",
    "monthlyAccountOnDemandHours": "OnDemandHours",
}

_CLIENTS: dict[str, Any] = {}


def client(name: str):
    if name not in _CLIENTS:
        _CLIENTS[name] = boto3.client(name, config=Config(retries={"mode": "standard", "max_attempts": 5}))
    return _CLIENTS[name]


def build_metrics(usage: dict[str, Any], deployment: str) -> list[dict[str, Any]]:
    dimensions = [{"Name": "Deployment", "Value": deployment}]
    metrics: list[dict[str, Any]] = []
    for field, metric in USAGE_FIELDS.items():
        value = usage.get(field)
        if not value:
            continue
        used = float(value.get("usage", 0.0))
        limit = float(value.get("limit", 0) or 0)
        metrics.append({"MetricName": metric, "Dimensions": dimensions, "Value": used, "Unit": "None"})
        if limit > 0:
            metrics.append({
                "MetricName": f"{metric}PercentOfLimit",
                "Dimensions": dimensions,
                "Value": round(100.0 * used / limit, 2),
                "Unit": "Percent",
            })
    return metrics


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    namespace = os.environ["METRIC_NAMESPACE"]
    deployment = os.environ["DIMENSION_VALUE"]
    usage = client("devops-agent").get_account_usage()
    metrics = build_metrics(usage, deployment)
    if metrics:
        client("cloudwatch").put_metric_data(Namespace=namespace, MetricData=metrics)
    summary = {m["MetricName"]: m["Value"] for m in metrics}
    LOG.info("published usage %s", summary)
    return {"status": "ok", "metrics": summary}
