#!/usr/bin/env bash
# Build outputs/lab-09-identity-inventory.json: every role, its trust policy, boundary and policy documents.
# Read-only. Each AWS call is retried, because a failed call must never silently drop data.
# The boundary comes from get-role, because list-roles does not return PermissionsBoundary.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
python3 - << 'PY' > outputs/lab-09-identity-inventory.json
import json, subprocess, sys
def aws(*args):
    for _ in range(3):
        out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            try: return json.loads(out.stdout)
            except Exception: pass
    print("WARNING: failed 3 times: aws " + " ".join(args), file=sys.stderr)
    return None
inv = []
for r in (aws("iam", "list-roles") or {}).get("Roles", []):
    name = r["RoleName"]
    role = (aws("iam", "get-role", "--role-name", name) or {}).get("Role", r)
    d = {"role": name, "arn": role.get("Arn"), "maxSessionDuration": role.get("MaxSessionDuration"),
         "permissionsBoundary": (role.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn"),
         "trustPolicy": role.get("AssumeRolePolicyDocument"), "attachedPolicies": [], "inlinePolicies": []}
    for p in (aws("iam", "list-attached-role-policies", "--role-name", name) or {}).get("AttachedPolicies", []):
        ver = ((aws("iam", "get-policy", "--policy-arn", p["PolicyArn"]) or {}).get("Policy") or {}).get("DefaultVersionId")
        doc = ((aws("iam", "get-policy-version", "--policy-arn", p["PolicyArn"], "--version-id", ver) or {}).get("PolicyVersion") or {}).get("Document") if ver else None
        d["attachedPolicies"].append({"name": p["PolicyName"], "arn": p["PolicyArn"], "version": ver, "document": doc})
    for pn in (aws("iam", "list-role-policies", "--role-name", name) or {}).get("PolicyNames", []):
        d["inlinePolicies"].append({"name": pn, "document": (aws("iam", "get-role-policy", "--role-name", name, "--policy-name", pn) or {}).get("PolicyDocument")})
    inv.append(d)
print(json.dumps(inv, indent=2, default=str))
PY
python3 -c "import json;d=json.load(open('outputs/lab-09-identity-inventory.json'));print(f'{len(d)} roles inventoried')"
