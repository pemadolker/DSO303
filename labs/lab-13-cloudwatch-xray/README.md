# Lab 13 – Centralized Logging and Monitoring with CloudWatch and X-Ray

**Module:** DSO303 · **Environment:** Floci (local AWS emulator)

## Overview
This lab adds observability to the existing USMS system in three layers, with a dashboard on top.

| Layer | Tool | Answers |
|---|---|---|
| **Logs** | CloudWatch Logs | *What happened?* (text events) |
| **Metrics** | CloudWatch Metrics + Alarms | *How much / how often?* (numbers over time) |
| **Traces** | AWS X-Ray | *Where did the time go for this one request?* |

> A metric says "eleven transcripts were slow". A trace says "*this* transcript was slow, and 74 ms of its 120 ms were in `render-pdf`".

## What I built
| Resource | Purpose |
|---|---|
| `/usms/central/application` | Central log group (30-day retention) |
| Retention policies | Set on every USMS log group, which previously never expired |
| `usms-notify-count`, `usms-central-errors` | Metric filters that turn log lines into metrics |
| `USMS/Application` namespace | Custom metrics, including `TranscriptsProcessed` and `TranscriptLagSeconds`, with `Faculty`/`Stage` dimensions |
| `USMSObservabilityWrite` | IAM policy for logs, metrics (scoped to one namespace) and traces |
| `usms-transcript-notifier` v2 | Instrumented version; alias `live` repointed from 1 → 2 |
| Active tracing + `usms-transcripts-sampling` | X-Ray tracing on the notifier, plus a sampling rule |
| `usms-transcript-lag-high` | Metric alarm on transcript lag |
| `usms-notify-silence` | Alarm that fires when data is *missing* (`treat-missing-data = breaching`) |
| `usms-transcript-pipeline-down` | Composite alarm: lag-high OR silence |
| `usms-overview` | Dashboard with 5 widgets |
| `scripts/utilities/usms-emit-telemetry.sh` | Sends one log line, one metric and one trace together |

## Main steps
1. Probed what this Floci build supports, then listed the existing logs and alarms. Every log group was set to *never expire*.
2. Created the central log group and set retention everywhere (30 days for app logs, 14 for Lambda debug logs).
3. Wrote structured `USMS_EVENT {...}` log lines, tested filter patterns with `test-metric-filter`, deployed two metric filters, and proved log → metric end to end.
4. Published custom metrics with dimensions, and created a separate IAM policy for telemetry (instead of editing the existing one).
5. Deployed notifier v2 by repointing the `live` alias, turned on tracing, built X-Ray segments, subsegments and annotations, and added a sampling rule.
6. Created the metric, absence and composite alarms, forced one into `ALARM` to prove it, then built the dashboard and queried the logs.
7. Restarted Floci, checked everything survived, wrote `configs/lab-13.env`, and committed.

## Key concepts
- **Retention.** CloudWatch Logs keep data forever by default, which is the most common avoidable CloudWatch cost.
- **Metric filters.** Turn matching log lines into metric data points as logs arrive. They only work going forward, not on old logs, and a pattern that matches nothing produces a metric that is always zero with no error. That's why patterns get tested before deploying.
- **Dimensions are part of the metric's identity.** `{Faculty=science}` and `{}` are two different metrics, and CloudWatch doesn't add them up for you. High-cardinality values like student IDs belong in logs or X-Ray annotations, not dimensions.
- **Alarm states and missing data.** `INSUFFICIENT_DATA` is a normal state, not an error. Treating missing data as *breaching* lets an alarm catch a pipeline that has gone silent.
- **Composite alarms.** Combine related alarms so one incident triggers one page instead of several.
- **X-Ray.** A segment is one service's work, and subsegments are the steps inside it. Annotations are indexed and searchable; metadata isn't. Sampling controls how many requests get traced.
- **IAM scoping.** `PutMetricData` only accepts `Resource: "*"`, so it's limited with a `cloudwatch:namespace` condition instead. Log ARNs need a trailing `:*` to cover log streams.

## Notes / limitations
Floci publishes few AWS built-in metrics, often stores metric filters and alarms without evaluating them, and doesn't enforce IAM. Where a filter didn't produce data points, I published the metric by hand and recorded it as synthetic in `outputs/lab-13-support-probe.txt`, keeping what I actually observed separate from what was only configured.