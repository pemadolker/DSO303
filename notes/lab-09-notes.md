# Lab 09 Notes: Securing USMS with IAM Roles and Security Groups

## Step 1: Environment
- Floci 2.2.0 up, hybrid storage. Sourced seven env files (course, lab-01 to lab-06), all values non-empty.
- Key IDs: app sg sg-6091af79bf17bcc64, alb sg sg-d6a9f362a51555d9e, enrolment sg sg-3d2494c284bd0b183, db sg sg-1ab4cbc60843d3564, web instance i-66fc3b0b10a198919, db instance i-55798b3b720a9eb05.

## Step 2: Security baseline
- The first baseline showed that things from Labs 2 to 6 had quietly changed while Floci was restarted many times during Labs 7 and 8 (Lab 8 only used the EKS cluster, so nothing checked them):
  - usms-web-01 and usms-db-01 were stopped, because Floci stops EC2 instances when it restarts, and the web data volume was detached.
  - the security group references were gone. usms-enrolment-sg had six tcp/80 rules with no source at all, usms-db-sg had three empty tcp/5432 rules and usms-app-sg one empty tcp/22 rule. Floci 2.2.0 drops the "source group" part of a rule on restart and leaves an empty rule behind.
- Repairs before starting the lab: started both instances, reattached the data volume (/dev/sdf, DeleteOnTermination False), and added back tcp/80 on usms-enrolment-sg from usms-alb-sg and tcp/5432 on usms-db-sg from usms-app-sg.
- The empty rules could not be removed. revoke-security-group-ingress returned True both by rule ID and by port, but the rules stayed. An empty rule has no source, so on real AWS it would match no traffic and grant nothing. I left them and treat them as broken rules, not open ones.
- The handout's tail -1 picked up a note line printed after the PASS line in the Lab 5 and 6 scripts, so I grabbed the PASS line directly and saved each script's full output once.
- Some AWS CLI calls crashed (segfault, or "Expecting property name enclosed in double quotes") while the instances were starting, which made some results change between runs. Floci itself was healthy afterwards (10 out of 10 calls worked). My machine is low on free memory, which may be part of it.
- An earlier run also failed the NACL, private subnet and user data checks, but those were the random CLI crashes. A clean run (18:30 UTC, before any Lab 9 change) is the official baseline, saved to outputs/lab-09-pre-verify.txt:
  - lab-02 PASS=32 FAIL=1: db-sg sourced from app-sg. The check only reads the first rule, IpPermissions[0], which is one of the empty rules Floci will not delete, even though the correct group rule is there.
  - lab-03 PASS=34 FAIL=2: db-01 has a Floci address (172.21.x), and USMS_WEB_AMI is None (the golden AMI ID was never captured).
  - lab-04 PASS=38 FAIL=1: enrolment-sg sourced from alb-sg, same IpPermissions[0] reason. Already documented in verify-lab-04.sh itself.
  - lab-05 PASS=49 FAIL=0.
  - lab-06 PASS=39 FAIL=3: the scheduled actions Floci does not support (same as my Lab 6 result).
- Step 18 compares against this file.

## Step 3: What this Floci build supports
**Path: A (full).** Management, reading and simulation all work.
- Supported: list-roles, list-policies, get-role, list-attached-role-policies, get-account-authorization-details, update-assume-role-policy, create-role with a permissions boundary, put-role-permissions-boundary, simulate-principal-policy, accessanalyzer list-analyzers, sts assume-role with a session policy, list-access-keys, get-access-key-last-used, describe-security-group-rules, authorize/revoke-security-group-egress, describe-prefix-lists, describe-network-interfaces, modify-instance-metadata-options and the instance MetadataOptions.
- Not available: get-credential-report.
- The handout's probe first said get-role, list-attached-role-policies and simulate-principal-policy were "not available". That was wrong: in my configs/lab-01.env, USMS_ROLE_EC2, USMS_ROLE_LAMBDA and USMS_ROLE_DEVELOPER hold full role ARNs, not names, so --role-name got an ARN and the simulate ARN was built twice. With the plain name (usms-ec2-app-role) all three worked. I export USMS_ROLE_*_NAME variables (the part after the last /) and use those wherever a name is needed.
- Floci limitation: nothing here is enforced. Floci accepts any credentials and carries no traffic, so every control in this lab is proven by reading its configuration, never by seeing AccessDenied or a timeout.
- Two axes: an API call is decided by IAM and fails with an error naming an action. A packet is decided by routing, security groups and NACLs and fails with a timeout. IAM evaluation order: an explicit Deny anywhere wins, then (SCPs), then the permissions boundary must allow, then a session policy must allow, then an identity or resource policy must allow, otherwise deny. Boundaries and session policies only take away, they never grant.

## Step 4: Inventory every identity
- 10 roles: usms-developer-role, usms-ec2-app-role, usms-lambda-exec-role (Lab 1), usms-analytics-partner-role and usms-backup-operator-role (Lab 1 exercises), usms-ecs-exec-role and usms-ecs-task-role (Lab 4), AWSServiceRoleForEcsApplicationAutoscaling (Lab 6), usms-eks-cluster-role and usms-eks-node-role (Lab 7). The handout example has 5, the rest come from my exercises and Labs 6 and 7.
- 4 users: usms-admin-01, usms-audit-01, usms-qa-01 and usms-dev-01. Only usms-dev-01 has an access key (1).
- 11 customer managed policies. Things to note:
  - USMSStudentDataReadWrite is attached 3 times: usms-ec2-app-role, usms-ecs-task-role and usms-eks-node-role. Step 6 looks at whether all three need write access.
  - USMSReportingReadOnly has 0 attachments, so it is a leftover that nothing uses.
  - USMSDeveloperBase is on version v3 with 4 attachments.
- Inventory saved as outputs/lab-09-identity-inventory.json (valid JSON, 10 roles). Every role shows boundary "-", so no role in the account has a permissions boundary.
- usms-developer-role has 0 policies attached, so assuming it gives no permissions at all. usms-eks-node-role has 2 (its own node policy and USMSStudentDataReadWrite).

### Your turn: two trust policies
- usms-developer-role trusts an AWS identity: Principal AWS arn:aws:iam::000000000000:user/usms-dev-01. Only that one IAM user, using its own credentials, can call sts:AssumeRole to get this role's credentials.
- usms-ec2-app-role trusts a service: Principal Service ec2.amazonaws.com. Any EC2 instance that is launched with this role's instance profile gets its credentials from the metadata service, so the real question becomes who is allowed to launch an instance with it (iam:PassRole), and there is no condition limiting which account or instance the request comes from.

## Step 5: IAM audit script
- scripts/utilities/usms-iam-audit.sh reads the Step 4 inventory and checks every role for four things: a wildcard action ("*" or "service:*"), Resource "*" on a changing action, iam:PassRole with no resource scope, and a service principal in the trust policy with no Condition (confused deputy). It changes nothing and exits 1 if there is any HIGH finding.
- Result: HIGH=8 MED=21 roles=10, exit code 1. Saved to outputs/lab-09-iam-findings.txt.
- The 8 HIGH findings are all the same shape, a service principal with no Condition: usms-lambda-exec-role and usms-backup-operator-role (lambda), usms-eks-cluster-role (eks), usms-ecs-exec-role and usms-ecs-task-role (ecs-tasks), usms-ec2-app-role and usms-eks-node-role (ec2), and the Lab 6 service-linked role (ecs.application-autoscaling). One convention repeated on every service role, not eight separate mistakes. Step 7 fixes usms-ecs-task-role, Exercise 2 deals with more. The service-linked role is managed by AWS and I would not edit its trust policy myself.
- 10 of the MED findings are "no permissions boundary", one per role. No role has a boundary yet.
- The other 11 MED findings are in the two EKS policies from Lab 7: ec2:Create/Delete/Attach/DetachNetworkInterface, ec2:CreateTags and elasticloadbalancing:Create* on Resource "*". EKS really does need to create network interfaces and load balancers it cannot name in advance, so these are expected, but they would normally be narrowed with conditions such as a required tag.
- No wildcard actions and no unscoped iam:PassRole on any role.
- usms-analytics-partner-role and usms-developer-role only have the boundary finding. Their trust policies name AWS identities, not services.
- The script's is_mutating check only looks at verb prefixes, so it misses things like sts:AssumeRole. It is a heuristic and says so.

