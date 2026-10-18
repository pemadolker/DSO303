#!/usr/bin/env bash
# usms-scaling-report.sh - Lab 06 Exercise 3
# Prints the scaling decision table for every ECS scalable target whose cluster
# name starts with "usms-", with a verdict computed from the target's own fields.
# Also writes outputs/lab-06-scaling-report.json.
# Read-only: it only calls describe-* / list-* APIs. No arguments.
#
# Why no "set -e": several calls are expected to fail on some builds
# (describe-scheduled-actions is UnsupportedOperation on Floci 2.2.0, and
# describe-scaling-activities may be missing). A report that dies on the first
# unsupported call would print nothing useful, so every call is checked
# individually and a failure becomes a line such as "unavailable" instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# course.env carries the profile / endpoint settings; nothing else is needed,
# because every name below is discovered from the API.
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

OUT_JSON="$REPO_ROOT/outputs/lab-06-scaling-report.json"
mkdir -p "$REPO_ROOT/outputs"

# Level 1 of discovery happens here; python3 does the rest.
if ! TARGETS_JSON=$(aws application-autoscaling describe-scalable-targets \
                      --service-namespace ecs --output json 2>/dev/null); then
  echo "cannot reach Application Auto Scaling (is Floci running?)" >&2
  exit 1
fi

python3 - "$OUT_JSON" "$TARGETS_JSON" <<'PY'
import json, re, subprocess, sys

out_path, targets_raw = sys.argv[1], sys.argv[2]

