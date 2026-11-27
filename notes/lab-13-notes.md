# Lab 13 Notes: Centralized Logging and Monitoring with CloudWatch and X-Ray

Probe `outputs/lab-13-support-probe.txt`: 6 of 9 SUPPORTED. Unsupported on Floci: all of X-Ray (`UnknownOperationException`), Logs Insights, `DescribeAlarmHistory`, `PutCompositeAlarm`. Real: Logs, metric filters, metrics, alarm evaluation, dashboards, Lambda.

## Steps 1-5
- Twelve env files sourced; `USMS_LAMBDA_NOTIFIER_FN` and `USMS_LOG_GROUP_NOTIFIER` come from Lab 10.
- Inventory before changing anything (`outputs/lab-13-telemetry-inventory.txt`): log groups with retention `None` = never expire, the Lab 06 queue alarm, the `USMS/Enrolment` namespace.

## Step 6: Retention
- Central group `/usms/central/application`, 30 days. ECS group 30, notifier and edge function groups 14. `set_retention` skips a group that does not exist instead of creating it by accident.
- Tagging: `tag-resource` (new API, by ARN) or the older `tag-log-group`, whichever this build has.

## Step 7: Events
- Timestamps are milliseconds. Seconds would put events in January 1970, outside retention, and they would be rejected or vanish.
- The handout's `timestamp=...,message='USMS_EVENT {...}'` fails: the shell removes the single quotes, and the CLI's shorthand parser then splits the value at the commas inside the JSON (`Expected: ',', received: '"'`). Passed the same four events as a JSON file instead.
- Your turn: fifth event `health-check ok: central log group reachable` (no `USMS_EVENT`, no `ERROR`), so the filters have a negative case. A plain message with no commas works fine in shorthand.

## Step 8: Testing patterns
- `USMS_NOTIFY` matches only the real notification line, not the summary or REPORT lines. Patterns are case sensitive.
- Your turn: `ERROR` matches event 4 (the failure) **and** event 5 (`"reason":"no ERROR here"`), because a bare term matches anywhere in the message. The quoted phrase `"ERROR USMS_EVENT"` matches only event 4, because the failure lines start with exactly that phrase. In production I would use the phrase; the handout deploys plain `ERROR`, which I kept so the verify script matches, and the false positive is written down here.

## Step 9: Filters
- `usms-notify-count` on the **notifier** group → `NotifyCount`; `usms-central-errors` on the **central** group → `CentralErrorCount`; both `metricValue=1`, `defaultValue=0`.

## Step 10: Proof
- Upload a probe object, invoke `live` with the S3 event, then read `NotifyCount`. Whether the filter itself produced the point is in the report (`L13_FILTER_PROOF`); if not, the handout's fallback publishes the metric directly and that is recorded as synthetic.
- Your turn: a window 24 h ago returned `Datapoints: []`; the window with the upload returned data. `defaultValue` only fills in a 0 when log events **arrive** and do not match. No log events at all = no data points, which is what an alarm sees as "missing data".

## Step 11: Custom metrics
- Same `TranscriptsProcessed` published with `{Faculty, Stage}` and with no dimensions: two metrics. The undimensioned one is the total; CloudWatch does not sum the dimensioned ones for you.
- `TranscriptLagSeconds` 0.42 and 1.91 → SampleCount 2, Average 1.165, Maximum 1.91.

## Step 12: USMSObservabilityWrite
- Logs: `CreateLogStream`, `PutLogEvents`, `DescribeLogStreams` on `/usms/*:*` and `/aws/lambda/usms-*:*`. Metrics: `PutMetricData` on `*` with `cloudwatch:namespace = USMS/Application`. X-Ray: put segments/telemetry and read sampling rules/targets.
- `configs/lab-01.env` has `USMS_ROLE_EC2` as an ARN; used `basename` to get `usms-ec2-app-role`.