## Step 6: The transcripts policy
- USMSStudentDataReadWrite, default version v1, has three statements:
  - Allow s3:ListBucket and s3:GetBucketLocation on arn:aws:s3:::usms-student-data (bucket ARN)
  - Allow s3:GetObject, s3:PutObject and s3:DeleteObject on arn:aws:s3:::usms-student-data/* (object ARN)
  - Deny s3:DeleteBucket on the bucket. An explicit Deny wins over everything, so no role can delete the bucket.
- Lab 1 got the two ARNs right: bucket actions (ListBucket) take the bucket ARN, object actions take bucket/*.
- Carried by three roles: usms-ec2-app-role, usms-ecs-task-role and usms-eks-node-role (the handout example only has the first two).
- The bucket does not exist yet: head-bucket returned "An error occurred (404) ... Not Found". Lab 10 creates it. An IAM policy is a statement about ARNs, so it can be reviewed before the resource exists.
- The exit code line was empty because my shell is zsh, where the pipe status array is $pipestatus[1], not ${PIPESTATUS[0]}. The 404 already shows it failed.
- Floci limitation: I cannot show the difference between a read-only and a read-write policy, because Floci allows every call. On real AWS a PutObject under a read-only policy would fail with AccessDenied. Reading the policy is the proof.

### Your turn: what each workload needs
- Enrolment API, to display a student's transcript: s3:GetObject, plus s3:ListBucket. ListBucket is needed because without it, S3 answers a missing key with 403 AccessDenied instead of 404 NoSuchKey, so the app could not tell "no transcript yet" from "not allowed".
- Registry upload workflow, to store a transcript: s3:GetObject, s3:ListBucket and s3:PutObject.
- The single action in the second list and not the first is s3:PutObject.
- My policy also grants s3:DeleteObject, which neither workload needs at all, and s3:GetBucketLocation, which only some SDKs call. So the over-grant on the read side is two verbs, PutObject and DeleteObject.

## Step 7: Read-only policy and the reader role
- The confused deputy: a trust policy that names a service principal (like ecs-tasks.amazonaws.com) lets that service assume the role for anyone who asks it, including another account. The fix is a Condition that pins the request to my account (aws:SourceAccount) and to my resources (aws:SourceArn). ec2.amazonaws.com does not send aws:SourceArn for instance profiles, so usms-ec2-app-role cannot be fixed this way (Exercise 2). A condition on a key the service never sends would block everything.
- policies/usms-student-data-ro-policy.json: Allow s3:ListBucket on the bucket, Allow s3:GetObject on bucket/*, and an explicit Deny on PutObject, DeleteObject, DeleteBucket and PutBucketPolicy on both ARNs. The Deny adds nothing today because nothing is allowed to write anyway, but it still wins if someone later attaches a broader policy to the same role. Valid JSON, 0 dollar signs.
- Created USMSStudentDataReadOnly. I changed the handout's tag Lab=05 to Lab=09.
- policies/trust-ecs-tasks-scoped.json (unquoted heredoc so the account and region were filled in): ecs-tasks.amazonaws.com with StringEquals aws:SourceAccount 000000000000 and ArnLike aws:SourceArn arn:aws:ecs:us-east-1:000000000000:*. Valid JSON, 0 dollar signs.
- Created usms-transcripts-reader-role with that trust, max session 3600, and attached USMSStudentDataReadOnly. The first attach failed with "Invalid length for parameter PolicyArn, value: 0" because the RO_POLICY_ARN variable was empty in that terminal. I looked the ARN up with list-policies and attached it.
- Rewrote the trust policy on usms-ecs-task-role (update-assume-role-policy replaces the whole document). Saved the old one first as outputs/lab-09-ecs-task-role-trust-before.json, so the undo is a file. Old: ecs-tasks.amazonaws.com, no Condition.
- Check: before [ecs-tasks, no condition], after [ecs-tasks, condition]: "SAME PRINCIPAL, NEW CONDITION". Who may assume the role did not change, only the circumstances.
- usms-ecs-task-role still has USMSStudentDataReadWrite, so Lab 10 is not affected. The fix was added next to the old setup, not instead of it.
- Floci limitation: Floci never checks trust conditions, so a wrong condition would make no difference here but would make the role unassumable on real AWS. That is why I read the document back instead of trusting the empty output of the update.

## Step 8: Scoped iam:PassRole and a permissions boundary
- iam:PassRole controls handing a role to a service. Unscoped it is an escalation path: someone with ec2:RunInstances and iam:PassRole on "*" can launch an instance with any admin role that trusts ec2.amazonaws.com, read the credentials from the metadata service, and become an admin. Every step is a normal API call.
- A permissions boundary is a second slot on a role that grants nothing. The effective permissions are the overlap of the identity policy and the boundary. Example: identity s3:*, ec2:*, iam:* with boundary s3:*, ec2:* gives s3:* and ec2:*. Identity s3:GetObject with the same boundary gives only s3:GetObject, the boundary added nothing.
- policies/usms-permissions-boundary.json (USMSPermissionsBoundary):
  - Allow (the ceiling): ec2:Describe*, ec2:CreateTags, ecs:*, elasticloadbalancing:*, application-autoscaling:*, logs:*, cloudwatch:*, s3:Get*, s3:List*, s3:PutObject, iam:PassRole, iam:Get*, iam:List*, sts:GetCallerIdentity, on "*". Resource "*" is fine for a ceiling because it grants nothing by itself.
  - Deny every way of changing who can do what (CreateUser, CreateAccessKey, Attach/PutUserPolicy, Attach/PutRolePolicy, DeleteRolePermissionsBoundary, UpdateAssumeRolePolicy, CreatePolicyVersion, SetDefaultPolicyVersion, organizations:*, account:*). So even if someone attaches an admin policy, the role cannot escalate or remove its own ceiling.
  - Deny deleting the VPC, subnets, internet gateway or NAT gateway.
- The boundary is attached to nothing as a normal policy (list-entities-for-policy returned empty lists). That is correct, but it looks like an orphan, so someone tidying up might delete the one control that caps the pipeline.
- policies/usms-deploy-policy.json (USMSDeployBase):
  - Allow the ECS deploy actions (register/deregister task definition, update/describe service, list/describe tasks) and some Describe and log reads on "*". ecs:UpdateService on "*" is a real MED finding (Exercise 2).
  - Allow iam:PassRole only on usms-ecs-exec-role, usms-ecs-task-role and usms-transcripts-reader-role, only when iam:PassedToService is ecs-tasks.amazonaws.com.
  - Deny iam:PassRole on "*" when iam:PassedToService is ec2.amazonaws.com. This still wins if someone later adds a broad Allow. Without the PassedToService condition, the task role could be passed to EC2 and an instance could write transcripts.
- policies/trust-deploy.json: only arn:aws:iam::000000000000:user/usms-admin-01 can assume it. A user in my own account is not a confused deputy risk. Hardening it would mean requiring MFA.
- usms-deploy-role created with --permissions-boundary USMSPermissionsBoundary, max session 3600, USMSDeployBase attached. Boundary read back as arn:aws:iam::000000000000:policy/USMSPermissionsBoundary, so this build stores boundaries.
- This is the first identity in the course that is not root. The escalation path above is now closed at its first step (no unscoped PassRole) and its third (nothing can be passed to EC2).
- I changed every Lab=05 tag in the handout to Lab=09.

## Step 9: Session policy and the intersection
- Three mechanisms: an identity policy grants and stays until detached; a permissions boundary only caps, and stays until removed; a session policy only caps, and is set by the caller on one sts:AssumeRole call for that session only. Effective = identity AND boundary AND session.
- outputs/lab-09-session-policy.json allows only ec2:DescribeVpcs, ec2:DescribeSubnets, ec2:DescribeSecurityGroups and sts:GetCallerIdentity. It lives in outputs/ because it is an argument to one call, not part of the account's setup.
- USMS_ROLE_DEVELOPER is already a full ARN in my lab-01.env, so I passed it directly (the handout builds role/$USMS_ROLE_DEVELOPER, which would give role/arn:aws:...).
- assume-role with --policy, 900 seconds, as the usms-dev profile: got assumed-role/usms-developer-role/lab09-scoped-review, and describe-vpcs returned 2. Afterwards I unset the three variables, whoami showed root again, and the session file was deleted.
- First calculation said everything was denied, because the Step 4 inventory showed usms-developer-role with no policies. The simulator disagreed (DescribeVpcs allowed, iam:CreateUser explicitDeny). list-attached-role-policies showed USMSDeveloperBase IS attached, so the inventory had missed it: an AWS CLI call crashed while it was being built and the script quietly recorded nothing. I rebuilt the inventory with each call retried up to 3 times, and re-ran the audit.
- After the rebuild the identity policy allows ec2:Describe* and a set of ec2 create actions, iam:Get*, iam:List*, logs and cloudwatch reads, s3:List*, s3:GetBucketLocation and sts:GetCallerIdentity, and explicitly denies aws-portal:*, iam:CreateUser, iam:CreateAccessKey, iam:AttachUserPolicy, iam:DeleteUser, iam:PutUserPolicy, organizations:* and more.
- All four session actions came out ALLOWED, because USMSDeveloperBase already has every one of them. The handout's suggested swap s3:ListAllMyBuckets would also be allowed (my policy has s3:List*), so to show the cap I tested two more actions:
  - ec2:DescribeVpcs: reading ALLOWED, simulator allowed
  - ec2:RunInstances: reading "NOT in the identity policy -> denied", simulator implicitDeny
  - iam:CreateUser: reading "denied by an explicit Deny", simulator explicitDeny
- So the session policy can ask for RunInstances but cannot grant it, because the role never had it. A session policy only takes away.
- Lesson: I used both methods, reading the documents (Python) and simulate-principal-policy, and they only agreed after the inventory was fixed. Checking one against the other is what caught the missing policy.
- Floci limitation: the session credentials are returned but the session policy is not enforced on real calls (describe-vpcs worked). The simulator is a second opinion, not enforcement.

### Audit after Steps 7 to 9
- Rebuilt inventory (12 roles: the 10 from Step 4 plus usms-transcripts-reader-role and usms-deploy-role). Audit now: HIGH=7 MED=35 (was HIGH=8 MED=21 in Step 5).
- HIGH 8 to 7: usms-ecs-task-role no longer has the confused deputy finding, because Step 7 added the SourceAccount and SourceArn conditions. The new reader role has the same scoped trust, so no HIGH either.
- MED went up mainly because the first inventory had missed USMSDeveloperBase on usms-developer-role. Now its ec2:CreateVpc, CreateSubnet, CreateRouteTable and similar on Resource "*" show up. usms-deploy-role adds one: ecs:UpdateService on "*".
- Handout bug: the inventory read the permissions boundary from list-roles, but list-roles never returns PermissionsBoundary (on real AWS too), only get-role does. So the audit said usms-deploy-role had no boundary even though Step 8 showed it. I filled the boundary in from get-role for every role. Now usms-deploy-role shows arn:aws:iam::000000000000:policy/USMSPermissionsBoundary and MED dropped by one (36 to 35). It is the only role with a boundary.

## Step 10: Access key rotation with no gap
- usms-dev-01's key from Lab 1 was the one long-lived credential in the account. Order used: create a second key, move the consumer, deactivate the old key, then delete it. Deactivating is the safety step, because a deactivated key can be turned back on, a deleted one is gone forever.
- Part 1: exactly one key, AKIAZWU15IHB83N9C49L, Active, created 2026-08-20. get-access-key-last-used returned N/A, which is normal on Floci and not a finding.
- Part 2: created the new key straight into outputs/usms-dev-01-access-key-new.json with chmod 600, so the secret never appeared on screen or in a screenshot. git check-ignore printed ".gitignore:7:outputs/*". New key AKIA51H1I07MDWCCR2JM, old key AKIAZWU15IHB83N9C49L.
- Part 3: pointed the usms-dev profile at the new key. get-caller-identity still said user/usms-dev-01 and the profile's configured key was AKIA51H1I07MDWCCR2JM.
- Part 4: set the old key Inactive. Two keys (old Inactive, new Active) and the profile still answered. On a real system I would wait a day or a week here and watch for anything failing. The lab skips that wait.
- Part 5: deleted the old key. One key left, AKIA51H1I07MDWCCR2JM, Active, created 2026-10-23. Only the new key file is left in outputs.
- Floci limitation: Floci accepts any credentials, so the profile answering does not prove the new key is valid. On real AWS it would. Here the proof is the key list and the profile's configured key ID.
- What would make the key unnecessary on real AWS: people would sign in through IAM Identity Center (or another identity provider) and get short-lived credentials, and workloads would use roles. The course keeps one key only because Lab 2's assume-role demo needs a named user.

## Step 11: IMDSv2
- The attack: an SSRF bug lets an attacker make the application fetch a URL they choose, but they usually cannot choose the method or headers. With IMDSv1, a plain GET to http://169.254.169.254/latest/meta-data/iam/security-credentials/ returns the role's credentials. With IMDSv2 a token is needed first, and getting one needs a PUT with a header, which the SSRF bug cannot do.
- The hop limit is a different defence: hop limit 1 stops the metadata reply from leaving the instance, so a container running on it (one hop away) cannot get the host's role credentials.
- usms-web-01 before: HttpTokens optional (IMDSv1 allowed), hop limit 1, endpoint enabled.
- modify-instance-metadata-options --http-tokens required --http-endpoint enabled --http-put-response-hop-limit 1. After: HttpTokens required, hop limit 1, endpoint enabled. Check printed "IMDSv2 REQUIRED, HOP LIMIT 1". The endpoint stays enabled because web-01 has an instance profile and gets its credentials from the metadata service (Lab 3 Step 11).
- Safe rollout on real AWS: watch the MetadataNoToken CloudWatch metric until it is zero (nothing still uses IMDSv1), then require tokens. Otherwise old SDKs break.
- My first attempt at this step failed on every call with "Inconsistency detected by ld.so ... elf_machine_rela_relative: Assertion failed", which means Linux could not even load the aws program. Together with the earlier segfaults this was my laptop (it had been running with under 1 GB of memory free for a long time). After a restart every call worked. Nothing had been changed by the failed attempt.
- Floci limitation: Floci stores the setting but serves no metadata service to instances, so there is nothing to enforce it on. Real AWS enforces it at the hypervisor as soon as the call returns.

### Your turn: usms-db-01
- usms-db-01 has no instance profile (IamInstanceProfile is None), so there are no credentials on it for anyone to steal.
- So I turned the metadata service off completely: --http-endpoint disabled (and tokens required). After: HttpEndpoint disabled, HttpTokens required. An instance with no role has no reason to talk to the metadata service at all.
- If I did the same to usms-web-01, it would lose its role credentials, because its instance profile credentials come from the metadata service. The app could no longer call S3 or anything else with the role.

## Step 12: Security group audit script
- Four questions for each group: who can reach me (ingress), what can I reach (egress, the rule nobody writes), is the source a group or an address (a group reference survives IP changes), and is the group attached to anything.
- Security groups are stateful, so limiting egress does not break the replies to allowed inbound connections. Egress rules only limit what the instance or task starts itself.
- scripts/utilities/usms-sg-audit.sh is the handout script with one addition marked # FIX: ingress rules with no source at all (left behind when Floci drops a group reference) are reported as LOW "grant nothing", instead of being printed with no finding. On real AWS a rule with no source matches no traffic.
- Result: HIGH=4 MED=11 LOW=9 groups=9 (the handout example has 5 groups; I also have the bastion, exam, and two EKS groups). Saved to outputs/lab-09-sg-findings-before.txt.
- Findings and my verdicts:
  - usms-alb-sg tcp/80 and tcp/443 from 0.0.0.0/0 (2 HIGH): accepted risk. It is the internet-facing load balancer from Lab 5.
  - usms-app-sg tcp/80 and tcp/443 from 0.0.0.0/0 (2 HIGH): open finding. usms-web-01 is a second internet entry point that existed before the load balancer. Exercise 4 asks if it should still exist.
  - Default allow-all egress on all 9 groups (MED): fix for enrolment, alb and db in Steps 13 to 15, app in Exercise 1.
  - usms-eks-cluster-sg tcp/443 from 10.0.0.0/16 (MED): the EKS API reachable from anywhere in the VPC. Acceptable for this course, would be narrowed to the node group's security group on real AWS.
  - usms-db-sg tcp/5432 from usms-exam-sg: a second path to the database that the handout does not expect. usms-exam-sg (from an earlier exercise) admits tcp/443 from 10.10.0.0/16. It is attached to nothing today, but anything put in that group could reach the database. Step 17 has to count it.
  - usms-exam-sg tcp/443 from 10.10.0.0/16 (MED): a whole other network range.
  - Empty-source rules: 3 on usms-enrolment-sg, 1 on usms-db-sg, 1 on usms-exam-sg (LOW). Fewer than in Step 2 (6 and 3), so some of the revokes I tried in Step 2 seem to have applied after Floci restarted, even though they did not show at the time.
  - usms-app-sg no longer has any tcp/22 rule. In Step 2 it had tcp/22 from 10.0.0.0/16 and an empty tcp/22. Both are gone after the restart, most likely because my Step 2 revoke by port (tcp 22, no source) removed every tcp/22 rule once it was saved. So SSH to the web instance is currently closed to everyone. Step 16 adds the bastion rule.
  - usms-bastion-sg tcp/22 from 203.0.113.10/32 (one address, from Lab 2 Exercise 2): fine.
  - default and several groups attached to no interface (LOW): accepted, the default group exists in every VPC.
- usms-enrolment-sg shows 18 network interfaces: leftovers from ECS tasks Floci started and replaced over many restarts.
- An audit tool gives findings, not verdicts. It cannot tell that one 0.0.0.0/0 (the ALB) is fine and another (the web instance) is a problem. That part is reading.

## Step 13: Written egress for the enrolment tasks
- What the enrolment tasks must start themselves: pull the container image (tcp/443), send logs with the awslogs driver (tcp/443), and read transcripts from S3 in Lab 10 (tcp/443 through the Lab 2 gateway endpoint). Nothing else, so not the database, not the web instance, and nothing on any other port.
- S3 prefix list found with describe-prefix-lists: pl-63a5400a (com.amazonaws.us-east-1.s3).
- policies/usms-enrolment-sg-egress.json: tcp/443 to pl-63a5400a (S3, stays inside the AWS network) and tcp/443 to 0.0.0.0/0 (image pull and logs, would be narrowed to interface endpoints on real AWS). Every rule has a Description. Valid JSON, 0 dollar signs.
- 443 to anywhere is still wide, but it blocks DNS exfiltration, SSH, database protocols, mail and command-and-control on other ports.
- policies/usms-egress-allow-all.json is the default rule (all protocols to 0.0.0.0/0) written down BEFORE removing it, so putting it back is one command.
- Order: authorise the new rules first (got sgr-9c4a805b694d1d0c6 and sgr-2705d36456ce7bd82), then revoke the default, so there is never a moment when the tasks cannot pull images or send logs.
- Floci problem: revoke-security-group-egress returned True, but the -1 allow-all rule was still listed afterwards. I tried again by its rule ID (sgr-85c72150294381d1b), also True, still listed. My first ID attempt matched nothing because I wrote the protocol as a number in the query instead of the text "-1".
- In Step 12 some revokes from Step 2 only showed up after Floci restarted, so it looks like this build saves the revoke but does not show it until a restart. The Step 18 restart will show whether the -1 rule is really gone.
- On real AWS the revoke takes effect immediately.
- Test after Floci restart (floci-down, floci-up): the -1 allow-all egress rule was STILL there. On usms-enrolment-sg, revoke-security-group-egress returned True but the rule stayed, even after a restart. Tried three ways: by permission shape, by rule ID, and across a restart. The same revoke DID work on usms-alb-sg in Step 14, so it is not that revokes never work on this build; something about this one group is different.
- The same restart also brought back 6 empty-source ingress rules on usms-enrolment-sg (after my laptop restart there were only 3), so Floci's saved security group data is not even consistent between restarts. What I thought in Step 12 were delayed revokes was this inconsistency.
- Adding rules does work and survives a restart: both new tcp/443 egress rules and the tcp/80 ingress from usms-alb-sg were still there.
- So on Floci I can write and add the correct rules, but not remove the default allow-all. The intended posture is in the policies/ documents, and on real AWS the revoke would take effect straight away. This is recorded as a Floci limitation.
- CORRECTION, found in Step 15: the revoke on usms-enrolment-sg DID work. describe-security-groups shows only the two tcp/443 egress rules, no -1 rule. The -1 rule only still appeared in describe-security-group-rules. On this Floci build that second listing is not updated when a rule is removed, so it keeps showing rules that are already gone (this is also where the "empty source" ghost rules come from). describe-security-groups is the one that reflects the real state, and it is what my audit script reads. So revokes work, one listing is stale.

## Step 14: Load balancer egress to a security group
- A load balancer should only ever connect to its targets, and their addresses change with every deployment and scaling event. So the rule names usms-enrolment-sg instead of addresses.
- policies/usms-alb-sg-egress.json: tcp/80 to usms-enrolment-sg (sg-3d2494c284bd0b183). Authorised (sgr-94459abfa9c22ed58), then revoked the default allow-all.
- Result: In = tcp/80 and tcp/443 from 0.0.0.0/0. Out = only tcp/80 to sg-3d2494c284bd0b183, CIDR null. Anything may open HTTP to the load balancer, and it may open HTTP to exactly one thing.
- Lab 6 scaling changes how many targets there are, not what the load balancer may reach, because the rule names a group.

## Step 15: Database egress
- policies/usms-db-sg-egress.json: tcp/443 to 0.0.0.0/0 only, for OS updates through the NAT gateway. Authorised (sgr-7ca601b0d7c1e4a4b), then revoked the default.
- Now denied from the database: DNS, SSH out, database connections out, SMTP and HTTP on 80. But 443 to anywhere still allows an HTTPS POST of the data to any site. Stopping that needs hostname filtering (AWS Network Firewall or a proxy).
- What this breaks on real AWS: dnf update needs DNS (Amazon resolver at 10.0.0.2), now blocked. The full rule set would add UDP and TCP 53 to 10.0.0.0/16 (Exercise 1).
- The handout's final check was missing SecurityGroups[0]. and wrote -1 as a number, so it errored. Fixed version used.

## Step 16: SSH only from the bastion group
- Lab 2 allowed tcp/22 to usms-app-sg from 10.0.0.0/16, so anything in the VPC, including every Fargate task, could reach SSH on the web instance. The fix is a rule sourced from usms-bastion-sg instead. No jump host is created; the group names a role in the design.
- Found the existing usms-bastion-sg from Lab 2 Exercise 2: sg-7907e03e35e024edb (it admits tcp/22 only from 203.0.113.10/32). The handout's lookup query (GroupId | [0]) would have returned None and created a duplicate group, so I used SecurityGroups[0].GroupId.
- policies/usms-app-sg-ssh-bastion.json: tcp/22 from sg-7907e03e35e024edb. Valid JSON, 0 dollar signs. Added as sgr-97fa0e96d1e90f409.
- The old 10.0.0.0/16 SSH rule was already gone (it disappeared after the Floci restart, see Step 12), so there was nothing to remove.
- usms-app-sg ingress now: tcp/80 from 0.0.0.0/0, tcp/443 from 0.0.0.0/0, tcp/22 from usms-bastion-sg only. A compromised enrolment task can no longer reach SSH on the web instance.

## Step 17: Reachability matrix and the two negatives
- scripts/utilities/usms-reachability-matrix.sh works out, from the rules only (never names or tags), who may open a connection to each group, what each group may start, and whether each instance has an address the internet could send to. Saved to outputs/lab-09-reachability.txt.
- Who may reach what:
  - The internet reaches usms-alb-sg (tcp/80, tcp/443) and usms-app-sg (tcp/80, tcp/443). The load balancer was argued for in Lab 5. The web instance never was, it is a second internet entry point (Exercise 4).
  - usms-app-sg tcp/22 only from usms-bastion-sg (Step 16). usms-bastion-sg tcp/22 only from 203.0.113.10/32.
  - usms-enrolment-sg only from usms-alb-sg (tcp/80).
  - usms-db-sg tcp/5432 from usms-app-sg AND from usms-exam-sg. The second path is extra and the handout does not expect it.
  - usms-exam-sg tcp/443 from 10.10.0.0/16, and usms-eks-cluster-sg tcp/443 from 10.0.0.0/16.
- What each group may start: usms-alb-sg only tcp/80 to usms-enrolment-sg; usms-enrolment-sg only tcp/443 (S3 prefix list and anywhere); usms-db-sg only tcp/443. usms-app-sg, usms-bastion-sg, usms-exam-sg, usms-eks-cluster-sg and default still have the default allow-all (app is Exercise 1; a jump host's job is to start SSH).
- Single point of control (protected by exactly one ingress rule): eks-cluster-sg-usms-eks-cluster-28280b01, usms-bastion-sg, usms-eks-cluster-sg, usms-enrolment-sg and usms-exam-sg. One mistake in that one rule is the whole of the protection. For usms-enrolment-sg the private subnet and no public address are more controls, but this tool only looks at security groups, so it understates the other layers.
- Instances: usms-web-01 private 172.21.0.7, "public" 127.0.0.1; usms-db-01 private 172.21.0.8, "public" 172.21.0.8. These are Floci's Docker network addresses, not real VPC addresses.

### Proving usms-db-01 is not reachable from the internet (outputs/lab-09-negative-proof.txt)
A negative cannot be tested directly, so I listed the separate controls that would ALL have to fail. db-01 is in subnet-5b834146 (the env file's private subnet A, I looked it up from the instance itself).
- Control 1, no public address: 172.21.0.8. FAILED on Floci, because Floci gives every running instance an address from its Docker network. On real AWS this would be None. A Floci limitation, not a design problem.
- Control 2, subnet does not auto-assign public IPs: False. Holds.
- Control 3, no internet gateway route: the 0.0.0.0/0 route goes to nat-dbd644227de3d04f4, with no igw. Holds. This is the most important one, because without it the subnet would be public.
- Control 4, security group admits groups only, no CIDR: tcp/5432 from sg-6091af79bf17bcc64 (usms-app-sg) and sg-f1f42d3ac3f25b1a0 (usms-exam-sg), plus one empty-source rule that grants nothing. Holds for "no CIDR", but there are two groups, not one.
- Control 5, custom network ACL: acl-b2c9cabb8ce8ab2aa, IsDefault False. Holds.
- The claim still holds even with control 1 failing on Floci. That is defence in depth: no single control is carrying it alone.

### Your turn
- If control 3 failed (the subnet got a route to an internet gateway): the security group would still only admit tcp/5432 from the app and exam groups, and the NACL would still apply, so nothing on the internet could open a database connection. On real AWS the instance would also still have no public address to send to.
- If control 4 failed (someone opened tcp/5432 to 0.0.0.0/0): the instance has no route to an internet gateway, so a reply could never get back out, and on real AWS it has no public address for anyone to reach in the first place.

## Step 18: Persistence and regression
- Part 1: recorded 11 facts before a restart (outputs/lab-09-pre-restart.txt): the task role trust has 2 condition keys, usms-deploy-role has the USMSPermissionsBoundary boundary, usms-transcripts-reader-role exists with USMSStudentDataReadOnly, usms-dev-01 has 1 access key, 0 allow-all egress rules on usms-alb-sg, usms-enrolment-sg and usms-db-sg, usms-alb-sg egress goes to sg-3d2494c284bd0b183 (usms-enrolment-sg), 0 CIDR sources for SSH on usms-app-sg, SSH comes from sg-7907e03e35e024edb (usms-bastion-sg), and web-01 HttpTokens required.
- I added the last two group-reference checks to the handout's nine, because on this Floci build group references are exactly what had gone missing after restarts before.
- I also fixed the handout's queries: they were missing SecurityGroups[0]. and wrote -1 as a number, same bug as Step 15.
- Part 2: floci-down.sh (docker compose stop, keeps the data, not down -v) and floci-up.sh, then sourced the env files again.
- Part 3: re-found every ID from the API by name instead of reusing the old variables, otherwise the test would only prove that the shell remembers strings. All five came back the same (sg-d6a9f362a51555d9e, sg-3d2494c284bd0b183, sg-1ab4cbc60843d3564, sg-6091af79bf17bcc64, i-66fc3b0b10a198919). The handout finds most groups by tag:Name, but I used group-name, because not every group has a Name tag.
- Result: "PERSISTENCE PROVEN", all 11 facts identical. A control that disappears after a restart is worse than no control, because the audit already said it was there.
- Part 4: the restart stopped both instances again (Floci does this every time), so I started them before running the earlier verify scripts. Lab 2 to 6 results: lab-02 32/1, lab-03 34/2, lab-04 38/1, lab-05 49/0, lab-06 39/3, the same failures as the Step 2 baseline. diff printed "NOTHING BROKE: all five verification scripts report exactly what they reported before this lab".
- Why this matters: Lab 9 changed a lot about who can do what (trust policies, egress, SSH, IMDS), but none of the things Labs 2 to 6 check changed. The system's permissions changed, and what it does did not. NOTHING BROKE does not prove my changes are correct, that is what Section 8's verify script is for.

## Step 19: configs/lab-09.env
- 16 exports, every value looked up live, so a filled value is evidence the resource exists. "all values populated".
- Values: USMSStudentDataReadOnly, USMSDeployBase and USMSPermissionsBoundary ARNs, usms-transcripts-reader-role and usms-deploy-role ARNs, bastion sg-7907e03e35e024edb, S3 prefix list pl-63a5400a, IMDS tokens required, dev key created 2026-10-23T18:57:41, allow-all egress left 0, review date 2026-10-24.
- The access key ID is deliberately NOT in the file. A key ID is not a secret, but writing one into a committed file is how a habit becomes a leak. The rotation date is recorded instead.
- I worked out the allow-all count and the prefix list before writing the file, instead of the handout's escaped mini-program inside the heredoc, because the handout's query had the same missing SecurityGroups[0]. and -1-as-a-number bug as Step 15.

## Section 8: Verification and cleanup
- scripts/utilities/verify-lab-09.sh: the handout script with these fixes, each marked # FIX:
  - allowall() and the two "egress is tcp/443 only" checks and the "no CIDR on tcp/22" check were missing SecurityGroups[0]. and wrote -1 as a number, so they could never count anything.
  - USMS_ECS_TASK_ROLE can be a full ARN in my env files, so the script strips it to the role name.
  - "the boundary is attached to NOTHING": the handout nested escaped quotes three deep, so the quotes ended up inside the query and it failed even though the boundary really has 0 attachments. Replaced with list-entities-for-policy counting the joined roles, users and groups lists. My own first fix used + inside the query, which JMESPath does not support, so I changed it to length([PolicyRoles, PolicyUsers, PolicyGroups][]).
  - "no unexpanded variable" now only flags uppercase shell variables like ${USMS_ACCOUNT_ID}, so Lab 1's IAM policy variable ${aws:username}, which is meant to stay, is not counted.
  - "no secret tracked by git" ignores outputs/.gitkeep (same bug as Labs 6 to 8).
- Result: PASS=49 FAIL=1. The one failure is "usms-db-01 has NO public address", because Floci gives every running instance an address from its Docker network (172.21.0.8). Same reason as Lab 3's verify and Step 17's control 1. On real AWS the private subnet instance would have no public address. The other two negatives (no auto-assign, no internet gateway route) pass.
- scripts/cleanup/lab-09-cleanup.sh: written and syntax checked, NOT run. It needs "UNDO USMS SECURITY REVIEW" typed in full. Order: detach policies from the two Lab 9 roles, remove the boundary, delete the roles, delete non-default policy versions then the policies, put back allow-all egress on the three groups and the 10.0.0.0/16 SSH rule, then delete usms-bastion-sg. It deliberately does not undo the key rotation or IMDSv2, because a teardown should never leave the account less secure. It runs first, before lab-06-cleanup.sh.

## Exercise 1: Egress for the web tier
- policies/usms-app-sg-egress.json, unquoted heredoc because the S3 prefix list and two group IDs had to be filled in when the file was written (pl-63a5400a, usms-alb-sg sg-d6a9f362a51555d9e, usms-db-sg sg-1ab4cbc60843d3564). Valid JSON, 0 dollar signs, every rule has a Description.
- Six rules, one per thing the web instance must start:
  - tcp/443 to pl-63a5400a: S3 through the Lab 2 gateway endpoint for Lab 10's transcripts.
  - tcp/443 to 0.0.0.0/0: AWS service endpoints, including STS for the instance profile credentials.
  - tcp/80 to usms-alb-sg: the enrolment API. Since Lab 5 that means the load balancer, not the tasks, so it is a group reference to the ALB's group.
  - tcp/5432 to usms-db-sg: PostgreSQL to the data tier, also a group reference.
  - udp/53 and tcp/53 to 10.0.0.2/32: DNS. The Amazon resolver is the VPC's base address plus two (10.0.0.0 + 2), one of the five addresses AWS reserves in each subnet (Lab 2). DNS uses UDP first and falls back to TCP for large or truncated answers, so both are needed.
- Authorised the new rules first (6 rule IDs), then revoked the default allow-all, so there was never a moment when the instance could not reach S3, STS or the database.
- 169.254.169.254 (the metadata service) does not need a rule. It is a link-local address handled by the host itself, and that traffic never goes through the instance's network interface or its security group.
- Result: usms-app-sg egress is the six rules and no -1 rule. Ingress unchanged (80 and 443 from 0.0.0.0/0, 22 from usms-bastion-sg). The audit no longer reports the default allow-all for usms-app-sg, only the two internet-ingress HIGH findings that Exercise 4 is about. verify-lab-09.sh still PASS=49 FAIL=1.
- usms-bastion-sg's egress is different in kind: a jump host exists to start SSH connections, so its egress is its job, not a side door. Its destination should be tcp/22 to usms-app-sg (the group that admits SSH from the bastion), not all traffic to 0.0.0.0/0.

## Exercise 2: Break-glass role and the open trust findings
### Part A: usms-breakglass-role
- policies/trust-breakglass.json: only arn:aws:iam::000000000000:user/usms-admin-01, with Bool aws:MultiFactorAuthPresent true AND StringEquals sts:ExternalId usms-breakglass-suspend-scaling. Both are in ONE Condition block, and different condition operators in the same block are combined with AND, so both must be true. (Several values inside one key would be OR.)
- ExternalId is normally for letting another account assume a role safely. Inside one account it is a deliberate extra step: you must know and type the value, so nobody assumes the break-glass role by accident or out of habit.
- Max session 3600 seconds, which is the shortest maximum IAM allows for a role (the range is 1 to 12 hours).
- Permissions boundary USMSPermissionsBoundary, so even if someone attaches more to it later, it is capped.
- policies/usms-breakglass-policy.json (USMSBreakGlassSuspendScaling): only application-autoscaling:RegisterScalableTarget (used with --suspended-state to suspend or resume scaling, as in Lab 6) and application-autoscaling:DescribeScalableTargets. No wildcard actions. Readable in ten seconds.
- Read back: max 3600, boundary set, trust shows both conditions, one attached policy.

### Part B: the open trust findings
- Fixed (each old trust saved as outputs/lab-09-<role>-trust-before.json first):
  - usms-ecs-exec-role: same scoped ecs-tasks trust as Step 7 (aws:SourceAccount and aws:SourceArn).
  - usms-lambda-exec-role: new policies/trust-lambda-scoped.json, lambda.amazonaws.com with aws:SourceAccount 000000000000 and aws:SourceArn arn:aws:lambda:us-east-1:000000000000:function:*.
  - usms-backup-operator-role: also a Lambda role with the same flaw, so the same fix.
  - All three now show their original service with conditions=2.
- Accepted, with reasons in configs/usms-iam-accepted-findings.txt (committed on purpose, a reason per line, otherwise it is just a suppression list):
  - usms-ec2-app-role: EC2 does not send aws:SourceArn for instance profiles, so a condition would lock the role out. Compensating controls: IMDSv2 required with hop limit 1 (Step 11), and USMSDeployBase denies passing any role to EC2 (Step 8).
  - usms-eks-node-role: same EC2 reason, and EKS is out of scope for this review.
  - usms-eks-cluster-role: EKS out of scope, to be revisited with aws:SourceArn pinned to the cluster ARN.
  - AWSServiceRoleForEcsApplicationAutoscaling: a service-linked role whose trust policy AWS owns and locks.
- scripts/utilities/usms-iam-audit.sh now reads that file and prints matching findings as "ACCEPTED (HIGH)" with the reason, instead of hard-coding exceptions. Result: HIGH=0 MED=35 ACCEPTED=4 roles=13, exit 0.
- With an empty decisions file the same audit exits 1, so any HIGH that is not accepted still fails it.
- I also saved the inventory builder as scripts/utilities/usms-iam-inventory.sh (each call retried 3 times, boundary taken from get-role), so it can be re-run after any trust change instead of pasting the long Python again.

## Exercise 3: The exposure report
- scripts/utilities/usms-exposure-report.sh puts every network interface in usms-vpc on one line, with a verdict worked out from three things only: the subnet's route table (is there a 0.0.0.0/0 route to an igw-), whether the interface has a public address, and its security groups' ingress rules. Names, tags and descriptions are only used as labels. It also writes outputs/lab-09-exposure.json.
- Verdicts: EXPOSED = igw route + public address + a rule open to 0.0.0.0/0. ISOLATED = no igw route, or no public address. ADDRESSABLE = igw route + public address but no rule lets the internet in. That last one is my answer for a public interface with no ingress rule at all (like a NAT gateway): it is not exposed today, but one added rule would make it so, so it deserves its own line instead of being hidden as ISOLATED or overstated as EXPOSED.
- It handles a group that was not in the first listing (asks for it directly), a subnet with no explicit route table (falls back to the VPC's main table), an interface with no description, and an interface left behind by a terminated instance.
- set -uo pipefail without -e, on purpose: one failed lookup should make one row say "unknown", not kill the whole report.
- It works from any folder (it finds the repo from its own path). The output from ~ and from labs/lab-09-security was IDENTICAL.
- First run showed usms-web-01 as ISOLATED ("igw route, but no public address"). Floci does not put the Elastic IP on the interface itself, but describe-addresses shows eipalloc-c83e5eab5465f2d38 associated with i-66fc3b0b10a198919 and eni-6db76d800ce384212 (Floci shows the address as 172.21.0.6 instead of the real 54.247.119.173). I changed the script to also read Elastic IP associations, which is right on real AWS too.
- Result: usms-web-01 EXPOSED (igw route + sg allows 443,80 from 0.0.0.0/0), usms-db-01 ISOLATED (no igw route), 18 ECS task interfaces ISOLATED (private subnet; only two addresses, 10.0.3.10 and 10.0.3.11, repeated nine times each, left over from tasks Floci restarted). EXPOSED=1 ISOLATED=19 interfaces=20.
- Floci has no interfaces for the load balancer or the NAT gateway, so those rows (which would be EXPOSED and ADDRESSABLE on real AWS) do not appear.
- Extra finding: eipalloc-a64be5014af20c8d6 (54.56.239.64) is an Elastic IP attached to nothing. On real AWS an unattached Elastic IP is charged every hour for doing nothing, so it should be released.
- Step 17's matrix only looked at security groups, so it could not tell that db-01 sits in a subnet with no route to the internet. This tool looks at both the routing and the security groups, which is why it can say ISOLATED for the database even though a security group alone could not.

## Exercise 5: The bucket policy draft
- scripts/utilities/usms-bucket-policy-draft.sh reads the bucket name out of USMSStudentDataReadWrite's document (not typed), using two shell parameter expansions: ${OBJECT_ARN%/*} to drop "/*" and ${BUCKET_ARN#arn:aws:s3:::} to drop the ARN prefix. Two exact cuts are simpler and clearer than sed or Python for that. Everything else (reading JSON) is Python. It applies nothing and works whether or not the bucket exists.
- It found 8 roles with s3 access to the bucket, from 6 policies: usms-ec2-app-role, usms-ecs-task-role, usms-eks-node-role (ReadWrite), usms-transcripts-reader-role (ReadOnly), usms-backup-operator-role (BackupOperator), usms-lambda-exec-role (LambdaBasic), usms-analytics-partner-role (only reports/*), usms-developer-role (DeveloperBase, list only). The handout talks about three transcripts policies; my account has more because of earlier exercises, and the script found them from the documents instead of a fixed list.
- outputs/lab-09-bucket-policy-draft.json: one Allow per role per resource limited to the actions it already has, a Deny for every principal ("*") when aws:SecureTransport is false, and a Deny with NotPrincipal for everyone except the 8 roles and the account root. Checks: PASS (every principal is an ARN except the TLS Deny, and the bucket ARN appears with and without /*). Valid JSON.
- outputs/lab-09-lab10-readiness.txt: bucket name, exists no, the 6 policy names, the 8 role ARNs, the principal count, and what changes when Lab 10 creates the bucket (nothing on that day; the difference comes when the S3 lab applies this draft).
- USMS_BUCKET_POLICY_DRAFT appended to configs/lab-09.env, now 17 exports.
- Known gotcha for the S3 lab: a Deny with NotPrincipal and role ARNs does not match the assumed-role session ARNs the roles actually call with, so it can lock the roles out. The usual fix is Principal "*" with a Condition on aws:PrincipalArn. I kept NotPrincipal because the exercise forbids "*" outside the TLS statement.
- Contrast: the Deny in USMSStudentDataReadOnly is an identity policy, so it can only stop the one role it is attached to. The Deny in the bucket policy is on the resource, so it stops everyone who is not on the list, whatever their own policies say. And an identity policy in my account is never even looked at for a principal in another account, while a bucket policy is checked for every request, including from another account.

## Exercise 4: Security review for the information security officer
### 1. The second front door
- usms-app-sg admits tcp/80 and tcp/443 from 0.0.0.0/0. That was right in Lab 2 Step 14, when usms-web-01 was the only way into USMS. Since Lab 5 the load balancer is the public entry point, but web-01 still has its own Elastic IP and its own open rules, so there are two public doors. The exposure report shows web-01 as EXPOSED.
- It should not still be reachable directly. To move it behind the load balancer: create a target group (target type instance) for web-01 on port 80 with a health check path, register web-01 in it, add a listener rule on the load balancer that forwards the web paths to that group, change usms-app-sg so tcp/80 comes only from usms-alb-sg, remove tcp/80 and tcp/443 from 0.0.0.0/0, and then disassociate and release web-01's Elastic IP.
- What would break: anyone or anything using the Elastic IP or a DNS name pointing at it; HTTPS, because the certificate would have to move to the load balancer (ACM) and TLS would end there; and the site would be down if the health check path is wrong.
- The other side: web-01 is a separate, older service, and putting it behind the same load balancer joins its fate to the enrolment service, so one bad listener change takes both down. If the two really serve different people, a separate small load balancer, or simply keeping it but locked to known networks, can be the more sensible choice.

### 2. What egress control bought
Three attacker behaviours Steps 13 to 15 now prevent:
- A compromised enrolment task opening a reverse shell to an attacker on a non-443 port (for example 4444): enrolment egress is tcp/443 only.
- A compromised enrolment task connecting straight to the database on 5432: enrolment has no egress to 5432, so lateral movement has to go some other way.
- Data being smuggled out of the database through DNS queries (DNS tunnelling) or over SSH or mail: usms-db-sg egress is tcp/443 only.
Two it does not prevent:
- Stealing data over HTTPS to an attacker's own website on 443. Stopping that needs hostname filtering, for example AWS Network Firewall, about $0.395 per endpoint-hour per Availability Zone plus $0.065 per GB processed (AWS Network Firewall pricing page).
- Misusing a role's real credentials through the AWS APIs (which also run on 443), for example copying transcripts to the attacker's own S3 bucket. That needs a VPC endpoint policy that only allows our own bucket (interface endpoints about $0.01 per hour per AZ plus $0.01 per GB, AWS PrivateLink pricing page), and detection with GuardDuty.

### 3. Who can read or write the transcripts
| Principal | How it gets access | Read | Write | Granting document |
|---|---|---|---|---|
| usms-ec2-app-role | attached policy, used by usms-web-01 | yes | Put and Delete | USMSStudentDataReadWrite |
| usms-ecs-task-role | attached policy, used by the enrolment tasks | yes | Put and Delete | USMSStudentDataReadWrite |
| usms-eks-node-role | attached policy, used by EKS nodes (its Deny * only applies outside us-east-1) | yes | Put and Delete | USMSStudentDataReadWrite |
| usms-transcripts-reader-role | attached policy | yes | no (explicit Deny) | USMSStudentDataReadOnly |
| usms-backup-operator-role | attached policy, only in us-east-1 | yes | no (Delete denied; it writes to usms-archive) | USMSBackupOperator |
| usms-lambda-exec-role | attached policy | yes | no | USMSLambdaBasic |
| usms-analytics-partner-role | attached policy | only reports/* | no | USMSAnalyticsPartnerReadOnly |
| usms-developer-role, and groups usms-developers (usms-dev-01), usms-admins (usms-admin-01), usms-qa (usms-qa-01) | s3:List* on "*" | file names only, not contents | no | USMSDeveloperBase |
| the account root | always | yes | yes | not limited by identity policies |
- Not on the list: usms-deploy-role (its boundary allows s3, but USMSDeployBase grants none), usms-breakglass-role, usms-ecs-exec-role. USMSReportingReadOnly would grant read but is attached to nothing.
- Indirect access also counts: anyone who can assume one of these roles, or launch an instance or task with one, inherits it. USMSAssumeAppRoles and USMSAssumeAnalyticsPartnerRole are the policies that allow assuming roles.
- How I know the list is complete: on real AWS the answer from the bucket's side comes from IAM Access Analyzer (external access is free; unused access is $0.20 per role or user per month, IAM Access Analyzer pricing page) or by simulating every principal. This course cannot do that for the bucket because the bucket does not exist yet and Floci evaluates nothing. Instead I read the default version of every customer managed policy in the account, kept every statement with an s3 action on "*" or on the bucket, looked up every entity each one is attached to with list-entities-for-policy, and expanded the groups to their users. The gap: I did not check AWS managed policies or users' inline policies, so the list is complete for customer managed policies only.

### 4. Detection
- Preventive controls stop things (IAM policies, boundaries, security groups, NACLs). Detective controls tell you something happened (CloudTrail, GuardDuty, Config, Access Analyzer). Everything in this lab so far is preventive; nothing would tell us if it changed.
- CloudTrail records every API call, including AuthorizeSecurityGroupIngress, AttachRolePolicy and AssumeRole. One trail delivering management events to S3 is free; extra copies are $2.00 per 100,000 events and data events $0.10 per 100,000 (CloudTrail pricing page).
- GuardDuty reads CloudTrail, VPC flow logs and DNS logs and flags unusual behaviour such as credentials used from an unexpected place. About $4.00 per million management events analysed, 30-day free trial (GuardDuty pricing page).
- AWS Config keeps the history of every security group and role and can alert on rules like "no SSH from 0.0.0.0/0". $0.003 per configuration item recorded and $0.001 per rule evaluation (AWS Config pricing page).
- IAM Access Analyzer flags any resource shared outside the account, free.
- What I would read first the morning after an incident, in order: GuardDuty findings (what looked wrong), CloudTrail for the affected principal (what it did, from where, especially AssumeRole and any IAM or security group change), AWS Config timeline for the security groups and roles involved (what changed and when), Access Analyzer (did anything become public), then VPC flow logs if they were on.

## Review questions
### 1. Why "nothing broke" is a strong result
Lab 9 changed a lot about who can do what, trust policies, egress, SSH and IMDS, and five scripts written before this lab, which check what Labs 2 to 6 built, gave exactly the same answers after a restart. That shows the security changes did not change what the system does, which is the thing people are most afraid of when tightening permissions. A plausible break: in Step 16, if I had removed the old SSH rule before adding the bastion rule, or in Step 13 if I had revoked allow-all on the enrolment group with a wrong document that also removed the tcp/80 ingress from the ALB, verify-lab-05 would have failed its "enrolment admits tcp/80 from usms-alb-sg" check. I would have put the rule back from the policies/ document straight away and then worked out what the document did wrong.

### 2. Attaching the boundary as a normal policy
attach-role-policy would make USMSPermissionsBoundary a grant instead of a ceiling. Upwards: the role would suddenly be allowed everything in it, like ecs:*, elasticloadbalancing:*, logs:*, s3:Get*, s3:List* and s3:PutObject on "*", far more than USMSDeployBase gives. Downwards: nothing caps the role any more, because the Deny statements in a normal policy still apply but there is no ceiling, so the next broad policy someone attaches would be fully effective. It becomes dangerous the moment anyone attaches a broader policy, or when s3:PutObject on "*" meets the transcripts bucket. Section 8's "the boundary is attached to NOTHING as an ordinary policy" check catches it.

### 3. A breach with every ingress rule correct
A bug in the enrolment API lets an attacker run commands inside a task. Ingress is perfect, the attacker came in on tcp/80 through the load balancer like any user. The task's role can read and write every transcript. The attacker reads the transcripts and sends them out. Step 13 narrows it: the task can no longer open a shell on port 4444 or talk to the database directly, but it can still send everything over HTTPS on 443, or copy it to their own S3 bucket with the role's credentials. Prevented entirely would need least privilege on the role (the API only reads, so the read-only role), a VPC endpoint policy limiting S3 to our own bucket, and hostname filtering on egress. This course cannot build that because Floci enforces no IAM, no endpoint policies and carries no traffic.

### 4. An attacker calling sts:AssumeRole from their own machine
- usms-ecs-task-role and usms-transcripts-reader-role trust only ecs-tasks.amazonaws.com, and now only for my account and my ECS resources. A person cannot assume them directly at all, only the ECS service can, so the attacker gets AccessDenied. They would have to get ECS to run a task with that role, which needs iam:PassRole.
- usms-deploy-role trusts the user usms-admin-01. If the attacker has usms-admin-01's credentials, they can assume it from anywhere, and get USMSDeployBase capped by the boundary. Without those credentials, they cannot.
- The answers differ because a service principal can only be used by the service, while a user principal can be used by whoever holds that user's keys. That is why the user-trusted role is the one that would also want MFA.

### 5. Five controls versus one
They protect against different failures. db-01's five controls are separate layers: routing, addressing, the security group and the NACL each fail in different ways, so one mistake leaves four. usms-enrolment-sg has one ingress rule in the matrix, so one wrong rule there is the whole of the security group's protection. But the matrix only models security groups. The enrolment tasks also sit in the private subnet with no internet gateway route and no public address, which the exposure report confirms (ISOLATED). So they are not really protected by one control, the matrix just cannot see the other layers. The real weakness for enrolment is the opposite direction: it is supposed to be reachable from the load balancer, so its protection depends on the load balancer and the application, not on how many network layers there are.

### 6. Key rotation
- Moving the consumer before touching the old key protects against an outage: the profile keeps working the whole time because both keys are active for a moment.
- Deactivating before deleting protects against a forgotten consumer: if some script still used the old key, it starts failing, I notice, and one command turns the key back on. Deleting first would turn that into a permanent outage.
- A long-lived key is a compromise because it works from anywhere, never expires, and ends up copied in files and history. A person should sign in through IAM Identity Center or another identity provider and get short-lived credentials. A workload should use a role (an instance profile, a task role or IRSA), so it never holds a key at all.

### 7. Is review a substitute for testing
Not fully. Reading catches things testing never shows, like the PassRole statement that could pass any role to any service, or the ec2.amazonaws.com trust with no condition, which no test ever trips because nobody is attacking during the test. Testing catches things reading misses, like a condition key the service never sends, which reads perfectly but makes the role unusable, or the Floci listing that still showed revoked rules (reading the wrong view looked fine, only checking the result showed the difference). For student transcripts I would want reading first, because the worst failures are things that are allowed but should not be, and you cannot test for every attacker. Then real testing on an account that enforces IAM.
