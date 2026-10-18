#!/usr/bin/env bash
# usms-scaling-history.sh - Lab 06 Exercise 5
# Exports the enrolment service's complete scaling configuration and history as ONE
# JSON document: outputs/lab-06-scaling-history.json (Lab 10 uploads it as its first object).
# Contents: the scalable target (bounds, suspension), every policy, every scheduled action,
# every alarm involved (with its state), and every scaling activity, including not-scaled ones.
# Every identifier is discovered: usms-* cluster -> its services -> the service ARN ->
# resource ID; nothing is hard-coded beyond the "usms-" prefix. Read-only. No arguments.
# Works from any directory. Contains, reads and references no access keys.
#
# No "set -e", for the same reason as usms-scaling-report.sh: some calls are expected to be
# unsupported on Floci (scheduled actions), and that should be recorded in the file, not abort it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
OUT="$REPO_ROOT/outputs/lab-06-scaling-history.json"
mkdir -p "$REPO_ROOT/outputs"

python3 - "$OUT" <<'PY'
import datetime, json, subprocess, sys

out_path = sys.argv[1]

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr.strip().splitlines() or ["failed"])[-1]
    try:
        return json.loads(r.stdout or "null"), None
    except json.JSONDecodeError as e:
        return None, str(e)

# 1. Discover the service: usms-* clusters -> their services -> service ARN -> resource ID.
clusters, err = aws("ecs", "list-clusters")
if clusters is None:
    sys.exit(f"cannot list ECS clusters: {err}")
cluster_arns = [c for c in clusters.get("clusterArns", []) if c.split("/")[-1].startswith("usms-")]

targets_doc, _ = aws("application-autoscaling", "describe-scalable-targets", "--service-namespace", "ecs")
targets = {t["ResourceId"]: t for t in (targets_doc or {}).get("ScalableTargets", [])}

service_arn = rid = None
for c in cluster_arns:
    svcs, _ = aws("ecs", "list-services", "--cluster", c)
    for s in (svcs or {}).get("serviceArns", []):
        candidate = s.split(":")[-1]          # same as ${SVC_ARN##*:} in Step 14
        if candidate in targets:              # the service that has a scalable target
            service_arn, rid = s, candidate
            break
    if rid:
        break
if not rid:
    sys.exit("no usms- ECS service with a scalable target found")

# 2. Everything attached to that resource ID.
policies, _ = aws("application-autoscaling", "describe-scaling-policies",
                  "--service-namespace", "ecs", "--resource-id", rid)
policies = (policies or {}).get("ScalingPolicies", [])

sched, sched_err = aws("application-autoscaling", "describe-scheduled-actions",
                       "--service-namespace", "ecs", "--resource-id", rid)

acts, acts_err = aws("application-autoscaling", "describe-scaling-activities",
                     "--service-namespace", "ecs", "--resource-id", rid,
                     "--include-not-scaled-activities")

# 3. Every alarm involved: the ones a policy lists, plus any alarm whose actions name a policy ARN.
all_alarms, _ = aws("cloudwatch", "describe-alarms")
all_alarms = (all_alarms or {}).get("MetricAlarms", [])
policy_arns = {p.get("PolicyARN") for p in policies}
listed = {a["AlarmName"] for p in policies for a in (p.get("Alarms") or [])}
alarms = [a for a in all_alarms
          if a["AlarmName"] in listed or policy_arns & set(a.get("AlarmActions") or [])]

doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resourceId": rid,
    "serviceArn": service_arn,
    "scalableTarget": targets[rid],
    "scalingPolicies": policies,
    "scheduledActions": (sched or {}).get("ScheduledActions") if sched is not None
                        else {"unavailable": sched_err},
    "alarms": alarms,
    "scalingActivities": (acts or {}).get("ScalingActivities") if acts is not None
                         else {"unavailable": acts_err},
}
with open(out_path, "w") as f:
    json.dump(doc, f, indent=2, default=str)
print(f"resourceId   {rid}")
print(f"policies     {len(policies)}")
print(f"alarms       {len(alarms)}")
print(f"scheduled    {'unavailable' if sched is None else len(doc['scheduledActions'])}")
print(f"activities   {'unavailable' if acts is None else len(doc['scalingActivities'])}")
print(f"written      {out_path}")
PY
