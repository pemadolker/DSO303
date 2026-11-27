#!/usr/bin/env bash
# For every usms- alarm: its configuration plus what its metric actually did in the last 24 hours.
# JSON on stdout only; diagnostics on stderr. Safe under set -u; handles composites and empty metrics.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

python3 - << 'PY'
import datetime, json, subprocess, sys

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        print("aws %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()), file=sys.stderr)
        return None
    return json.loads(r.stdout or "null")

end = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = end - datetime.timedelta(hours=24)
alarms = aws("cloudwatch", "describe-alarms", "--alarm-name-prefix", "usms-",
             "--alarm-types", "MetricAlarm", "CompositeAlarm") or {}
report = []
for a in alarms.get("MetricAlarms", []):
    dims = a.get("Dimensions") or []
    args = ["cloudwatch", "get-metric-statistics", "--namespace", a["Namespace"],
            "--metric-name", a["MetricName"], "--start-time", start.isoformat(),
            "--end-time", end.isoformat(), "--period", "3600",
            "--statistics", "Minimum", "Average", "Maximum", "SampleCount"]
    if dims:
        args += ["--dimensions"] + ["Name=%s,Value=%s" % (d["Name"], d["Value"]) for d in dims]
    pts = (aws(*args) or {}).get("Datapoints", [])
    samples = sum(p.get("SampleCount", 0) for p in pts)
    if pts:
        mn = min(p["Minimum"] for p in pts); mx = max(p["Maximum"] for p in pts)
        avg = sum(p["Average"] * p["SampleCount"] for p in pts) / samples if samples else None
        observed = {"min": mn, "avg": round(avg, 4) if avg is not None else None, "max": mx, "samples": samples}
    else:
        observed = {"min": None, "avg": None, "max": None, "samples": 0}
    stat_val = observed["max"] if a["ComparisonOperator"].startswith("Greater") else observed["min"]
    th, op = a["Threshold"], a["ComparisonOperator"]
    breached = None if stat_val is None else {
        "GreaterThanThreshold": stat_val > th, "GreaterThanOrEqualToThreshold": stat_val >= th,
        "LessThanThreshold": stat_val < th, "LessThanOrEqualToThreshold": stat_val <= th}.get(op)
    report.append({
        "alarm": a["AlarmName"], "type": "metric", "namespace": a["Namespace"], "metric": a["MetricName"],
        "dimensions": {d["Name"]: d["Value"] for d in dims}, "statistic": a.get("Statistic"),
        "period": a.get("Period"), "evaluation_periods": a.get("EvaluationPeriods"),
        "datapoints_to_alarm": a.get("DatapointsToAlarm"), "threshold": th, "operator": op,
        "missing_data": a.get("TreatMissingData"), "observed": observed,
        "threshold_ever_breached": breached})
for c in alarms.get("CompositeAlarms", []):
    report.append({"alarm": c["AlarmName"], "type": "composite", "rule": c.get("AlarmRule"),
                   "namespace": None, "metric": None, "statistic": None, "threshold": None,
                   "operator": None, "missing_data": None,
                   "observed": {"min": None, "avg": None, "max": None, "samples": 0},
                   "threshold_ever_breached": None})
print(json.dumps(sorted(report, key=lambda r: r["alarm"]), indent=2))
PY
