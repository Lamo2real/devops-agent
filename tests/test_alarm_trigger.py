"""alarm_trigger tests. botocore's Stubber validates every request against the
real devops-agent API model, so a wrong parameter name or type fails here."""

from datetime import datetime, timezone

import boto3
import pytest
from botocore.stub import ANY, Stubber

from devops_agent_lambdas import alarm_trigger as at

ALARM_ARN = "arn:aws:cloudwatch:eu-north-1:123456789012:alarm:symptom-orders-5xx"


@pytest.fixture(autouse=True)
def lambda_env(monkeypatch):
    monkeypatch.setenv("AGENT_SPACE_ID", "space-1")
    monkeypatch.setenv("ASSOCIATION_ID", "assoc-1")
    monkeypatch.setenv("INVESTIGATION_PRIORITY", "HIGH")
    monkeypatch.setenv("DEDUP_WINDOW_MINUTES", "60")
    monkeypatch.setenv("ALARM_NAME_PREFIXES", "symptom-,sym2-")


@pytest.fixture
def stub(monkeypatch):
    client = boto3.client("devops-agent", region_name="eu-north-1")
    monkeypatch.setattr(at, "_CLIENT", client)
    with Stubber(client) as s:
        yield s
        s.assert_no_pending_responses()


def event(name="symptom-orders-5xx", state="ALARM", **detail):
    return {
        "version": "0",
        "id": "e-1",
        "detail-type": "CloudWatch Alarm State Change",
        "source": "aws.cloudwatch",
        "account": "123456789012",
        "time": "2026-11-25T10:00:00Z",
        "region": "eu-north-1",
        "resources": [f"arn:aws:cloudwatch:eu-north-1:123456789012:alarm:{name}"],
        "detail": {
            "alarmName": name,
            "state": {"value": state, "reason": "Threshold Crossed: 3 datapoints", "timestamp": "2026-11-25T10:00:00.000+0000"},
            "previousState": {"value": "OK"},
            "configuration": {
                "description": "5xx on the orders ALB",
                "metrics": [{
                    "id": "m1",
                    "metricStat": {
                        "metric": {"namespace": "AWS/ApplicationELB", "name": "HTTPCode_Target_5XX_Count",
                                   "dimensions": {"LoadBalancer": "app/orders/abc"}},
                        "period": 60, "stat": "Sum",
                    },
                    "returnData": True,
                }],
            },
            **detail,
        },
    }


def task(task_id="t-1", status="PENDING_START", ref=None):
    now = datetime(2026, 11, 25, 10, 0, tzinfo=timezone.utc)
    return {
        "agentSpaceId": "space-1", "taskId": task_id, "title": "x", "taskType": "INVESTIGATION",
        "priority": "HIGH", "status": status, "createdAt": now, "updatedAt": now, "version": 1,
        "reference": {"system": "CloudWatch", "referenceId": ref or at.reference_id(ALARM_ARN),
                      "referenceUrl": "https://x", "associationId": "assoc-1"},
    }


def expect_list(stub, tasks, next_token=None, expected_extra=None):
    params = {"agentSpaceId": "space-1", "filter": ANY, "limit": 100, "sortField": "CREATED_AT", "order": "DESC"}
    params.update(expected_extra or {})
    response = {"tasks": tasks}
    if next_token:
        response["nextToken"] = next_token
    stub.add_response("list_backlog_tasks", response, params)


def test_creates_investigation_with_full_context(stub):
    expect_list(stub, [])
    stub.add_response("create_backlog_task", {"task": task()}, {
        "agentSpaceId": "space-1", "taskType": "INVESTIGATION", "priority": "HIGH",
        "title": "CloudWatch alarm symptom-orders-5xx is in ALARM",
        "description": ANY, "reference": ANY, "clientToken": ANY,
    })
    result = at.handler(event())
    assert result == {"status": "created", "alarm": "symptom-orders-5xx", "taskId": "t-1"}


