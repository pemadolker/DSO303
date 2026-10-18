#!/usr/bin/env bash
# Lab 05 Section 13.1 Task A (practice run): the transcripts target group and two listener rules.
# Run from anywhere:  bash scripts/practice/lab-05-task-a.sh 2>&1 | tee outputs/lab-05-assessment-a.txt
# set -x prints every command before its output, so the captured file shows commands AND results.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for f in course lab-01 lab-02 lab-03 lab-04 lab-05; do source "configs/$f.env"; done
set -x

# 1. Target group: ip targets, HTTP 8080, in usms-vpc, health check on /transcripts/health
#    every 15 s, 4 s timeout, healthy after 2, unhealthy after 3, any 2xx or 3xx counts as healthy.
TRANSCRIPTS_TG_ARN=$(aws elbv2 create-target-group \
  --name usms-transcripts-tg \
  --protocol HTTP --port 8080 \
  --vpc-id "$USMS_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path /transcripts/health \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 4 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200-399 \
  --tags Key=Project,Value=USMS Key=Lab,Value=05 Key=Service,Value=transcripts \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-groups --target-group-arns "$TRANSCRIPTS_TG_ARN" \
  --query 'TargetGroups[0].{Type:TargetType,Proto:Protocol,Port:Port,Vpc:VpcId,Path:HealthCheckPath,Interval:HealthCheckIntervalSeconds,Timeout:HealthCheckTimeoutSeconds,Healthy:HealthyThresholdCount,Unhealthy:UnhealthyThresholdCount,Matcher:Matcher.HttpCode}' \
  --output table

# 2. Deregistration delay 20 s: an attribute change, not a recreate.
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TRANSCRIPTS_TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=20 \
  --query "Attributes[?Key=='deregistration_delay.timeout_seconds']" --output table

# 3. Priority 30: /transcripts and everything below it -> usms-transcripts-tg.
RULE30_ARN=$(aws elbv2 create-rule \
  --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --priority 30 \
  --conditions '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/transcripts","/transcripts/*"]}}]' \
  --actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TRANSCRIPTS_TG_ARN\"}]" \
  --query 'Rules[0].RuleArn' --output text)

# 4. Priority 5: /admin and everything below it -> fixed 503, no target contacted.
#    Priority 5 is the lowest number on the listener, so it is evaluated first.
RULE5_ARN=$(aws elbv2 create-rule \
  --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --priority 5 \
  --conditions '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/admin","/admin/*"]}}]' \
  --actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"503","ContentType":"text/plain","MessageBody":"usms admin api is not exposed publicly"}}]' \
  --query 'Rules[0].RuleArn' --output text)

# 5. All rules in evaluation order. Priority is a string ("5" sorts after "30" as text),
#    so the raw listing is followed by the report tool, which sorts numerically, default last.
aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Paths:Conditions[0].PathPatternConfig.Values,Action:Actions[0].Type,Status:Actions[0].FixedResponseConfig.StatusCode,Target:Actions[0].TargetGroupArn}' \
  --output json
./scripts/utilities/usms-lb-report.sh
