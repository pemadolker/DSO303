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