def test_request_contents():
    alarm = at.parse_alarm_event(event())
    req = at.build_task(alarm, at._settings())
    assert req["reference"]["referenceId"] == at.reference_id(ALARM_ARN)
    assert len(req["reference"]["referenceId"]) <= 128
    assert req["reference"]["associationId"] == "assoc-1"
    assert req["reference"]["referenceUrl"].endswith("#alarmsV2:alarm/symptom-orders-5xx")
    assert "AWS/ApplicationELB/HTTPCode_Target_5XX_Count" in req["description"]
    assert "5xx on the orders ALB" in req["description"]
    assert "do not change resources" in req["description"]
    assert len(req["clientToken"]) == 64


def test_retry_of_same_event_reuses_client_token():
    a = at.build_task(at.parse_alarm_event(event()), at._settings())
    b = at.build_task(at.parse_alarm_event(event()), at._settings())
    assert a["clientToken"] == b["clientToken"]
    later = event()
    later["detail"]["state"]["timestamp"] = "2026-11-25T11:00:00.000+0000"
    assert at.build_task(at.parse_alarm_event(later), at._settings())["clientToken"] != a["clientToken"]


def test_open_investigation_for_same_alarm_is_not_duplicated(stub):
    expect_list(stub, [task(ref="cw-alarm-other"), task("t-9", "IN_PROGRESS")])
    assert at.handler(event()) == {"status": "duplicate", "alarm": "symptom-orders-5xx", "taskId": "t-9"}


def test_finished_investigation_does_not_block_new_one(stub):
    expect_list(stub, [task("t-old", "COMPLETED")])
    stub.add_response("create_backlog_task", {"task": task("t-2")}, None)
    assert at.handler(event())["status"] == "created"


def test_dedup_paginates(stub):
    expect_list(stub, [task(ref="cw-alarm-other")], next_token="n1")
    expect_list(stub, [task("t-7", "PENDING_TRIAGE")], expected_extra={"nextToken": "n1"})
    assert at.handler(event())["taskId"] == "t-7"


def test_dedup_failure_fails_open(stub):
    stub.add_client_error("list_backlog_tasks", "AccessDeniedException", http_status_code=403)
    stub.add_response("create_backlog_task", {"task": task("t-3")}, None)
    assert at.handler(event())["status"] == "created"


def test_create_failure_raises_so_lambda_retries(stub):
    expect_list(stub, [])
    stub.add_client_error("create_backlog_task", "ValidationException", http_status_code=400)
    with pytest.raises(Exception):
        at.handler(event())


@pytest.mark.parametrize("evt", [
    event(state="OK"),
    event(state="INSUFFICIENT_DATA"),
    {**event(), "detail-type": "Something else"},
])
def test_irrelevant_events_are_ignored(evt):
    assert at.handler(evt)["status"] == "ignored"


def test_alarm_outside_prefixes_is_ignored():
    assert at.handler(event(name="cpu-high"))["status"] == "ignored"


def test_long_names_are_truncated_to_api_limits():
    long_name = "symptom-" + "x" * 500
    req = at.build_task(at.parse_alarm_event(event(name=long_name)), at._settings())
    assert len(req["title"]) <= 400
    assert len(req["reference"]["title"]) <= 512
    assert len(req["description"]) <= 10000


def test_event_without_resources_builds_arn():
    evt = event()
    evt["resources"] = []
    assert at.parse_alarm_event(evt)["arn"] == ALARM_ARN


def test_find_open_task_uses_window(stub):
    now = datetime(2026, 11, 25, 12, 0, tzinfo=timezone.utc)
    stub.add_response("list_backlog_tasks", {"tasks": []}, {
        "agentSpaceId": "space-1",
        "filter": {"createdAfter": datetime(2026, 11, 25, 11, 30, tzinfo=timezone.utc), "taskType": ["INVESTIGATION"]},
        "limit": 100, "sortField": "CREATED_AT", "order": "DESC",
    })
    assert at.find_open_task("space-1", "r", 30, now=now) is None
