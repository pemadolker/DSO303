# AWS Practical Laboratory 13 Report

**Student Name:** Pema Dolker 
**Module:** DSO303  
**Practical:** Lab 13 - Centralized Logging and Monitoring with CloudWatch and X-Ray  
**Environment:** Floci (local AWS API emulator, Docker Compose, hybrid storage), account 000000000000, us-east-1

**Support:** 6 of 9 probes SUPPORTED (`outputs/lab-13-support-probe.txt`); X-Ray read-back supported: no. Three handout commands were changed and are explained in section 7: JSON log events are passed as a JSON document, the EC2 role name is taken from the ARN stored in `configs/lab-01.env`, and the emitter names its metric namespace directly.

Step notes and the six review questions: `notes/lab-13-notes.md`. Exercises: `labs/lab-13-cloudwatch-xray/exercises.md`. Exercise 4 plan: `notes/lab-13-observability-plan.md`.

> **Observed** = I ran it and saw it. **Floci limitation** = behaved differently from real AWS. **Conceptual** = only possible on real AWS, so I explained it instead.

## 1. Aim / Objective

The aim of this practical is to make USMS observable in three layers: **logs** (what happened), **metrics** (how much, how often) and **traces** (where the time went for one request), with alarms and a dashboard on top. I inventoried the monitoring that already existed, set retention on every log group, turned log lines into metrics with metric filters, published custom metrics with dimensions, instrumented the transcript notifier and enabled tracing through new versions and the `live` alias, built X-Ray segments by hand, and created a threshold alarm, an absence alarm, a composite alarm and a dashboard.

## 2. Introduction

A metric says "eleven transcripts were slow". A trace says "this transcript was slow, and 74 ms of its 120 ms were in render-pdf". A log line says what exactly happened. Each answers a different question and costs differently, which is why all three exist.

The main ideas I used:

- **Retention** - CloudWatch Logs keep data forever by default, the most common avoidable cost.
- **Metric filters** - turn matching log lines into metric points as they arrive; never retroactive, and a pattern that matches nothing gives a metric of zeros with no error, so patterns are tested first with `test-metric-filter`.
- **Dimensions** - part of a metric's identity: `{Faculty=science}` and no dimensions are two different metrics. High-cardinality values (student ids) belong in logs and trace annotations, not dimensions.
- **Alarm states and missing data** - `INSUFFICIENT_DATA` is normal; treating missing data as breaching lets an alarm catch silence.
- **Composite alarms** - one incident, one page.
- **X-Ray** - a segment is one service's work, subsegments are steps inside it, annotations are indexed and searchable, metadata is not, sampling decides what is traced.
- **IAM for telemetry** - `PutMetricData` only accepts `Resource: "*"`, so it is scoped with the `cloudwatch:namespace` condition.

## 3. Use Case

- Knowing within minutes that transcript notifications have stopped, even though "stopped" produces no data at all.
- Counting failures per faculty from log lines without changing the code that writes them.
- Finding which step of one slow transcript took the time.
- Keeping log costs bounded with retention per group.
- One page per incident instead of several alarms for the same failure.

## 4. System Architecture / Design

```text
 SOURCES                        LOGS                                  METRICS (USMS/Application)
 notifier:live (v2 metrics,  -> /aws/lambda/usms-transcript-notifier  NotifyCount (filter usms-notify-count)
   v3 active tracing)            14 days                              CentralErrorCount (filter usms-central-errors)
 usms-emit-telemetry.sh      -> /usms/central/application 30 days     TranscriptsProcessed {Faculty,Stage} + total
 put-metric-data / segments                                            TranscriptLagSeconds {Stage}, EdgeDenyCount
                                                                            |
 X-RAY: segments + subsegments, annotations faculty/stage          ALARMS: usms-transcript-lag-high (Max > 2 s, notBreaching)
        sampling rule usms-transcripts-sampling (10% + 2/s)                usms-notify-silence (Sum < 1 for 15 min, breaching)
                                                                           usms-transcript-pipeline-down = lag OR silence
 IAM: USMSObservabilityWrite on usms-lambda-exec-role and usms-ec2-app-role      DASHBOARD: usms-overview
```

