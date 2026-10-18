#!/usr/bin/env bash
# Removes the Task A practice objects so verify-lab-05.sh is back to its documented result.
# Order: the rules first (one of them forwards to the target group), then the target group.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for f in course lab-05; do source "configs/$f.env"; done
set -x
for p in 5 30; do
  ARN=$(aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
        --query "Rules[?Priority=='$p'].RuleArn | [0]" --output text)
  [ -n "$ARN" ] && [ "$ARN" != "None" ] && aws elbv2 delete-rule --rule-arn "$ARN"
done
TG=$(aws elbv2 describe-target-groups --names usms-transcripts-tg \
     --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
[ -n "$TG" ] && [ "$TG" != "None" ] && aws elbv2 delete-target-group --target-group-arn "$TG"
aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" --query 'Rules[].Priority' --output text
