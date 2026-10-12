#!/usr/bin/env bash
# Lab 06 verify - Floci PATH C edition (Application Auto Scaling unsupported on this build).
# Read-only. Checks what exists; reports Application Auto Scaling checks as skip.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
for f in 01 02 03 04 05 06; do source "configs/lab-$f.env" 2>/dev/null || true; done
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECS_DESIRED_BASELINE:=2}"
: "${USMS_ALARM_QUEUE_HIGH:=usms-enrolment-queue-high}"
: "${USMS_METRIC_NAMESPACE:=USMS/Enrolment}"

PASS=0; FAIL=0; SKIP=0
check() { if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1));
          else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi; }
skip()  { printf "  skip %s\n" "$1"; SKIP=$((SKIP+1)); }
svcq()  { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
            --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }

echo "== Environment =="
check "Floci container running" \
  'test "$(docker container inspect $FLOCI_CONTAINER_NAME --format "{{.State.Running}}")" = true'
check "Storage mode is NOT memory" \
  'docker container inspect $FLOCI_CONTAINER_NAME --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -qE "^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$"'
check "AWS CLI reaches Floci" 'aws sts get-caller-identity'
check "Account is 000000000000" \
  'test "$(aws sts get-caller-identity --query Account --output text)" = 000000000000'

echo "== Service state (unchanged by this lab) =="
check "service is ACTIVE" 'test "$(svcq status)" = ACTIVE'
check "desiredCount is the baseline" 'test "$(svcq desiredCount)" = "$USMS_ECS_DESIRED_BASELINE"'
check "service has exactly ONE loadBalancers entry" 'test "$(svcq "length(loadBalancers)")" = 1'
check "task definition is still usms-enrolment:2" 'svcq taskDefinition | grep -q "usms-enrolment:2$"'

echo "== CloudWatch objects (these DO exist on this build) =="
check "alarm $USMS_ALARM_QUEUE_HIGH exists" \
  'aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" --query "MetricAlarms[0].AlarmName" --output text | grep -qx "$USMS_ALARM_QUEUE_HIGH"'
check "alarm watches the custom metric" \
  'test "$(aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" --query "MetricAlarms[0].MetricName" --output text)" = EnrolmentQueueDepth'
check "alarm threshold is 100" \
  'test "$(aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" --query "MetricAlarms[0].Threshold" --output text | cut -d. -f1)" = 100'
check "custom metric namespace has at least one metric" \
  'test "$(aws cloudwatch list-metrics --namespace "$USMS_METRIC_NAMESPACE" --query "length(Metrics)" --output text)" -ge 1'

echo "== Application Auto Scaling (Path C) =="
if aws application-autoscaling describe-scalable-targets --service-namespace ecs >/dev/null 2>&1; then
  echo "  NOTE: Application Auto Scaling answers on this build - use the full verify script."
else
  skip "scalable target, policies, scheduled actions, suspension (service not implemented)"
fi

echo "== Files and Git hygiene =="
check "configs/lab-06.env exists" 'test -f configs/lab-06.env'
check "configs/lab-06.env has no empty values and no None" '! grep -qE "export [A-Z_]+=$|=None$" configs/lab-06.env'
for t in target-tracking-cpu target-tracking-requests step-scaling-out suspended-state; do
  check "templates/lab-06-$t.json is valid JSON" "python3 -m json.tool templates/lab-06-$t.json"
done
check "suspended-state document does NOT suspend scale-out" \
  "python3 -c \"import json,sys;d=json.load(open('templates/lab-06-suspended-state.json'));sys.exit(0 if d.get('DynamicScalingOutSuspended') is False else 1)\""
check "no Lab 06 document contains an unexpanded variable" '! grep -l "[$]" templates/lab-06-*.json'
check "no outputs/ file is tracked by git" '! git ls-files | grep -q "^outputs/[^.]"'

echo; echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
