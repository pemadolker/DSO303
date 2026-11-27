# Lab 13 Exercise 4 - USMS observability plan

The registrar's four complaints:

1. Nobody noticed for six hours that transcripts had stopped; the dashboard was green because the graphs were empty.
2. When they noticed, they could not tell whether it was the upload, the function or the bucket.
3. The audit office asked who downloaded a particular transcript in March, and the logs were gone.
4. The monitoring bill is larger than the bill for the thing being monitored.

## 1. The right layer for each complaint

| Complaint | Layer | Why not the others |
|---|---|---|
| Six hours unnoticed | **Metrics** (a count, with an absence alarm) | Logs only help if someone searches them, and there is nothing to search when nothing happens. Traces are sampled and per-request; a trace cannot show the absence of requests. |
| Upload, function or bucket? | **Traces** | One trace of one transcript shows each hop (S3 event → notifier → `head_object` → metric publish) with timings and errors. Metrics say *that* it failed, not *where*; logs from three services would have to be joined by hand. This complaint has only one right answer, and Steps 15-17 built it. |
| Who downloaded transcript X in March | **Logs** (access logs, kept long) | It is a question about one event by one person months ago. Metrics aggregate it away; traces are sampled and kept 30 days. |
| Bill | **All three**, mostly logs and metric cardinality | See section 5. |

## 2. Log group taxonomy and retention

| Log group | Contents | Retention | Who reads it |
|---|---|---|---|
| `/usms/central/application` | Structured `USMS_EVENT` lines from all services | 30 days | Platform team |
| `/aws/lambda/usms-*` | Function stdout, `REPORT` lines | 14 days | Platform team |
| `/usms/ecs/enrolment` | Container logs | 30 days | Platform team |
| `/usms/audit/transcript-access` | One line per transcript download: who, which transcript, when, from where (CloudFront access logs and S3 data events, delivered here or to an S3 archive) | 400 days in CloudWatch, then archive in S3 Glacier for the registrar's records period | **Only** the audit role and the registrar's office; platform engineers cannot read it (a resource policy and a separate KMS key) |

The longest retention is the audit group, because it is the only one whose question is asked about a date in the past by someone outside the team; 400 days covers "last March" from any day this year (verify the university's actual records-retention requirement before fixing the number). The shortest is the function logs at 14 days, because they are debugging output that is only read while an incident is fresh and repeats what the central group records in structured form. Both numbers are judgments I would confirm with the registrar and with a week of real usage.

## 3. Service level indicators

| SLI | Target | Alarm or graph |
|---|---|---|
| **Delivery ratio**: transcripts with a successful notification / transcripts uploaded, per hour | 99.5% per day | **Alarm** - it is what students notice ("my transcript never arrived"). |
| **Notification latency**: p95 seconds from upload to notification | under 5 s | **Graph only**, alarm at a higher level (e.g. p95 > 30 s for 15 minutes). Slow is annoying; missing is the incident. |
| **Download success**: 2xx / all transcript requests at CloudFront, excluding 403 for unauthenticated requests | 99.9% | **Alarm** on sustained 5xx. 403s are graphed separately: they are the edge doing its job. |

The targets are starting points ("it seemed reasonable", stated honestly), to be replaced after measuring a month of real traffic. An SLI that is only graphed is not wasted: it is what shows a slow drift before it becomes an outage, and it is the evidence when choosing future targets.

## 4. Alarms and missing data

| Alarm | Metric | Missing data | Action |
|---|---|---|---|
| `usms-notify-silence` | Sum of `NotifyCount` < 1 for 3 × 5 min | **breaching** | Ticket, and feeds the composite |
| `usms-transcript-lag-high` | Max `TranscriptLagSeconds` > 2 s, 2 of 3 min | notBreaching | Ticket, feeds the composite |
| `usms-transcript-pipeline-down` | Composite: lag OR silence | (composite) | **Page** |
| `usms-delivery-ratio-low` (new) | Metric math: notifications / uploads < 0.995 over 1 hour | breaching | Page via composite |
| `usms-cdn-5xx-high` (new) | CloudFront `5xxErrorRate` > 1% for 10 min | notBreaching | Page |

The one that would have caught the six-hour outage is `usms-notify-silence`. When transcripts stopped, the metrics stopped arriving. A threshold alarm on a value (latency above X) evaluates the data it gets; with no data and `notBreaching` it stays OK forever, which is exactly the "green dashboard with empty graphs" the registrar saw. Only an alarm that treats missing data as breaching turns silence into an alert. The caveat: during genuinely quiet periods (2 am, holidays) silence is normal, so this alarm needs either a schedule-aware threshold or a synthetic heartbeat transcript uploaded every 10 minutes, which I would add.

## 5. Where the bill goes

Order of magnitude, for USMS's size (thousands of transcripts a day, not millions):

- **Log storage with no retention** - the largest line, because it grows forever. Every group in Step 5's inventory was "never expire". Setting retention (done in Step 6) is the biggest single saving.
- **Log ingestion** - debug-level output from functions and containers, billed per GB ingested. Second biggest; fix by logging structured events at INFO and sampling debug output.
- **Custom metrics by cardinality** - each distinct dimension combination is a billed metric. This is where a mistake explodes: a `StudentId` dimension would create one metric per student, thousands of times the cost of everything else.
- **Logs Insights queries** - billed per GB scanned; a dashboard widget running a query over 30 days every minute adds up.
- **X-Ray** - small at 10% sampling.

Cardinality of every proposed dimension: `Faculty` ≈ 8 values; `Stage` = 4 (notify, origin, viewer-request, render); `Service` = 5. The combinations used are `Faculty × Stage` (≈ 32 metrics) and `Stage` alone (4). No dimension uses a student id, transcript id or request id; those go in logs and trace annotations.

The two changes with the largest effect: retention on every log group, and keeping per-student and per-request values out of metric dimensions.

## 6. What I would not build yet

A full distributed tracing rollout across every USMS service (the ECS enrolment API, the EKS services, the edge functions). Today the incident the registrar describes involves three hops of one pipeline, and tracing the notifier covers it. Instrumenting everything costs development time and X-Ray spend for questions nobody is asking. What would change my mind: a second incident where we could not tell which service was slow, or a cross-service request path (portal → API → results) becoming the main complaint.

## What I would measure before committing

- Real daily volumes of uploads, downloads and log GB per group, which decide the retention and cost numbers.
- The normal hourly pattern of notifications, which decides whether the silence alarm needs a heartbeat or a schedule.
- How long the registrar actually needs access records, which decides the audit retention.
