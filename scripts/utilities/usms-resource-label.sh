#!/usr/bin/env bash
# usms-resource-label.sh — derives the ResourceLabel string Application Auto
# Scaling's ALBRequestCountPerTarget predefined metric needs, purely from the
# API. Never hard-code an identifier here — the point of this script is that
# Lab 06 and the CloudFormation lab can call it unchanged in any account.
set -euo pipefail

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
  echo "could not resolve load balancer '$LB_NAME'" >&2
  exit 1
fi
if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  echo "could not resolve target group '$TG_NAME'" >&2
  exit 1
fi

# The load balancer's suffix is everything after ":loadbalancer/" — a fixed
# marker string, so parameter expansion's "##*/" (strip up to the last
# slash) is wrong here: it would strip too much. We need "##*:loadbalancer/"
# instead, removing up to that specific marker, since the ARN has more
# slashes after it that belong in the suffix.
LB_SUFFIX="${LB_ARN##*:loadbalancer/}"

# The target group's suffix starts at the literal word "targetgroup" and
# keeps everything after it — here "##*/" strips up to the LAST slash before
# that word would also be wrong (it would strip "targetgroup/" itself), so
# instead we cut on the segment before it and rebuild with awk-free shell:
# everything from "targetgroup/" onward is what we want, which IS reachable
# with "##*:" (strip up to the last colon, which is the ARN's own account
# separator) only if "targetgroup" were the final colon-delimited field —
# it is not, so parameter expansion alone cannot cleanly isolate it without
# knowing the exact marker; we anchor on the known literal instead:
TG_SUFFIX="targetgroup/${TG_ARN#*targetgroup/}"

LABEL="${LB_SUFFIX}/${TG_SUFFIX}"

# Validate: contains both names, exactly six slash-separated segments, first
# segment is the literal "app" (an NLB's equivalent would be "net" instead —
# the segment names which load-balancer type produced the ARN, since the two
# types' ARN formats are otherwise identical in shape).
SEGMENT_COUNT=$(echo "$LABEL" | awk -F'/' '{print NF}')
if [ "$SEGMENT_COUNT" -ne 6 ]; then
  echo "unexpected segment count ($SEGMENT_COUNT) in: $LABEL" >&2
  exit 1
fi
case "$LABEL" in
  app/*) : ;;
  *) echo "expected label to start with 'app/', got: $LABEL" >&2; exit 1 ;;
esac
case "$LABEL" in
  *"$LB_NAME"*) : ;;
  *) echo "label missing load balancer name: $LABEL" >&2; exit 1 ;;
esac
case "$LABEL" in
  *"$TG_NAME"*) : ;;
  *) echo "label missing target group name: $LABEL" >&2; exit 1 ;;
esac

echo "$LABEL"