## Steps 13-14: Notifier v2, alias, tracing
- v2 adds a trace id on every log line, `TranscriptsProcessed {Faculty, Stage}` per object and `TranscriptLagSeconds` per invocation, and never fails the invocation because of telemetry.
- `update-function-code` + `update-function-configuration` change `$LATEST`; `publish-version` freezes it; `update-alias live` moves traffic. The S3 notification still targets `live`, so no trigger changed.
- Your turn: `live` → 1 returned `{keys, processed}` (no `trace_id`); `live` → v2 returned `trace_id` and `seconds` again. Same alias ARN, two shapes. Rollback takes one API call and is effective on the next invocation (seconds). Lab 10 Step 11's edge rollback is different: CloudFront must replicate the old version to every edge location, which takes minutes.
- Active tracing is configuration, so a new version (v3) and the alias moved again.

## Steps 15-18: X-Ray
- Trace id `1-<8 hex epoch>-<24 hex>`, segment ids 16 hex. Saved in `outputs/lab-13-trace-ids.txt` because they cannot be derived later.
- Parent segment with four annotations; same segment id sent again with three subsegments (s3-head-object, render-pdf, cloudwatch-put-metric-data); a downstream `usms-student-data` segment with `parent_id`.
- `put-trace-segments`, `get-trace-summaries`, `batch-get-traces`, `get-service-graph`: all `UnknownOperationException` on Floci. Nothing stored, 0 summaries.
- Validation (10 checks, all ok) written to `outputs/lab-13-trace-validation.json`, not over the read-back file. This is the evidence for Steps 15-16.
- Emitter: log, metric and trace for one fictional transcript with the same trace id. Its `put-log-events` uses JSON for the same shorthand reason as Step 7.
- Handout bug in the emitter: it used `NAMESPACE="${USMS_METRIC_NAMESPACE:-USMS/Application}"`, but `configs/lab-06.env` (sourced in Step 2) exports `USMS_METRIC_NAMESPACE=USMS/Enrolment`, and `lab-13.env` does not exist yet at Step 17, so the emitter would publish `TranscriptsProcessed` into the Lab 06 namespace. Fixed by naming `USMS/Application` directly in the emitter.
- Sampling: `usms-transcripts-sampling`, priority 1000, 10% + reservoir 2. Document valid; `create-sampling-rule` unsupported, so not created.

## Steps 19-21: Alarms
- lag-high: `Maximum > 2` for 2 of 3 one-minute periods, `notBreaching`.
- silence: `Sum(NotifyCount) < 1` for 3 of 3 five-minute periods, `breaching`.
- Forced lag-high to ALARM with `set-alarm-state` (with a reason and reason data). 2 s later it was OK again: Floci's evaluator re-evaluated (`missing datapoints treated as not breaching`). History: `DescribeAlarmHistory` unsupported, empty file.
- Composite: `ALARM("usms-transcript-lag-high") OR ALARM("usms-notify-silence")`. `PutCompositeAlarm` unsupported, so it does not exist; the drive-to-ALARM step returned `null`. Verify's two composite checks fail for this reason.
- Later the silence alarm went to ALARM on its own (3 of 3 periods missing = breaching), which is its job. Re-ran the Step 10 commands (probe upload + invoke `live`) → one real `NotifyCount` → OK by itself (`2 datapoint(s) breaching`). Screenshot `step21-recovery.png`.

## Steps 22-23: Dashboard and queries
- Five widgets: text header, processed by faculty, latency max/avg with the threshold line, single values, alarm status. Grid is 24 wide; overlap check passes.
- Insights: `parse` the faculty out of the JSON and `stats count() by faculty`. Unsupported on Floci; the fallback with `filter-log-events` and Python gave `science 4`, `engineering 3`.

## Steps 24-26
- Restart: configuration diff and metric data points before/after recorded in the report.
- `configs/lab-13.env`: 28 exports.
- Verify script: `ROLE_EC2` stripped to a name (ARN in lab-01.env). Cleanup script not run.

---

## Review questions

### 1. "We have logs, so we do not need metrics"
First, cost and speed of the question "how many": answering it from logs means scanning and parsing every line in the time range each time you ask (Logs Insights charges per GB scanned), while a metric is a pre-aggregated number per minute that is free to read and instant to graph. Second, alarms: CloudWatch alarms evaluate metrics, not log lines; to alarm on something in logs you have to turn it into a metric anyway (a metric filter), and alarms on metrics can treat missing data as a signal, which a log search cannot. They are right when the question is about one specific event rather than a count: "what happened to transcript stu-00417 at 10:32" is a log question, and a low-traffic system where someone reads the logs every day may genuinely not need metrics yet.

