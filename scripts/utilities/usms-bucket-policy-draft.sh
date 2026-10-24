#!/usr/bin/env bash
# Draft the bucket policy for the transcripts bucket (Lab 09 Exercise 5). Applies NOTHING.
#
# Reads outputs/lab-09-identity-inventory.json (Step 4, rebuilt by usms-iam-inventory.sh)
# and every customer managed policy, finds each role granted any s3: action on the bucket,
# and writes:
#   outputs/lab-09-bucket-policy-draft.json   the draft resource policy
#   outputs/lab-09-lab10-readiness.txt        what Lab 10 needs to know
#
# The bucket name is READ from Lab 01's policy document, never typed.
# Works whether or not the bucket exists. Never touches an access key.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
ACCOUNT="${USMS_ACCOUNT_ID:-000000000000}"

INVENTORY="outputs/lab-09-identity-inventory.json"
[ -f "$INVENTORY" ] || { echo "no $INVENTORY - run scripts/utilities/usms-iam-inventory.sh first" >&2; exit 2; }

# The bucket name comes out of Lab 01's policy document.
RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
OBJECT_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" \
  --query 'PolicyVersion.Document' --output json | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d['Statement'] if isinstance(d['Statement'], list) else [d['Statement']]
res = [x for s in st for x in (s['Resource'] if isinstance(s['Resource'], list) else [s['Resource']])]
print(next((x for x in res if x.startswith('arn:aws:s3:::') and x.endswith('/*')), ''))")
# Shell parameter expansion, not sed or python: two small, exact cuts.
#   ${OBJECT_ARN%/*}            drops the trailing "/*"       -> arn:aws:s3:::<bucket>
#   ${BUCKET_ARN#arn:aws:s3:::} drops the fixed ARN prefix    -> <bucket>
BUCKET_ARN="${OBJECT_ARN%/*}"
BUCKET="${BUCKET_ARN#arn:aws:s3:::}"
[ -n "$BUCKET" ] || { echo "could not read the bucket name from USMSStudentDataReadWrite" >&2; exit 2; }

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then EXISTS=yes; else EXISTS=no; fi

python3 - "$INVENTORY" "$BUCKET" "$ACCOUNT" "$EXISTS" << 'PY'
import json, sys
inventory, bucket, account, exists = sys.argv[1:5]
bucket_arn, objects_arn = f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"

def as_list(x):
    return [] if x is None else (x if isinstance(x, list) else [x])

def covers(resource):
    # a statement Resource that reaches the transcripts bucket: "*", the bucket, or anything under it
    return resource == "*" or resource == bucket_arn or resource.startswith(bucket_arn + "/")

grants, policy_names = {}, set()
for role in json.load(open(inventory)):
    for p in role.get("attachedPolicies", []) + role.get("inlinePolicies", []):
        doc = p.get("document") or {}
        for st in as_list(doc.get("Statement")):
            if st.get("Effect") != "Allow":
                continue
            acts = [a for a in as_list(st.get("Action")) if str(a).lower().startswith("s3:")]
            res = [r for r in as_list(st.get("Resource")) if covers(r)]
            if not acts or not res:
                continue
            policy_names.add(p["name"])
            # "*" in an identity policy becomes the two bucket ARNs in a bucket policy
            res = sorted({x for r in res for x in ([bucket_arn, objects_arn] if r == "*" else [r])})
            g = grants.setdefault(role["arn"], {"role": role["role"], "pairs": set()})
            for a in acts:
                for r in res:
                    g["pairs"].add((a, r))

statements = []
for arn in sorted(grants):
    by_res = {}
    for a, r in grants[arn]["pairs"]:
        by_res.setdefault(r, set()).add(a)
    for r in sorted(by_res):
        statements.append({
            "Sid": f"Allow{grants[arn]['role'].replace('-', '').title()}{'Objects' if r.endswith('*') else 'Bucket'}"[:100],
            "Effect": "Allow",
            "Principal": {"AWS": arn},
            "Action": sorted(by_res[r]),
            "Resource": r,
        })
statements.append({
    "Sid": "DenyAnyRequestNotOverTls",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [bucket_arn, objects_arn],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}},
})
allowed = sorted(grants) + [f"arn:aws:iam::{account}:root"]
statements.append({
    "Sid": "DenyEveryoneExceptTheKnownRolesAndTheAccount",
    "Effect": "Deny",
    "NotPrincipal": {"AWS": allowed},
    "Action": "s3:*",
    "Resource": [bucket_arn, objects_arn],
})
draft = {"Version": "2012-10-17", "Statement": statements}
json.dump(draft, open("outputs/lab-09-bucket-policy-draft.json", "w"), indent=2)

# ---- mechanical checks ----
problems = []
for s in statements:
    pr = s.get("Principal", s.get("NotPrincipal"))
    if s["Sid"] == "DenyAnyRequestNotOverTls":
        if pr != "*": problems.append("the insecure-transport Deny must use Principal \"*\"")
        continue
    for a in as_list((pr or {}).get("AWS") if isinstance(pr, dict) else pr):
        if not str(a).startswith("arn:aws:iam::"):
            problems.append(f"{s['Sid']}: principal {a!r} is not an ARN")
text = json.dumps(draft)
for needed in (f'"{bucket_arn}"', f'"{objects_arn}"'):
    if needed not in text:
        problems.append(f"bucket ARN {needed} does not appear")
print("checks:", "PASS" if not problems else "FAIL")
for p in problems:
    print("  -", p)

lines = [
    f"bucket name (read from USMSStudentDataReadWrite) : {bucket}",
    f"bucket exists today                              : {exists}",
    f"policies that grant s3 on the bucket             : {', '.join(sorted(policy_names))}",
]
for arn in sorted(grants):
    lines.append(f"role ARN                                         : {arn}")
lines += [
    f"principals in the Allow statements               : {len(grants)} roles (+ the account root, kept out of the Deny)",
    "what changes when Lab 10 runs create-bucket      : nothing changes for any role on that day, because "
    "they still get access only from their identity policies; the difference comes when the S3 lab applies "
    "this draft, after which any principal not in the list (including a role in another account) is refused "
    "by the bucket itself, and every request has to use TLS.",
]
open("outputs/lab-09-lab10-readiness.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

python3 -m json.tool outputs/lab-09-bucket-policy-draft.json > /dev/null && echo "draft is valid JSON"
