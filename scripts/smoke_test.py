#!/usr/bin/env python3
"""End-to-end smoke test of a deployed stack.

1. Checks the Agent Space, the monitoring account association and (if any) the
   GitHub repository associations.
2. Forces the smoke test alarm into ALARM, which must make EventBridge invoke
   the alarm-trigger Lambda, which must create an investigation.
3. Waits for the investigation, then fires the alarm again to prove the
   duplicate check, and finally resets the alarm to OK.

Usage: python scripts/smoke_test.py [--timeout 180] [--keep-alarm]
Needs boto3 and AWS credentials for the account in project.env.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))

import config as project_config  # noqa: E402
from devops_agent_lambdas import alarm_trigger  # noqa: E402
from devops_agent_lambdas.alarm_trigger import reference_id  # noqa: E402


def tf_outputs() -> dict:
    out = subprocess.run(
        ["terraform", f"-chdir={ROOT / 'terraform' / 'main'}", "output", "-json"],
        capture_output=True, text=True, check=True,
    )
    return {k: v["value"] for k, v in json.loads(out.stdout).items()}


def check(label: str, ok: bool, detail: str = "") -> bool:
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}{(': ' + detail) if detail else ''}")
    return ok


def wait_for_task(agent, space_id: str, ref_id: str, since: float, timeout: int):
    deadline = time.time() + timeout
    while time.time() < deadline:
        page = agent.list_backlog_tasks(
            agentSpaceId=space_id, limit=50, sortField="CREATED_AT", order="DESC",
            filter={"taskType": ["INVESTIGATION"]},
        )
        for task in page.get("tasks", []):
            if (task.get("reference") or {}).get("referenceId") == ref_id and task["createdAt"].timestamp() >= since - 5:
                return task
        time.sleep(10)
    return None


def lambda_results(logs, function: str, since: float) -> list[str]:
    paginator = logs.get_paginator("filter_log_events")
    pages = paginator.paginate(logGroupName=f"/aws/lambda/{function}", startTime=int(since * 1000), filterPattern='"msg"')
    return [e["message"] for page in pages for e in page.get("events", [])]


def wait_for_log(logs, function: str, since: float, needles: tuple[str, ...], timeout: int) -> str:
    """Poll the Lambda log until one of the needles appears; return the matching text."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = " ".join(lambda_results(logs, function, since))
        if any(n in text for n in needles):
            return text
        time.sleep(10)
    return " ".join(lambda_results(logs, function, since))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--keep-alarm", action="store_true")
    args = parser.parse_args()

    env_file = Path(os.environ.get("PROJECT_ENV_FILE", str(project_config.DEFAULT_ENV_FILE)))
    try:
        cfg = project_config.load_file(env_file)
    except project_config.ConfigError as exc:
        print("\n".join(exc.errors), file=sys.stderr)
        return 2
    region = cfg["AWS_REGION"]
    session = boto3.session.Session(region_name=region)
    agent = session.client("devops-agent")
    cloudwatch = session.client("cloudwatch")
    logs = session.client("logs")
    out = tf_outputs()
    space_id = out["agent_space_id"]
    ok = True

    print("Agent Space")
    space = agent.get_agent_space(agentSpaceId=space_id)["agentSpace"]
    ok &= check("agent space exists", space.get("agentSpaceId") == space_id, space.get("name", ""))
    associations = [
        a for page in agent.get_paginator("list_associations").paginate(agentSpaceId=space_id)
        for a in page.get("associations", [])
    ]
    by_service: dict[str, list] = {}
    for assoc in associations:
        by_service.setdefault(assoc["serviceId"], []).append(assoc)
    monitor = [a for a in by_service.get("aws", []) if "aws" in a.get("configuration", {})]
    ok &= check("monitoring account associated", bool(monitor), monitor[0].get("status", "") if monitor else "missing")
    for name, assoc_id in (out.get("github_repositories") or {}).items():
        match = next((a for a in associations if a["associationId"] == assoc_id), None)
        status = (match or {}).get("status", "missing")
        ok &= check(f"GitHub repository {name}", match is not None and status != "invalid", status)

    alarm = out.get("smoke_test_alarm_name")
    if not alarm:
        print("Smoke test alarm disabled (CREATE_SMOKE_TEST_ALARM=false); skipping the alarm path.")
        return 0 if ok else 1

    alarm_arn = cloudwatch.describe_alarms(AlarmNames=[alarm])["MetricAlarms"][0]["AlarmArn"]
    ref_id = reference_id(alarm_arn)
    function = out["alarm_trigger_function"]

    # A previous smoke investigation may still be open: then a new one is
    # (correctly) suppressed, so only the duplicate path can be tested.
    alarm_trigger._CLIENT = agent
    task = alarm_trigger.find_open_task(space_id, ref_id, cfg["DEDUP_WINDOW_MINUTES"])

    if task is None:
        print("Alarm -> investigation")
        cloudwatch.set_alarm_state(AlarmName=alarm, StateValue="OK", StateReason="smoke test reset")
        time.sleep(2)
        start = time.time()
        cloudwatch.set_alarm_state(AlarmName=alarm, StateValue="ALARM", StateReason="smoke test: forced ALARM")
        task = wait_for_task(agent, space_id, ref_id, start, args.timeout)
        ok &= check("investigation created from alarm", task is not None, f"{task['taskId']} {task['status']}" if task else "timeout")
        if task is None:
            for line in lambda_results(logs, function, start)[-5:]:
                print("    lambda:", line.strip())
    else:
        print(f"Previous smoke investigation {task['taskId']} is still open ({task['status']}); testing duplicate protection only.")

    if task is not None:
        print("Duplicate protection")
        cloudwatch.set_alarm_state(AlarmName=alarm, StateValue="OK", StateReason="smoke test: flap")
        time.sleep(2)
        flap = time.time()
        cloudwatch.set_alarm_state(AlarmName=alarm, StateValue="ALARM", StateReason="smoke test: flap again")
        results = wait_for_log(logs, function, flap, ("open investigation exists", "investigation started"), args.timeout)
        skipped = "open investigation exists" in results
        ok &= check("flapping alarm did not start a second investigation", skipped,
                    "duplicate skipped" if skipped else results[-200:] or "no Lambda log")

    if not args.keep_alarm:
        cloudwatch.set_alarm_state(AlarmName=alarm, StateValue="OK", StateReason="smoke test finished")
    print("\nRESULT:", "PASS" if ok else "FAIL")
    if task is not None:
        print(f"Open the investigation in the operator web app (task {task['taskId']}).")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