### 2. Metric filter versus direct publishing
Retroactivity: neither is retroactive; a filter only sees lines that arrive after it is created, and direct publishing only exists from the moment the code is deployed (logs from before can still be searched, metrics cannot be created for the past). Cost: a filter costs nothing extra beyond the logs you already pay for (plus the custom metric); direct publishing adds `PutMetricData` calls. Adding a measurement: a filter is a configuration change on the log group, no deploy; direct publishing needs a code change and a new version. Code that is not yours: only a filter works, because you cannot add `PutMetricData` to someone else's code but you can read its logs. For "how many transcript downloads", a filter on the existing log line is enough and needs no code change. For "how long the render took", the value has to be measured inside the code around the render call, so I would publish it directly (or log it and extract it with a filter, as in Exercise 1, if I want to keep one source of truth). The answers differ because one is a count of events that are already logged and the other is a measurement that only the code can take.

### 3. notBreaching on lag-high, breaching on silence
If lag-high treated missing data as breaching, every quiet period (night, holidays, no uploads) would page someone for "high latency" when nothing happened at all: latency with no requests is not high, it is undefined. If silence treated missing data as notBreaching, it would never fire in the one situation it exists for: when notifications stop, `NotifyCount` stops arriving, the alarm sees missing data, treats it as OK and stays green. Incident only the second catches: the S3 notification configuration is deleted by a bad `put-bucket-notification-configuration` (replace-only), so uploads continue but the notifier never runs. No invocations means no latency data, so lag-high stays OK, while silence goes to ALARM after 15 minutes. On the dashboard the latency graph and the processed-by-faculty graph would just be empty, with nothing red, which looks like a quiet day.

### 4. Dimension versus annotation
A metric dimension is part of the metric's identity; each distinct combination of values is a separate metric that is stored, billed and aggregated on its own. It is for questions like "graph and alarm on this, per value". As distinct values grow, the number of metrics and the cost grow with them, and graphs become unusable. An X-Ray annotation is an indexed key/value on one trace; it lets you search ("show me traces where faculty = science") but you do not graph or alarm on it, and many distinct values are fine. Placement: the transcript's **faculty** is a dimension (a handful of values, and I want counts and alarms per faculty); the **student id** is an annotation (and a log field), never a dimension, because it would create one metric per student; the **origin's HTTP status** is a dimension if I want an error-rate alarm (few values: 200, 403, 404, 500...), and also useful as an annotation to find the failing traces; the **renderer name** is an annotation, because it explains one slow trace and there is no need to graph it per renderer unless I am comparing renderers, in which case it is a low-cardinality dimension.

### 5. Why tracing needed its own version
A version freezes code **and** configuration, and `TracingConfig` is configuration. Version 2 was published before tracing was turned on, so version 2 will never trace, whatever `$LATEST` says. If I had changed `TracingConfig` and left `live` on version 2, only `$LATEST` would trace, and every real invocation through the alias (the S3 trigger) would run untraced, with nothing telling me so. Publishing version 3 and moving the alias is the only way to get the new configuration into the path the trigger uses. Lab 10 Step 11 made the same claim for the edge: CloudFront associates a version precisely because a version is a fixed bundle of code and configuration.

### 6. What forcing an alarm proves
It proves the alarm exists, its state can change, the transition is recorded in history, and anything wired to that state (the composite alarm, a dashboard widget, later SNS actions) reacts. It does not prove that the metric, threshold, period and missing-data policy would ever put it in ALARM by themselves, that the metric name and dimensions match what the code publishes, or that real data reaches it. On real AWS the equivalent test is to generate a real breach (publish latency values above 2 s for two minutes, or stop notifications for 15 minutes) and watch the alarm evaluate on its own and send its notification. Testing what happens after an alarm fires matters even with a good threshold, because the usual failure is not the threshold but the path: the action is missing, the SNS topic has no subscription, the composite has actions disabled, or the page goes to someone who left. It is the same course-wide rule: `set-alarm-state` succeeding only shows the API accepted the call, not that the monitoring does what I meant. In this lab the silence alarm did get that real test without my planning it: the notifier went quiet, the alarm went to ALARM by itself, and one real notification brought it back to OK.