![Lab 13 architecture](../../screenshots/lab13/lab-13-architecture.png)

## 5. Implementation Procedure

1. **Steps 1 to 5** - started Floci, sourced twelve env files, probed support, and inventoried existing log groups, alarms, namespaces and dashboards.
2. **Step 6** - created `/usms/central/application` and set retention on every USMS log group (30 days application, 14 days function).
3. **Steps 7 to 10** - wrote structured `USMS_EVENT` log lines with millisecond timestamps, tested filter patterns, deployed two metric filters and proved log → metric end to end.
4. **Steps 11 and 12** - published custom metrics with and without dimensions, and created `USMSObservabilityWrite` for both roles.
5. **Steps 13 and 14** - deployed the instrumented notifier as a new version and moved `live`, rolled back and forward, then enabled active tracing as its own version.
6. **Steps 15 to 18** - built X-Ray segments, subsegments and a downstream segment, read them back or validated them, searched by annotation, wrote the telemetry emitter and created a sampling rule.
7. **Steps 19 to 23** - created the two alarms and the composite, forced one into ALARM and back, built the dashboard and queried the logs.
8. **Steps 24 to 26, Section 8, Exercises** - restarted and compared, wrote `configs/lab-13.env`, built the verify and cleanup scripts, did Exercises 1 to 5 and committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Steps 1 to 5 - environment, probe, inventory**

![Step 1](../../screenshots/lab13/step1.png)
![Step 2](../../screenshots/lab13/step2.png)
![Step 3](../../screenshots/lab13/step3.png)
![Step 4](../../screenshots/lab13/step4.png)
![Step 5](../../screenshots/lab13/step5.png)

**Observed:** 6 of 9 probes SUPPORTED. The inventory showed the monitoring that already existed from earlier labs (the ECS log group, Lambda log groups from Lab 10, the Lab 06 alarm and namespace), and the log groups had no retention, which means never expire.

**Step 6 - retention**

![Step 6](../../screenshots/lab13/step6.png)
![Step 6 all groups](../../screenshots/lab13/step6-2.png)

**Observed:** central group created with 30 days; every USMS group now has a retention value instead of never-expire.

**Steps 7 to 10 - log lines to metrics**

![Step 7](../../screenshots/lab13/step7.png)
![Step 7 fifth event (your turn)](../../screenshots/lab13/step7-2.png)
![Step 8](../../screenshots/lab13/step8.png)
![Step 8 ERROR pattern (your turn)](../../screenshots/lab13/step8-2.png)
![Step 9](../../screenshots/lab13/step9.png)
![Step 10](../../screenshots/lab13/step10.png)
![Step 10 defaultValue (your turn)](../../screenshots/lab13/step10-2.png)

**Observed:** four events accepted and read back in order; a fifth health-check line that no filter matches. `test-metric-filter` with `USMS_NOTIFY` matched only message 1. For the ERROR filter, the plain pattern `ERROR` also matched my false-positive line `... "reason":"no ERROR here"`, while the quoted phrase `"ERROR USMS_EVENT"` matched only the real failure (details in the exercises file). End-to-end proof: observed: the metric filter turned the notifier's USMS_NOTIFY log line into 1 NotifyCount data point(s). For `defaultValue`: a window with no log events at all returned an **empty** `Datapoints` list, because `defaultValue=0` is only emitted when log events arrive that do not match; it does not invent data when nothing is written.

**Steps 11 and 12 - custom metrics and permissions**

![Step 11](../../screenshots/lab13/step11.png)
![Step 11 dimensions](../../screenshots/lab13/step11-2.png)
![Step 12](../../screenshots/lab13/step12.png)

**Observed:** `list-metrics` shows `TranscriptsProcessed` more than once, with `Faculty,Stage` and with no dimensions: same name, different metrics, and CloudWatch does not add them up. `USMSObservabilityWrite` is attached to both roles; `PutMetricData` is scoped with `cloudwatch:namespace = USMS/Application`, and the log ARNs end in `:*` so they cover the streams.

**Steps 13 and 14 - instrumented notifier, alias, tracing**

