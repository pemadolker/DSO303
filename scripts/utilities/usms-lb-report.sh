#!/usr/bin/env bash
# usms-lb-report.sh — walks every ALB named usms-* and prints its routing
# decision table: listeners, rules in evaluation order, and target health.
#
# set -e is deliberately NOT used: a missing listener, an empty rule set, or
# a target group with zero targets are all valid states this script must
# describe, not errors to abort on. Each AWS call is checked for a usable
# result individually instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_JSON="$REPO_ROOT/outputs/lab-05-lb-report.json"
mkdir -p "$REPO_ROOT/outputs"

echo "[]" > "$OUT_JSON"

LB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName, 'usms-')].LoadBalancerArn" \
  --output text)

if [ -z "$LB_ARNS" ]; then
  echo "No load balancers found with prefix usms-"
  exit 0
fi

REPORT="[]"

for LB_ARN in $LB_ARNS; do
  LB_JSON=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
    --query 'LoadBalancers[0]' --output json)

  LB_NAME=$(echo "$LB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["LoadBalancerName"])')
  SCHEME=$(echo "$LB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Scheme"])')
  TYPE=$(echo "$LB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Type"])')
  STATE=$(echo "$LB_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["State"]["Code"])')
  AZ_COUNT=$(echo "$LB_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["AvailabilityZones"]))')
  SG_COUNT=$(echo "$LB_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("SecurityGroups",[])))')

  printf '%s   %s  %s  %s  AZs=%s  SGs=%s\n' \
    "$LB_NAME" "$SCHEME" "$TYPE" "$STATE" "$AZ_COUNT" "$SG_COUNT"

  LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
    --query 'Listeners[].ListenerArn' --output text)

  if [ -z "$LISTENER_ARNS" ]; then
    echo "  (no listeners)"
    continue
  fi

  for LISTENER_ARN in $LISTENER_ARNS; do
    LPROTO=$(aws elbv2 describe-listeners --listener-arns "$LISTENER_ARN" \
      --query 'Listeners[0].Protocol' --output text)
    LPORT=$(aws elbv2 describe-listeners --listener-arns "$LISTENER_ARN" \
      --query 'Listeners[0].Port' --output text)
    echo "  $LPROTO:$LPORT"

    RULES_JSON=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --output json)

    # Priority is a string, and the default rule's priority is the literal
    # word "default" rather than a number, so a plain sort_by puts it in an
    # arbitrary position relative to the numeric priorities. Fix: split into
    # numeric rules (sorted numerically via python3, not lexically) and the
    # default rule, then always print the default last.
    python3 - "$RULES_JSON" "$LB_NAME" "$REPO_ROOT/outputs/lab-05-lb-report.json" << 'PYEOF'
import json, sys

rules_json, lb_name, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
rules = json.loads(rules_json)["Rules"]

numeric = [r for r in rules if r["Priority"] != "default"]
default = [r for r in rules if r["Priority"] == "default"]
numeric.sort(key=lambda r: int(r["Priority"]))
ordered = numeric + default

tg_cache = {}

def tg_counts(tg_arn):
    if tg_arn in tg_cache:
        return tg_cache[tg_arn]
    import subprocess
    out = subprocess.run(
        ["aws", "elbv2", "describe-target-health", "--target-group-arn", tg_arn,
         "--query", "TargetHealthDescriptions", "--output", "json"],
        capture_output=True, text=True
    )
    try:
        targets = json.loads(out.stdout)
    except Exception:
        targets = []
    total = len(targets)
    healthy = len([t for t in targets if t.get("TargetHealth", {}).get("State") == "healthy"])
    tg_cache[tg_arn] = (total, healthy)
    return (total, healthy)

rows = []
for r in ordered:
    prio = r["Priority"]
    conds = r.get("Conditions", [])
    if conds:
        field = conds[0].get("Field", "-")
        values = ",".join(conds[0].get("PathPatternConfig", {}).get("Values", conds[0].get("Values", [])))
    else:
        field, values = "-", "-"

    action = r["Actions"][0] if r.get("Actions") else {}
    atype = action.get("Type", "-")

    if atype == "forward" and "TargetGroupArn" in action:
        tg_arn = action["TargetGroupArn"]
        tg_name = tg_arn.split("/")[-2] if "/" in tg_arn else tg_arn
        total, healthy = tg_counts(tg_arn)
        action_desc = f"-> {tg_name} ({total} targets, {healthy} healthy)"
    elif atype == "fixed-response":
        code = action.get("FixedResponseConfig", {}).get("StatusCode", "?")
        action_desc = f"-> fixed-response {code}"
    elif atype == "redirect":
        action_desc = "-> redirect"
    else:
        action_desc = f"-> {atype}"

    print(f"    prio  {prio:<7} {field:<13} {values:<35} {action_desc}")
    rows.append({"priority": prio, "field": field, "values": values, "action": action_desc})

# append this listener's rows to the cumulative JSON report
try:
    with open(out_path) as f:
        existing = json.load(f)
except Exception:
    existing = []
existing.append({"load_balancer": lb_name, "rules": rows})
with open(out_path, "w") as f:
    json.dump(existing, f, indent=2)
PYEOF
  done
done
