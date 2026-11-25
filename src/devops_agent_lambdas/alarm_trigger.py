"""Start an AWS DevOps Agent investigation when a symptom alarm fires.

Trigger: EventBridge rule on "CloudWatch Alarm State Change" events whose
alarm name starts with one of ALARM_NAME_PREFIXES and whose new state is ALARM.

Design notes (from the Norway lab, 30 Oct 2026):
* Flapping alarms created 7 to 12 extra incidents. We skip a new investigation
  while one for the same alarm, created within DEDUP_WINDOW_MINUTES, is open.
* EventBridge and Lambda retry on failure. The client token is derived from
  the alarm and the state change time, so a retry never creates a second task.
* If the duplicate check itself fails (for example missing permission), we
  still start the investigation: a duplicate is cheaper than a missed incident.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import urllib.parse
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

LOG = logging.getLogger(__name__)
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

OPEN_STATUSES = {"PENDING_TRIAGE", "LINKED", "PENDING_START", "IN_PROGRESS", "PENDING_CUSTOMER_APPROVAL"}
REFERENCE_SYSTEM = "CloudWatch"
MAX_TITLE = 400
MAX_DESCRIPTION = 10000
MAX_REFERENCE_TITLE = 512

_CLIENT = None


def client():
    """DevOps Agent client, created once per container (tests replace it)."""
    global _CLIENT
    if _CLIENT is None:
        _CLIENT = boto3.client(
            "devops-agent",
            config=Config(retries={"mode": "standard", "max_attempts": 5}, connect_timeout=5, read_timeout=20),
        )
    return _CLIENT


def _settings() -> dict[str, Any]:
    return {
        "agent_space_id": os.environ["AGENT_SPACE_ID"],
        "association_id": os.environ["ASSOCIATION_ID"],
        "priority": os.environ.get("INVESTIGATION_PRIORITY", "HIGH"),
        "dedup_minutes": int(os.environ.get("DEDUP_WINDOW_MINUTES", "60")),
        "prefixes": [p for p in os.environ.get("ALARM_NAME_PREFIXES", "").split(",") if p],
    }


def reference_id(alarm_arn: str) -> str:
    """Stable id for an alarm, within the 128 character API limit."""
    return "cw-alarm-" + hashlib.sha256(alarm_arn.encode()).hexdigest()[:40]


def client_token(alarm_arn: str, state_timestamp: str) -> str:
    """Same alarm + same state change = same token, so retries are idempotent."""
    return hashlib.sha256(f"{alarm_arn}|{state_timestamp}".encode()).hexdigest()[:64]


def console_url(region: str, alarm_name: str) -> str:
    quoted = urllib.parse.quote(alarm_name, safe="")
    return f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}#alarmsV2:alarm/{quoted}"


def parse_alarm_event(event: dict[str, Any]) -> dict[str, Any] | None:
    """Pull out what we need. Returns None for events we should ignore."""
    if event.get("detail-type") != "CloudWatch Alarm State Change":
        LOG.info("ignoring event with detail-type %r", event.get("detail-type"))
        return None
    detail = event.get("detail") or {}
    state = detail.get("state") or {}
    if state.get("value") != "ALARM":
        LOG.info("ignoring alarm %s in state %s", detail.get("alarmName"), state.get("value"))
        return None
    name = detail.get("alarmName")
    region = event.get("region")
    account = event.get("account")
    resources = event.get("resources") or []
    if not name or not region:
        raise ValueError("alarm event without alarmName or region")
    arn = resources[0] if resources else f"arn:aws:cloudwatch:{region}:{account}:alarm:{name}"
    previous = (detail.get("previousState") or {}).get("value", "UNKNOWN")
    config = detail.get("configuration") or {}
    return {
        "name": name,
        "arn": arn,
        "region": region,
        "account": account,
        "reason": state.get("reason", ""),
        "reason_data": state.get("reasonData", ""),
        "timestamp": state.get("timestamp") or event.get("time", ""),
        "previous": previous,
        "description": config.get("description") or "",
        "metrics": config.get("metrics") or [],
    }


def _metric_summary(metrics: list[dict[str, Any]]) -> str:
    lines = []
    for metric in metrics[:5]:
        stat = metric.get("metricStat") or {}
        m = stat.get("metric") or {}
        if m:
            dims = ", ".join(f"{k}={v}" for k, v in (m.get("dimensions") or {}).items())
            lines.append(f"- {m.get('namespace')}/{m.get('name')} ({dims}) {stat.get('stat', '')} per {stat.get('period', '?')}s")
        elif metric.get("expression"):
            lines.append(f"- expression {metric.get('id')}: {metric['expression']}")
    return "\n".join(lines) or "- (not included in the event)"


def build_task(alarm: dict[str, Any], settings: dict[str, Any]) -> dict[str, Any]:
    url = console_url(alarm["region"], alarm["name"])
    title = f"CloudWatch alarm {alarm['name']} is in ALARM"[:MAX_TITLE]
    description = "\n".join([
        f"The symptom alarm **{alarm['name']}** changed from {alarm['previous']} to ALARM at {alarm['timestamp']}.",
        "",
        f"Account: {alarm['account']}  Region: {alarm['region']}",
        f"Alarm: {alarm['arn']}",
        f"Console: {url}",
        f"Alarm description: {alarm['description'] or '(none)'}",
        f"Reason: {alarm['reason']}",
        "",
        "Metrics:",
        _metric_summary(alarm["metrics"]),
        "",
        "Investigate the root cause and write a mitigation plan. Correlate with recent deployments, "
        "commits and configuration changes. Propose code or configuration fixes as a GitHub issue; "
        "do not change resources.",
    ])[:MAX_DESCRIPTION]
    return {
        "agentSpaceId": settings["agent_space_id"],
        "taskType": "INVESTIGATION",
        "title": title,
        "description": description,
        "priority": settings["priority"],
        "reference": {
            "system": REFERENCE_SYSTEM,
            "title": f"CloudWatch alarm {alarm['name']}"[:MAX_REFERENCE_TITLE],
            "referenceId": reference_id(alarm["arn"]),
            "referenceUrl": url,
            "associationId": settings["association_id"],
        },
        "clientToken": client_token(alarm["arn"], alarm["timestamp"]),
    }


def find_open_task(agent_space_id: str, ref_id: str, window_minutes: int, now: datetime | None = None) -> dict[str, Any] | None:
    """Open investigation for the same alarm created within the window, if any."""
    now = now or datetime.now(timezone.utc)
    kwargs: dict[str, Any] = {
        "agentSpaceId": agent_space_id,
        "filter": {"createdAfter": now - timedelta(minutes=window_minutes), "taskType": ["INVESTIGATION"]},
        "limit": 100,
        "sortField": "CREATED_AT",
        "order": "DESC",
    }
    for _ in range(10):  # at most 1000 recent tasks
        page = client().list_backlog_tasks(**kwargs)
        for task in page.get("tasks", []):
            ref = task.get("reference") or {}
            if ref.get("referenceId") == ref_id and task.get("status") in OPEN_STATUSES:
                return task
        token = page.get("nextToken")
        if not token:
            return None
        kwargs["nextToken"] = token
    return None


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    settings = _settings()
    alarm = parse_alarm_event(event)
    if alarm is None:
        return {"status": "ignored"}
    if settings["prefixes"] and not any(alarm["name"].startswith(p) for p in settings["prefixes"]):
        LOG.info("alarm %s does not match ALARM_NAME_PREFIXES, ignored", alarm["name"])
        return {"status": "ignored", "alarm": alarm["name"]}

    ref_id = reference_id(alarm["arn"])
    try:
        existing = find_open_task(settings["agent_space_id"], ref_id, settings["dedup_minutes"])
    except (ClientError, BotoCoreError) as exc:
        LOG.warning("duplicate check failed, starting investigation anyway: %s", exc)
        existing = None
    if existing:
        LOG.info(json.dumps({"msg": "open investigation exists", "alarm": alarm["name"], "taskId": existing["taskId"]}))
        return {"status": "duplicate", "alarm": alarm["name"], "taskId": existing["taskId"]}

    request = build_task(alarm, settings)
    response = client().create_backlog_task(**request)
    task = response["task"]
    LOG.info(json.dumps({"msg": "investigation started", "alarm": alarm["name"], "taskId": task["taskId"], "status": task["status"]}))
    return {"status": "created", "alarm": alarm["name"], "taskId": task["taskId"]}
