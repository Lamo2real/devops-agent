---
name: incident-investigation
description: Step-by-step investigation playbook for symptom alarms (HTTP 5xx, unhealthy targets, application errors, pods not ready). Use it for every alarm-triggered investigation.
---

# Incident investigation playbook

1. **Scope the symptom.** Read the alarm, its metric and the time it started.
   Check whether other alarms in the same account fired within 15 minutes.
2. **Recent changes first.** List deployments, commits, merged pull requests,
   GitOps syncs, CloudTrail write events and configuration changes in the
   two hours before the alarm. Most incidents follow a change.
3. **Follow the request path.** Load balancer (5xx, target health, health
   check path) -> service (ECS tasks / Kubernetes pods, restarts, events) ->
   dependencies (RDS connections and latency, downstream APIs).
4. **Logs.** Use CloudWatch Logs Insights on the affected service around the
   start time. Group errors by message and count them.
5. **Delayed data.** CloudTrail and database logs can arrive minutes late.
   Re-check before concluding that nothing changed.
6. **Conclude.** State the root cause with the evidence that proves it, the
   mitigation, and the permanent fix as a GitHub issue.
