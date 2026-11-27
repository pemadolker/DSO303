#!/usr/bin/env bash
# Generate templates/lab-13-dashboard.json from the account id and region in configs/, then put it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-01.env
ACCT="${USMS_ACCOUNT_ID:?USMS_ACCOUNT_ID missing from configs/lab-01.env}"
REGION="${AWS_REGION_COURSE:?AWS_REGION_COURSE missing from configs/course.env}"

cat > templates/lab-13-dashboard.json << EOF
{
  "widgets": [
    { "type": "text", "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": { "markdown": "# USMS - transcript delivery\\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only." } },
    { "type": "metric", "x": 0, "y": 2, "width": 12, "height": 6,
      "properties": { "title": "Transcripts processed, by faculty", "region": "${REGION}", "stat": "Sum", "period": 300,
        "view": "timeSeries", "stacked": false,
        "metrics": [ [ "USMS/Application", "TranscriptsProcessed", "Faculty", "science", "Stage", "notify" ],
                     [ "USMS/Application", "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify" ] ] } },
    { "type": "metric", "x": 12, "y": 2, "width": 12, "height": 6,
      "properties": { "title": "Notification latency - max and average", "region": "${REGION}", "period": 60, "view": "timeSeries",
        "metrics": [ [ "USMS/Application", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Maximum", "label": "max" } ],
                     [ "USMS/Application", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Average", "label": "avg" } ] ],
        "annotations": { "horizontal": [ { "label": "alarm threshold", "value": 2 } ] } } },
    { "type": "metric", "x": 0, "y": 8, "width": 8, "height": 4,
      "properties": { "title": "Notifications in the last 5 minutes", "region": "${REGION}", "stat": "Sum", "period": 300,
        "view": "singleValue",
        "metrics": [ [ "USMS/Application", "NotifyCount" ], [ "USMS/Application", "CentralErrorCount" ] ] } },
    { "type": "alarm", "x": 8, "y": 8, "width": 16, "height": 4,
      "properties": { "title": "Pipeline alarms",
        "alarms": [ "arn:aws:cloudwatch:${REGION}:${ACCT}:alarm:usms-transcript-pipeline-down",
                    "arn:aws:cloudwatch:${REGION}:${ACCT}:alarm:usms-transcript-lag-high",
                    "arn:aws:cloudwatch:${REGION}:${ACCT}:alarm:usms-notify-silence" ] } },
    { "type": "metric", "x": 0, "y": 12, "width": 24, "height": 6,
      "properties": { "title": "Central errors - last 3 hours", "region": "${REGION}", "stat": "Sum", "period": 300,
        "view": "timeSeries", "start": "-PT3H",
        "metrics": [ [ "USMS/Application", "CentralErrorCount" ] ],
        "annotations": { "horizontal": [ { "label": "page threshold (proposed, no alarm yet)", "value": 1 } ] } } }
  ]
}
EOF
python3 -m json.tool templates/lab-13-dashboard.json > /dev/null && echo "generated templates/lab-13-dashboard.json (valid JSON)"
aws cloudwatch put-dashboard --dashboard-name usms-overview \
  --dashboard-body file://templates/lab-13-dashboard.json --query 'DashboardValidationMessages' --output json
