# Lab 1 - Independent Exercises Report  

**Course:** DSO303  
**Lab:** Lab 1 - IAM, Section 9 (Independent Lab Exercises) 
**Student:** Pema Dolker  
**Date:** 20/8/26

The report below is a supplement to the Lab 1 report and contains detailed descriptions of all the
five independent exercises: explanations about the design rationale, exact commands, verification steps
and reflection. The work was done against the same Floci environment set up and verified in the main
lab report.


## Exercise 1 - The QA Identity

### Objective
To create a group `usms-qa` and a user `usms-qa-01` belonging to the group, properly labeled and with
policy `USMSDeveloperBase` (which already exists) attached to the **group**, not to the user.

### Design Reasoning
Use of an existing policy, as opposed to creation of a new one, shows that `USMSDeveloperBase`
was generic enough to apply to another team – for instance, QA engineers, just like developers, need
to be able to read infrastructure and access their test resources.

### Implementation
```bash
aws iam create-group --group-name usms-qa

QA_ARN=$(aws iam create-user \
  --user-name usms-qa-01 \
  --tags Key=Role,Value=QA Key=Project,Value=USMS \
  --query 'User.Arn' \
  --output text)

aws iam add-user-to-group --group-name usms-qa --user-name usms-qa-01

aws iam attach-group-policy \
  --group-name usms-qa \
  --policy-arn arn:aws:iam::000000000000:policy/USMSDeveloperBase
```

### Results
| Check | Command | Result |
|---|---|---|
| User in group | `aws iam get-group --group-name usms-qa` | `usms-qa-01` present |
| Policy on group | `aws iam list-attached-group-policies --group-name usms-qa` | `USMSDeveloperBase` attached |
| Policy NOT on user | `aws iam list-attached-user-policies --user-name usms-qa-01` | Empty (correct) |

![get-group, list-attached-group-policies, and list-attached-user-policies for the usms-qa group and usms-qa-01 user](../../screenshots/ex1-qa-identity.png)

### Reflection
This empty output from the command `list-attached-user-policies` is not an error but rather a
proper one. The practical task showed how important it was to distinguish between the *direct* 
policies that belong to a user and *inherited* policies of the user because only the check of both 
of them provides complete information on the permissions of the user.

## Exercise 2 - The Read-Only Reporting Policy

### Objective
Design and create a new customer managed policy called `USMSReportingReadOnly` which allows access to read-only permissions on all objects under `transcripts/` in the `usms-student-data` bucket but denies all writes and deletions.

### Design Reasoning
While this is the immediate objective of the task, the `ListBucket` statement includes an
`s3:prefix` condition of `StringLike: transcripts/*`. Without this condition, the reporting
identity can *list* all objects in the bucket (even those files far away from the scope of
this identity) while having permission to *read* only the allowed objects. This is an information exposure issue which cannot be identified using the literal approach.