![Step 13](../../screenshots/lab13/step13.png)
![Step 13 invoke](../../screenshots/lab13/step13-2.png)
![Step 13 rollback (your turn)](../../screenshots/lab13/step13-3.png)
![Step 14](../../screenshots/lab13/step14.png)

**Observed:** instrumented code published as version 3 and `live` moved to it; the invoke printed a `USMS_SUMMARY` line and returned `trace_id` and `seconds`. Rolling `live` back to version 1 returned the old payload shape without `trace_id`; rolling forward brought it back; no version was deleted. Turning on active tracing is a configuration change, so it was published as its own version, 4, and `live` moved again.

**Steps 15 to 18 - X-Ray**

![Step 15](../../screenshots/lab13/step15.png)
![Step 16](../../screenshots/lab13/step16.png)
![Step 16 read back](../../screenshots/lab13/step16-2.png)
![Step 16 validation](../../screenshots/lab13/step16-3.png)
![Step 17](../../screenshots/lab13/step17.png)
![Step 17 emitter](../../screenshots/lab13/step17-2.png)
![Step 18](../../screenshots/lab13/step18.png)

**Observed:** `put-trace-segments` returned `[]` (every segment accepted). Read-back: 0 trace summaries read back. The structural validation passed its ten checks (one trace id, 16-hex ids, subsegments inside the parent's time window, the downstream segment naming its parent, annotations only strings, numbers or booleans); I wrote it to `outputs/lab-13-trace-validation.json` so it does not overwrite the read-back file. The emitter sends one log line, one metric and one trace for the same fictional transcript, joined by trace id. The sampling rule is 10% plus a reservoir of 2 per second for the notifier.

**Steps 19 to 23 - alarms, composite, dashboard, queries**

![Step 19](../../screenshots/lab13/step19.png)
![Step 20](../../screenshots/lab13/step20.png)
![Step 20 history](../../screenshots/lab13/step20-2.png)
![Step 21](../../screenshots/lab13/step21.png)
![Step 22](../../screenshots/lab13/step22.png)
![Step 23](../../screenshots/lab13/step23.png)
![Step 23 fallback](../../screenshots/lab13/step23-2.png)

**Observed:** lag-high uses `Maximum` with missing data as `notBreaching`; silence uses `Sum < 1` over three 5-minute periods with missing data as `breaching`. `set-alarm-state` drove lag-high to ALARM with a reason, the history recorded the transitions, and it was set back to OK. The composite's rule is `ALARM("usms-transcript-lag-high") OR ALARM("usms-notify-silence")`. The dashboard has five widgets on the 24-column grid with no overlap. The Logs Insights query counted events by faculty, and the `filter-log-events` plus local parse gives the same answer where Insights is not available.

**Steps 24 and 25 - restart and env file**

![Step 24](../../screenshots/lab13/step24.png)
![Step 24 after](../../screenshots/lab13/step24-2.png)
![Step 25](../../screenshots/lab13/step25.png)

**Observed:** configuration before and after the restart: IDENTICAL; metric data points before=0 after=0. `configs/lab-13.env` has 28 exports.

**Section 8 and Step 26**

![Verification](../../screenshots/lab13/section8-verify.png)
![Cleanup script](../../screenshots/lab13/section8-cleanup.png)
![Verification after exercises](../../screenshots/lab13/step26-verify.png)
![Commit](../../screenshots/lab13/step26.png)

**Observed:** `verify-lab-13.sh` first run: PASS=47  FAIL=2; after the exercises (widget check updated to 6 in Exercise 2): PASS=47  FAIL=2. If the "no alarm stuck in ALARM" check fails, that is the silence alarm doing its job: with missing data treated as breaching and no notifications for 15 minutes, it is supposed to go to ALARM. The cleanup script is written but not run.

### 6.2 AWS Management Console Verification

Floci has no console. The `describe-*`, `get-metric-statistics`, `get-trace-summaries` and `get-dashboard` output above is the verification.

## 7. Analysis and Discussion

The objectives were achieved: every USMS log group has retention, two filters turn log lines into metrics, custom metrics carry small-cardinality dimensions, the notifier publishes its own telemetry and is traced, and three alarms plus a dashboard sit on top.

The idea that stuck was the absence alarm. A threshold alarm on a value cannot fire when the value stops arriving: with `notBreaching` it simply sees nothing and stays OK, which is exactly how a dashboard shows "all green" during an outage. Treating missing data as `breaching` on a count of notifications turns silence into a signal.

The second was cardinality. The notifier's `faculty_of()` function is deliberately crude because a dimension value derived from a path is how you end up with one metric per student. Student ids go in logs and trace annotations instead.

Changes to the handout, and why:

- **Log events with JSON payloads.** Step 7 and the emitter pass events as `timestamp=...,message=USMS_EVENT {"event":...,"student":...}`. The AWS CLI's shorthand parser splits on the commas inside the JSON and fails with `Expected: ',', received: '"'` (the exact command was checked on its own before the run). The same events now go in as a JSON document (`--log-events file://...` in Step 7, a JSON string built with Python in the emitter). The content is identical.
- **The EC2 role name.** `configs/lab-01.env` stores `USMS_ROLE_EC2` as a full ARN (the same issue I found in Lab 09), so `attach-role-policy --role-name` would fail. Step 12 and the verify script use the part after the last `/`.
- **The emitter's namespace.** It read `$USMS_METRIC_NAMESPACE`, which `configs/lab-06.env` exports as `USMS/Enrolment`, so at Step 17 its metrics would have gone into the Lab 06 namespace. It now names `USMS/Application` directly.
- **Trace files.** The structural validation goes to its own file so it does not overwrite what was read back from X-Ray.

Observed versus recorded: **observed** - log groups and retention, ordered events, filter tests, metric filters, custom metrics and dimensions, versions and the alias moving, segments accepted, alarm state transitions and history, the composite rule, the dashboard body, the queries and persistence. **Depends on the build** (recorded in the tokens above) - whether filters produced data points, whether X-Ray returned summaries, whether alarms evaluate by themselves. **Not claimed** - real alarm evaluation latency, notification delivery (no actions are attached yet), service maps from real traffic, and cost.

## 8. Reflection

**What I learned.** I had used logs and dashboards before, but I had not thought about which question each signal answers or what each costs. Seeing that `defaultValue` does not create data when nothing is logged, and that a dimension creates a separate metric, changed how I would design monitoring.

**Challenges.** The handout's log-event commands fail on the CLI's shorthand syntax. It looks like an emulator problem, but running the exact command on its own shows it is the CLI parsing the commas inside the JSON.

**Real world use.** For our Semzung project I would start with one absence alarm on the thing users depend on, retention on every group, and structured log lines that can become metrics later.

**What I want to explore more.** The CloudWatch embedded metric format (metrics written as log lines, no `PutMetricData` calls), and X-Ray from a real SDK instead of hand-built segments.

## 9. Conclusion

The objectives were achieved. USMS now has a central log group, retention everywhere, two metric filters, custom metrics with dimensions, an instrumented and traced notifier behind its alias, hand-built traces with annotations, a sampling rule, a threshold alarm, an absence alarm, a composite alarm, a dashboard and an emitter that produces all three signals together.

Key ideas: logs, metrics and traces answer different questions; retention and cardinality decide the bill; filters only work forward and must be tested first; and the most important alarm is often the one that watches for silence.

## 10. Appendix

- Notes and review questions: `notes/lab-13-notes.md`; exercises: `labs/lab-13-cloudwatch-xray/exercises.md`; plan: `notes/lab-13-observability-plan.md`
- Source: `labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py`
- Policy: `policies/usms-observability-write-policy.json`
- Templates: `templates/lab-13-metric-data.json`, `lab-13-segment-*.json`, `lab-13-sampling-rule.json`, `lab-13-dashboard.json`
- Scripts: `scripts/utilities/usms-emit-telemetry.sh`, `usms-dashboard-gen.sh` (Ex 2), `usms-threshold-report.sh` (Ex 3), `verify-lab-13.sh`, `scripts/cleanup/lab-13-cleanup.sh` (not run)
- Recorded values: `configs/lab-13.env`; screenshots: `screenshots/lab13/`
- Git-ignored: support probe, inventory, filter tests, metric read-backs, trace ids and summaries, alarm history, restart files, threshold report, alarm actions draft, latency baseline, readiness file