def aws(*args):
    """Run an aws CLI call and return parsed JSON, or None if the call failed."""
    r = subprocess.run(["aws", *args, "--output", "json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "null")
    except json.JSONDecodeError:
        return None

def num(x):
    """50.0 -> '50.0', 60 -> '60', None -> '-'"""
    return "-" if x is None else str(x)

METRIC_SHORT = {
    "ECSServiceAverageCPUUtilization": "CPU",
    "ECSServiceAverageMemoryUtilization": "Memory",
    "ALBRequestCountPerTarget": "ALBReq",
}
OPS = {
    "GreaterThanOrEqualToThreshold": ">=", "GreaterThanThreshold": ">",
    "LessThanThreshold": "<", "LessThanOrEqualToThreshold": "<=",
}

def verdict(t, desired, n_policies):
    # Evaluated top to bottom; the first rule that matches wins.
    # PINNED first: if min == max nothing can ever change the count, so every
    #   other state is meaningless.
    # FROZEN before AT-CEILING: a suspended target will not scale in either
    #   direction, and that is the hazard nobody sees (policies and alarms all
    #   look normal). "At the ceiling" describes the count; "frozen" says the
    #   control loop is switched off, which is the fact an operator must act on.
    #   A target that is frozen AND at the ceiling cannot come back down by itself.
    # AT-CEILING before AT-FLOOR: at the ceiling, demand may be going unserved;
    #   at the floor with several policies, the service is simply idle.
    # ELASTIC: none of the above - the loop is free to move in both directions.
    lo, hi = t.get("MinCapacity"), t.get("MaxCapacity")
    if lo is not None and lo == hi:
        return "PINNED"
    if any(v is True for v in (t.get("SuspendedState") or {}).values()):
        return "FROZEN"
    if desired is not None and desired == hi:
        return "AT-CEILING"
    if desired is not None and desired == lo and n_policies > 1:
        return "AT-FLOOR"
    return "ELASTIC"

def signed_steps(cfg):
    steps = (cfg or {}).get("StepAdjustments") or []
    return " / ".join(f"{s['ScalingAdjustment']:+d}" for s in steps) or "no steps"

targets = (json.loads(targets_raw) or {}).get("ScalableTargets") or []
pattern = re.compile(r"^service/(usms-[^/]+)/([^/]+)$")
targets = [t for t in targets if pattern.match(t.get("ResourceId", ""))]

if not targets:
    print("no ecs scalable targets on a usms- cluster")
    json.dump({"targets": []}, open(out_path, "w"), indent=2)
    sys.exit(0)

# Every alarm once; then look them up by name or by the ARN they invoke.
# Batching like this means one describe-alarms call instead of one per policy.
all_alarms = (aws("cloudwatch", "describe-alarms") or {}).get("MetricAlarms") or []
by_name = {a["AlarmName"]: a for a in all_alarms}

report = []
for t in sorted(targets, key=lambda x: x["ResourceId"]):
    rid, dim = t["ResourceId"], t["ScalableDimension"]
    cluster, service = pattern.match(rid).groups()

    svc = aws("ecs", "describe-services", "--cluster", cluster, "--services", service)
    svc = ((svc or {}).get("services") or [{}])[0]
    desired, running = svc.get("desiredCount"), svc.get("runningCount")

    pols = aws("application-autoscaling", "describe-scaling-policies",
               "--service-namespace", "ecs", "--resource-id", rid)
    pols = sorted((pols or {}).get("ScalingPolicies") or [], key=lambda p: p["PolicyName"])

    sched_raw = aws("application-autoscaling", "describe-scheduled-actions",
                    "--service-namespace", "ecs", "--resource-id", rid)
    sched = None if sched_raw is None else (sched_raw.get("ScheduledActions") or [])

    acts_raw = aws("application-autoscaling", "describe-scaling-activities",
                   "--service-namespace", "ecs", "--resource-id", rid, "--max-items", "1")
    acts = None if acts_raw is None else (acts_raw.get("ScalingActivities") or [])

    v = verdict(t, desired, len(pols))
    susp = [k for k, val in (t.get("SuspendedState") or {}).items() if val is True]

    print(f"{rid}   {dim}")
    print(f"  bounds       min={t.get('MinCapacity')}  max={t.get('MaxCapacity')}   "
          f"desired={num(desired)}   running={num(running)}   {v}")
    print(f"  suspended    {', '.join(susp) if susp else 'none'}")

    pol_out = []
    if not pols:
        print("  policies     none")
    for p in pols:
        name, ptype = p["PolicyName"], p["PolicyType"]
        # Alarms that invoke this policy: the policy's own list first (AWS fills it),
        # then any alarm whose actions name the policy ARN (Floci leaves the list
        # empty for alarms you attach yourself).
        names = [a["AlarmName"] for a in (p.get("Alarms") or [])]
        names += [a["AlarmName"] for a in all_alarms
                  if p.get("PolicyARN") in (a.get("AlarmActions") or []) and a["AlarmName"] not in names]
        alarms = [by_name[n] for n in names if n in by_name]

        if ptype == "TargetTrackingScaling":
            c = p.get("TargetTrackingScalingPolicyConfiguration") or {}
            pm = (c.get("PredefinedMetricSpecification") or {}).get("PredefinedMetricType")
            cm = (c.get("CustomizedMetricSpecification") or {}).get("MetricName")
            label = METRIC_SHORT.get(pm, pm or cm or "custom")
            extra = "  scale-in disabled" if c.get("DisableScaleIn") else ""
            print(f"  target-track {name:<42} {label}/{num(c.get('TargetValue')):<9} "
                  f"out={num(c.get('ScaleOutCooldown'))}  in={num(c.get('ScaleInCooldown'))}{extra}")
            if alarms:
                parts = []
                for a in alarms:
                    kind = "AlarmHigh" if "AlarmHigh" in a["AlarmName"] else \
                           "AlarmLow" if "AlarmLow" in a["AlarmName"] else a["AlarmName"]
                    parts.append(f"{kind}={a.get('StateValue')}")
                print(f"                 alarms  {'  '.join(parts)}")
            else:
                print("                 alarms  none listed")
        elif ptype == "StepScaling":
            c = p.get("StepScalingPolicyConfiguration") or {}
            print(f"  step         {name:<42} {signed_steps(c):<15} cooldown={num(c.get('Cooldown'))}")
            if alarms:
                for a in alarms:
                    op = OPS.get(a.get("ComparisonOperator"), a.get("ComparisonOperator"))
                    thr = a.get("Threshold")
                    thr = int(thr) if isinstance(thr, float) and thr.is_integer() else thr
                    print(f"                 alarm   {a['AlarmName']} = {a.get('StateValue')}  "
                          f"({a.get('Namespace')} {a.get('MetricName')} {op} {thr})")
            else:
                print("                 alarm   none - nothing can invoke this policy")
        else:
            print(f"  {ptype:<12} {name}")
        pol_out.append({"name": name, "type": ptype,
                        "alarms": [{"name": a["AlarmName"], "state": a.get("StateValue")} for a in alarms]})

    if sched is None:
        print("  scheduled    unavailable on this build")
    elif not sched:
        print("  scheduled    none")
    for s in sched or []:
        sta = s.get("ScalableTargetAction") or {}
        print(f"  scheduled    {s['ScheduledActionName']:<33} {s.get('Schedule')}  "
              f"{s.get('Timezone') or 'UTC'}  min={num(sta.get('MinCapacity'))}")

    if acts is None:
        print("  last activity  unavailable on this build")
    elif not acts:
        print("  last activity  none recorded")
    else:
        a = acts[0]
        print(f"  last activity  {a.get('StartTime')}  {a.get('StatusCode')}  {a.get('Description')}")

    report.append({
        "resourceId": rid, "dimension": dim,
        "min": t.get("MinCapacity"), "max": t.get("MaxCapacity"),
        "desired": desired, "running": running, "verdict": v, "suspended": susp,
        "policies": pol_out,
        "scheduledActions": None if sched is None else [s["ScheduledActionName"] for s in sched],
        "lastActivity": None if not acts else acts[0],
    })
    print()

with open(out_path, "w") as f:
    json.dump({"targets": report}, f, indent=2, default=str)
print(f"written {out_path}")
PY