### Implementation
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucketTranscriptsOnly",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::usms-student-data",
      "Condition": { "StringLike": { "s3:prefix": "transcripts/*" } }
    },
    {
      "Sid": "ReadTranscripts",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::usms-student-data/transcripts/*"
    },
    {
      "Sid": "NeverWriteOrDelete",
      "Effect": "Deny",
      "Action": ["s3:Put*", "s3:Delete*"],
      "Resource": [
        "arn:aws:s3:::usms-student-data",
        "arn:aws:s3:::usms-student-data/*"
      ]
    }
  ]
}
```
```bash
aws iam create-policy \
  --policy-name USMSReportingReadOnly \
  --description "Read-only access to transcripts/ prefix in usms-student-data. Denies all writes and deletes." \
  --policy-document file://usms-reporting-readonly-policy.json
```

### Results
The customer managed policy `USMSReportingReadOnly` was successfully created (`AttachmentCount: 0`
at creation, version `v1`, `IsAttachable: True`).

![create-policy output for USMSReportingReadOnly, plus list-policies --scope Local confirming its attributes](../../screenshots/ex2-reporting-policy.png)

### Reflection
This exercise helped to understand the difference between the ARN of bucket vs object in S3 policies discussed in the main lab (Step 23). `s3:ListBucket` should point to the bucket ARN with no `/*` suffix while `s3:GetObject` should target the object ARN with `/*`. Making this mistake twice during the lab helped to understand why the former is mentioned as the most frequent mistake in S3 policies.

## Exercise 3 - The Third-Party Analytics Role

### Objective
Create a role usms-analytics-partner-role that is assumed by the usms-audit-01 identity for up to 30
minutes in each session with the scope of `arn:aws:s

### Design Reasoning and a Real Constraint Encountered
The first attempt set `--max-session-duration 1800` directly on the role, which **failed**:

```
Parameter validation failed:
Invalid value for parameter MaxSessionDuration, value: 1800, valid min value: 3600
```

AWS implements a **minimum value of 1 hour (3600 seconds)** for a session duration ceiling
of a role itself –
`MaxSessionDuration` can’t be set lower than that, even if the real-world usage requires
this lower ceiling. This means: set the role's ceiling to its minimum value allowed (3600
seconds), and enforce the *actual* 30 minutes restriction at the time of assumption, using
`--duration-seconds 1800` option in `sts assume-role`.


### Implementation
```bash
# Trust policy — only usms-audit-01 may assume this role
cat > trust-analytics-partner.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowAuditorToAssume",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::000000000000:user/usms-audit-01" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Permissions policy — read-only, reports/ prefix only
cat > usms-analytics-partner-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadReportsOnly",
    "Effect": "Allow",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::usms-student-data/reports/*"
  }]
}
EOF

aws iam create-role \
  --role-name usms-analytics-partner-role \
  --assume-role-policy-document file://trust-analytics-partner.json \
  --max-session-duration 3600 \
  --tags Key=Project,Value=USMS Key=External,Value=true

# Second half of the handshake: usms-auditors must be permitted to call AssumeRole
aws iam attach-group-policy --group-name usms-auditors \
  --policy-arn <USMSAssumeAnalyticsPartnerRole ARN>

# Enforce the real 30-minute cap at assume time
aws sts assume-role \
  --role-arn <role ARN> \
  --role-session-name analytics-test \
  --duration-seconds 1800 \
  --query 'Credentials.Expiration' --output text
```

### Results
| Check | Result |
|---|---|
| Role's `MaxSessionDuration` | `3600` (the enforced floor) |
| Trust policy principal | `usms-audit-01` |
| Session actually granted | Expiration ≈ 30 minutes after the assume-role call time, confirming the shorter cap was honoured despite the role's own ceiling being 3600 |

![The assume-analytics-role policy, its attachment to usms-auditors, and the assume-role call with duration-seconds 1800 returning an expiration ~30 minutes out](../../screenshots/ex3-analytics-partner-assume-role.png)
*(Please note that the previous validation error regarding the `MaxSessionDuration`, which led to fixing it as 3600, was recorded in the session log instead of a separate screenshot – see the "Design Reasoning and Real Constraint Experienced" section above for the error message.)*

### Reflection: `sts:ExternalId`
This particular exercise had you decide on whether or not an `ExternalId` condition needs to
be set in this particular role's trust policy. The use of `sts:ExternalId` is designed to avoid
the **confused deputy problem**, which occurs in a legitimate cross-*account* trust scenario, where a single third party (like the actual SaaS analytics provider) uses only one single role ARN for all their customers in AWS. Otherwise, the malicious customer can make that third party assume the role of another customer, simply because they provide that particular role's ARN.

In this exercise, the trust policy names a specific **in-account** IAM user
(`usms-audit-01`), not an external AWS account, so `ExternalId` is not strictly necessary
here. If this role were ever opened up to a genuine external AWS account instead, the trust
policy should be extended with:
```json
"Condition": { "StringEquals": { "sts:ExternalId": "<pre-shared-secret>" } }
```
and the partner would be required to pass `--external-id` on every `assume-role` call.



## Exercise 4 - Least-Privilege Design: The Backup Operator

### Objective

Based on the provided job description, design a policy that performs a daily backup job that:
Copies all objects from `usms-student-data` to `usms-archive`, verifies what was copied,
logs its completion, never deletes anything, never reads IAM, and runs only in
`us-east-1` — with a maximum of 4 statements and no wildcard `Action`/`Resource` on any `Allow`.

### Design Reasoning
**1. User, group, or role?**
Role assumed by `lambda.amazonaws.com` — this is an automated unattended job, and a role
implies no permanent access keys need to remain on record (like `usms-ec2-app-role`).

**2. What does "copy" actually require?**
This is where the trick comes in: **there is no `s3:CopyObject` action.** Copying an object
really means 2 actions on 2 separate resources — `s3:GetObject` on the source object, and
`s3:PutObject` on the destination object.

**3. What does "verify" require?**
`s3:GetObject` and (for attributes) `s3:GetObjectAttributes` on the *destination*, so the job
can verify what it wrote.

**4. Logging.**
Same three actions used on `usms-lambda-exec-role`:
`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` — but limited to one
specific log group, not `logs:*`.

**5. "Never read IAM" and region restriction.**
Satisfied by omission (since nothing in the policy grants `iam:*` permission, it will
automatically fall under the implied deny), and an `aws:RequestedRegion` condition on
every statement.

### Implementation
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadSourceBucketObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::usms-student-data/*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "us-east-1" } }
    },
    {
      "Sid": "WriteAndVerifyArchiveBucket",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:GetObjectAttributes"],
      "Resource": "arn:aws:s3:::usms-archive/*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "us-east-1" } }
    },
    {
      "Sid": "WriteCompletionLog",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:000000000000:log-group:/usms/backup-operator:*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "us-east-1" } }
    },
    {
      "Sid": "DenyDeleteAnywhere",
      "Effect": "Deny",
      "Action": "s3:DeleteObject",
      "Resource": [
        "arn:aws:s3:::usms-student-data/*",
        "arn:aws:s3:::usms-archive/*"
      ]
    }
  ]
}
```

Exactly 4 statements. No `Action: "*"` or `Resource: "*"` on any `Allow` statement. The final
`Deny` statement is deliberate **defense-in-depth**: nothing in the first three statements
allows deletion, but a denial makes sure it cannot ever be reintroduced
unconsciously without removing this final statement.

### Results
Role `usms-backup-operator-role` was created (trust: `lambda.amazonaws.com`), and
`USMSBackupOperator` was attached.

**The completed policy document (the logging statement and explicit-deny guardrail):**
![The final two statements of usms-backup-operator-policy.json, including the DenyDeleteAnywhere statement and JSON validation](../../screenshots/ex4-backup-operator-policy-json.png)

**Role creation and attachment:**
![get-role showing the lambda.amazonaws.com trust principal, and list-attached-role-policies confirming USMSBackupOperator is attached](../../screenshots/ex4-backup-operator-role-creation.png)
<!-- 
### Three Ways This Policy Could Still Be Abused

| # | Abuse vector | Fix |
|---|---|---|
| 1 | No object-key restriction on the archive bucket — `PutObject` is allowed on **any** key under `usms-archive/*`, not just a backup-specific prefix. A compromised job could overwrite unrelated archive files. | Scope `Resource` to a specific prefix, e.g. `arn:aws:s3:::usms-archive/nightly/*`, if that is the only path the job legitimately writes to. |
| 2 | No integrity/checksum enforcement — "verify" here only means "can read it back," not "matches a hash." A buggy job could silently write corrupted data and still pass its own check. | This is primarily an application-layer fix (the Lambda code should compare checksums/ETags), though the policy could additionally require server-side encryption headers via a `Condition` as a partial mitigation. |
| 3 | The trust policy allows **any** Lambda function in the account to assume this role, not just the intended backup function. | Add a `Condition` on the trust policy using `aws:SourceArn`, scoped to the specific backup Lambda function's ARN. | -->

### Reflection
This was the hardest exercise, as it was necessary to translate the casual job description
into IAM actions without guesswork, the important point being discovered that `s3:CopyObject`
action does not exist, and "copy" actually is two separate `Allow` statements on two different
resources. The post-factum analysis of possible attack vectors on the policy was very valuable,
as it is easy to consider a policy finished after it satisfies the requirements in technical sense,
and yet the truly least-privilege policy needs to look for additional capabilities of a policy.


## Exercise 5 - Preparing the Developer Identity for Lab 2

### Objective
Determine whether `usms-dev-01` already has all the permissions which Lab 2 (VPC) would need;
if not, grant exactly the required actions as a policy version v3; change
`configs/lab-01.env` file and the verification script accordingly.

### Method
Instead of using only `simulate-principal-policy` command (that, according to the lab
report, incorrectly gave an `implicitDeny` for permissions inherited by group on this
Floci build), the actual v2 policy document was read back and compared line-by-line
with the list of required actions for Lab 2:

```bash
cat usms-developer-base-policy-v2.json | python3 -c "
import json,sys
doc = json.load(sys.stdin)
for st in doc['Statement']:
    if st.get('Sid') == 'BuildNetworkingForLab02':
        print('\n'.join(st['Action']))
"
```

**v2 already contained:** `CreateVpc`, `CreateSubnet`, `CreateRouteTable`, `CreateRoute`,
`CreateInternetGateway`, `AttachInternetGateway`, `AssociateRouteTable`,
`CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`, `CreateTags`, `ModifyVpcAttribute`,
`DeleteVpc`, `DescribeAvailabilityZones` (13 actions).

**Genuinely missing (2 actions):** `ec2:CreateNatGateway` and `ec2:AllocateAddress`. These
two belong together — a NAT gateway cannot be created without first allocating an Elastic IP
address for it, so both permissions were required as a pair, not independently.

### Implementation
```bash
python3 - << 'PY'
import json, pathlib
p = pathlib.Path("usms-developer-base-policy-v2.json")
doc = json.loads(p.read_text())
for st in doc["Statement"]:
    if st.get("Sid") == "BuildNetworkingForLab02":
        st["Action"] += ["ec2:CreateNatGateway", "ec2:AllocateAddress"]
pathlib.Path("usms-developer-base-policy-v3.json").write_text(json.dumps(doc, indent=2))
PY

aws iam create-policy-version \
  --policy-arn arn:aws:iam::000000000000:policy/USMSDeveloperBase \
  --policy-document file://usms-developer-base-policy-v3.json \
  --set-as-default

echo "export USMS_VPC_CIDR=10.0.0.0/16" >> configs/lab-01.env
```

The verification script's hard-coded expectation of `v2` as the default policy version was
also updated to `v3` — per the exercise's explicit instruction that "a verification script
that is never updated is a verification script nobody trusts."

### Results
| Check | Expected | Actual |
|---|---|---|
| `list-policy-versions` | v1 (False), v2 (False), v3 (True) | ✔ Matched exactly |
| No actions added beyond the required 2 | Only `CreateNatGateway` + `AllocateAddress` | ✔ Confirmed by diff against v2 |
| `USMS_VPC_CIDR` present in `configs/lab-01.env` | `10.0.0.0/16` | ✔ Present |
| `verify-lab-01.sh` updated and re-run | `PASS=34 FAIL=0` with the v3 check passing | ✔ Confirmed |

**The "before" state - reading back v2's 13 actions directly, to identify the gap by inspection rather than guessing:**
![Python one-liner printing all 13 actions in v2's BuildNetworkingForLab02 statement](../../screenshots/ex5-v2-before-state.png)

**The version bump — v1/v2/v3, with v3 now the default:**
![list-policy-versions showing v1 (False), v2 (False), v3 (True)](../../screenshots/ex5-policy-versions-v3.png)

**Final verification confirming the updated check passes:**
![verify-lab-01.sh re-run showing "USMSDeveloperBase default version is v3" passing, ending in PASS=34 FAIL=0](../../screenshots/ex5-final-verify-v3-pass.png)

### Reflection

The most important takeaway from this exercise was more about the methodology than
technical part itself: when the official verification utility returned a result different from
manual inspection of the actual policy, it was necessary to trust the primary source of information
(the actual JSON policy) rather than just consider it wrong and/or the verification utility wrong,
without further checks.

---

## Overall Summary

| Exercise | Core skill demonstrated |
|---|---|
| 1 - QA Identity | Reusing an existing policy across teams via group attachment, not duplication |
| 2 - Reporting Policy | Prefix-scoped conditions; closing an information-disclosure gap beyond the literal spec |
| 3 - Analytics Partner Role | Diagnosing and correctly resolving a real AWS parameter-validation constraint (`MaxSessionDuration` floor); reasoning about `sts:ExternalId` |
| 4 - Backup Operator | Translating a job description into precise least-privilege actions; discovering non-existent actions (`s3:CopyObject`); proactive abuse-vector analysis |
| 5 - Lab 2 Prep | Diff-based policy-gap analysis; distrusting an unreliable tool output in favour of direct source verification; maintaining a verification script as living documentation |

All five exercises were completed against the same environment verified in the main Lab 1
report, and the full 34-point verification script continued to pass (`PASS=34 FAIL=0`) after
all exercise work was completed.