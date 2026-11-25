---
name: platform-context
description: Facts about this customer's platform (accounts, services, owners, deployment flow). Use it to understand where a failing component runs and who owns it.
---

# Platform context

Fill this in per customer. Keep it short and factual.

| Item | Value |
| --- | --- |
| Monitoring account | 123456789012 |
| Workload accounts | prod-app, prod-data |
| Region | eu-north-1 |
| Compute | EKS / ECS / Lambda |
| GitOps | Argo CD |
| Repositories | org/app, org/infra |
| On-call | team-x (Slack #oncall) |

## Services

- **orders-service**: public API behind an ALB, depends on RDS PostgreSQL.

## Known behaviour

- Nightly batch jobs between 01:00 and 03:00 raise latency; not an incident.
