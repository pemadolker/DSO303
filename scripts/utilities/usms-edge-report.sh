#!/usr/bin/env bash
# Emit one JSON document describing every usms- Lambda function and whether it could be
# associated with CloudFront as a Lambda@Edge function. JSON on stdout, diagnostics on stderr.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

python3 - << 'PY'
import json, subprocess, sys

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        print("aws %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()), file=sys.stderr)
        return None
    return json.loads(r.stdout or "null")

fns = aws("lambda", "list-functions",
          "--query", "Functions[?starts_with(FunctionName, `usms-`)]") or []
report = []
for f in sorted(fns, key=lambda x: x["FunctionName"]):
    name = f["FunctionName"]
    versions = aws("lambda", "list-versions-by-function", "--function-name", name,
                   "--query", "Versions[?Version!='$LATEST'].Version") or []
    aliases = aws("lambda", "list-aliases", "--function-name", name,
                  "--query", "Aliases[].Name") or []
    env = bool((f.get("Environment") or {}).get("Variables") or {})
    vpc = bool((f.get("VpcConfig") or {}).get("SubnetIds") or [])
    runtime = f.get("Runtime") or ""
    memory, timeout = f.get("MemorySize", 0), f.get("Timeout", 0)
    cap_mem, cap_timeout = (128, 5) if "viewer" in name else (10240, 30)
    reasons = []
    if not runtime.startswith(("nodejs", "python")):
        reasons.append("runtime %s not allowed at the edge" % runtime)
    if env:
        reasons.append("has environment variables")
    if vpc:
        reasons.append("attached to a VPC")
    if not versions:
        reasons.append("no published version")
    if memory > cap_mem:
        reasons.append("memory %d MB over the %d MB cap" % (memory, cap_mem))
    if timeout > cap_timeout:
        reasons.append("timeout %d s over the %d s cap" % (timeout, cap_timeout))
    report.append({
        "name": name, "runtime": runtime, "memory": memory, "timeout": timeout,
        "versions": len(versions), "aliases": len(aliases), "env_vars": env,
        "edge_eligible": not reasons, "reasons": reasons,
    })
print(json.dumps(report, indent=2))
PY
