# Lab 01 — IAM — completed

## What exists after this lab
- Environment: Floci via docker-compose.yml, FLOCI_STORAGE_MODE=hybrid,
  bind-mounted to ~/floci-data, persistence proven in Step 14
- Groups: usms-admins, usms-developers, usms-auditors
- Users: usms-admin-01, usms-dev-01, usms-audit-01
- Customer managed policies: USMSDeveloperBase (v2), USMSStudentDataReadWrite,
  USMSAssumeAppRoles, USMSLambdaBasic
- Inline policy: USMSSelfManageCredentials on usms-dev-01
- Roles: usms-ec2-app-role, usms-lambda-exec-role, usms-developer-role
- Instance profile: usms-ec2-app-profile

## Reproduce
    source ~/Desktop/Y4S1/DSO303/aws-floci-course/configs/course.env
    ./scripts/setup/floci-up.sh
    source ~/Desktop/Y4S1/DSO303/aws-floci-course/configs/lab-01.env

## Evidence
- [x] whoami.sh output showing account 000000000000
- [x] floci-storage-check.sh output, all [ok]
- [x] Step 14 persistence proof (user survived a restart)

## Floci limitations observed
- GetAccountAuthorizationDetails: not supported on this Floci build
  (UnsupportedOperation error)
- floci snapshot save/list: not available on this server version
  (used tar -czf fallback of ~/floci-data instead)
- simulate-principal-policy: returned implicitDeny for ec2:CreateVpc on
  usms-dev-01 despite the permission being granted via the usms-developers
  group. Likely does not evaluate group-inherited policies the way real
  AWS does. Verified directly via get-policy-version that the group policy
  document is correct.

## Problems I hit and how I fixed them
- Had previously run `floci start` + `eval $(floci env)` in Lab 0, which
  bypasses Compose and doesn't durably persist state. Removed that container
  (`floci stop --remove`) and unset the leftover AWS_* env vars before
  starting fresh with docker-compose.yml.



## Exercise 3 — sts:ExternalId reflection
Should usms-analytics-partner-role use an ExternalId condition?

In this lab, the trust policy names a specific in-account user (usms-audit-01),
so ExternalId isn't strictly needed here -- it's designed for genuine
cross-ACCOUNT trust, where a third party (like a real analytics vendor) is
given one role ARN they reuse across many different customers' AWS accounts.
Without ExternalId, that third party could be tricked (the "confused deputy"
problem) into assuming a role belonging to a different customer than intended.

If this role were later opened up to a real external AWS account (not an
in-account user), I would add:
  "Condition": { "StringEquals": { "sts:ExternalId": "<pre-shared-secret>" } }
to the trust policy, and require the partner to always pass --external-id
when calling assume-role.


## Exercise 4 — USMSBackupOperator design notes

### Why a role, not a user or group
This is an automated nightly job, not a human identity. Modeled as a role
assumed by lambda.amazonaws.com, so there's no permanent access key sitting
in a cron config -- credentials are temporary and auto-rotated (same
reasoning as Step 28's EC2 role).

### Why there's no s3:CopyObject
There is no such action. "Copying" an object is really two separate
permissions on two separate resources: s3:GetObject on the source
(usms-student-data/*) and s3:PutObject on the destination (usms-archive/*).
"Verify what it copied" is handled by also granting s3:GetObject /
s3:GetObjectAttributes on the destination, so the job can read back what
it just wrote.

### 4 statements, no wildcards
1. ReadSourceBucketObjects   -- GetObject on usms-student-data/* only
2. WriteAndVerifyArchiveBucket -- Put/Get on usms-archive/* only
3. WriteCompletionLog        -- scoped to one specific log group, not logs:*
4. DenyDeleteAnywhere        -- explicit deny on DeleteObject, both buckets,
                                 as defense-in-depth even though nothing
                                 above grants delete

"Never read IAM" is satisfied by omission -- nothing in the policy touches
iam:*, so it falls to implicit deny automatically.

### Three ways this policy could still be abused
1. No object-key restriction on the archive bucket -- PutObject is allowed
   on ANY key under usms-archive/*, not just a backup-specific prefix. A
   compromised job could overwrite unrelated archive files.
   Fix: scope Resource to something like usms-archive/nightly/* if that's
   the only path the job ever writes to.

2. No integrity/checksum enforcement. "Verify" here just means "can read
   it back" -- nothing forces an actual hash comparison, so a buggy job
   could silently write corrupted data and still pass its own check.
   Fix: this is really an application-layer concern (the Lambda code
   should compare checksums), but the policy could also require SSE
   headers via a Condition as a partial mitigation.

3. The trust policy allows ANY Lambda function in this account to assume
   this role, not just the intended backup function.
   Fix: add a Condition on the trust policy using aws:SourceArn scoped to
   the specific backup Lambda's function ARN.