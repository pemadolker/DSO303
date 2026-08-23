# AWS Practical Laboratory Report

**Course:** DSO303  
**Lab:** Lab 1 - Identity and Access Management (IAM)   
**Student:** Pema Dolker    
**Date:** 20/8/26   



## 1. Aim / Objective


The aim of this lab was to understand AWS Identity and Access Management through creation of an identity infrastructure in the fictitious University Student Management System (USMS) using AWS Command Line Interface. In place of actual AWS account, the emulator of AWS, which operates in our own machine and doesn't involve any cost, called Floci was used.


By the end of this lab we should be able to create users, groups and roles in IAM, create and assign policies, receive temporary credentials through STS and handle access keys without inadvertently commiting it to Git.



## 2. Introduction
 

Identity and Access Management (IAM) is the service in AWS which determines two fundamental things: **authentication**- who you are, and **authorization** - what you're allowed to do. IAM is available globally and without any charges and unlike EC2 instances, the identity and policies are not tied to any particular AWS region although every CLI command requires one.


There are four main building blocks of IAM:

- **Users** - identity for a person or a long running process with permanent credentials.
- **Groups**  - just a container for users. Policy is attached to a group and all members of that group receive it. Group itself does not have any credentials and is unable to do anything.
- **Roles**- identity without any permanent credentials at all. Credentials are instead assumed, and provide temporary credentials which automatically expire after some time. Roles are used for EC2 instances, Lambda functions and for humans requiring temporary elevated privileges.
- **Policies** - a JSON document stating Allow/Deny for a particular action to a particular resource.

IAM is considered the foundational security layer of any AWS account: no
other AWS service can be used safely  without  designing underlying IAM structure correctly. Every single access decision made by AWS obeys two fundamental principles: **default deny** -  nothing is allowed unless explicitly allowed and  **explicit deny** always wins - nothing is allowed if explicitly denied. The latter is the principle behind creating a guardrail which cannot be accidentally bypassed in the future.




## 3. Use Case

The lab revolves around a fictitious university's cloud infrastructure called - the **University Student
Management System (USMS)**  that has three humans and three service roles:


| Identity | Type | Represents |
|---|---|---|
| `usms-admin-01` | User in `usms-admins` | Lead cloud engineer |
| `usms-dev-01` | User in `usms-developers` | Builds infrastructure |
| `usms-audit-01` | User in `usms-auditors` | Read-only auditor |
| `usms-ec2-app-role` | Role | The application server |
| `usms-lambda-exec-role` | Role | Notification functions |
| `usms-developer-role` | Role | Assumed temporarily for elevated builds |


This reflects how real-life organizations operate - people are segmented based on their job functions **group** and not given individual policies, while servers run on **roles** instead of access keys saved on the disks.



## 4. System Architecture / Design

All this comes under one IAM account (that is, the fictitious account created by Floci, 000000000000). There are three groups that each have one user and one or more policies each. The three roles are distinct - two of the roles are assumed by the AWS services EC2 and Lambda, while one role is assumed by the human user usms-dev-01 to elevate their permissions.

<!-- ```
                    ┌─────────────────────────────────────────┐
                    │           IAM Account (Floci)            │
                    │         Account ID: 000000000000          │
                    └─────────────────────────────────────────┘
                                       │
        ┌──────────────────┬──────────────────────┬──────────────────────┐
        │                  │                      │                      │
   usms-admins        usms-developers        usms-auditors          (Roles)
        │                  │                      │
   usms-admin-01      usms-dev-01            usms-audit-01
        │                  │                      │
        └── USMSDeveloperBase (v3)            ReadOnlyAccess
             │                                      │
        USMSAssumeAppRoles                  USMSAssumeAnalyticsPartnerRole
             │
        [assumes] usms-developer-role  →  temporary creds (ASIA..., 1hr)

   ┌────────────────────────┐    ┌──────────────────────────┐
   │   usms-ec2-app-role     │    │  usms-lambda-exec-role    │
   │   trust: ec2.amazonaws  │    │  trust: lambda.amazonaws  │
   │   .com                  │    │  .com                     │
   │   perms: S3 RW on       │    │  perms: logs write +      │
   │   usms-student-data     │    │  S3 read on student-data  │
   │   wrapped in:           │    └──────────────────────────┘
   │   usms-ec2-app-profile  │
   └────────────────────────┘
``` -->

## 4.1 IAM Concepts Quick Reference

Two pieces of IAM theory were essential to every step of this practical and are summarised
here for reference.

**Anatomy of an ARN** (Amazon Resource Name - the globally unique address of any AWS
resource):

```
arn:aws:iam::000000000000:user/usms-dev-01
 │   │   │  │       │           └── resource (type/name)
 │   │   │  │       └────────────── account id (12 digits)
 │   │   │  └────────────────────── region — EMPTY for IAM, since it is a global service
 │   │   └───────────────────────── service (iam, s3, ec2, sts, ...)
 │   └───────────────────────────── partition (aws | aws-cn | aws-us-gov)
 └───────────────────────────────── literal prefix, always "arn"
```

**Policy evaluation logic** - the two rules that govern every access decision in AWS:

```
                For every request
                       │
                       ▼
        Is there an explicit DENY anywhere?
              /                    \
           YES                      NO
            │                        │
        ✗ DENIED          Is there an explicit ALLOW?
                              /              \
                            NO               YES
                             │                 │
                    ✗ DENIED (default)     ✓ ALLOWED
```

1. **Default deny** - no matching policy statement means no access; permissions are never
   implicit.
2. **Explicit deny always wins** - a single `Deny` statement overrides any number of `Allow`
   statements. This is the mechanism behind `USMSDeveloperBase`'s
   `DenyDangerousIdentityChanges` statement: even if a broader policy were mistakenly
   attached to a developer later, the explicit deny on `iam:CreateUser`,
   `iam:AttachUserPolicy`, etc. would still hold.

**Permissions policy vs. trust policy** — the distinction that governs every role built in
this lab:

| | Permissions policy | Trust policy |
|---|---|---|
| Answers | "What may this identity do?" | "Who may become this role?" |
| Attached via | `--policy-document` on `create-policy` / `attach-*-policy` | `--assume-role-policy-document` on `create-role` (exactly one per role) |
| Applies to | users, groups, roles | roles only |

Both halves are required independently for a role assumption to succeed — a role can have a
perfect permissions policy and still be unusable if its trust policy doesn't name the
intended caller (or vice versa).


## 5. Implementation Procedure


**Part A -Setting up the environment.**
Before even considering starting work with IAM, I needed to set up the proper working AWS environment locally. First, I made a project folder structure (policies/, configs/, scripts/, outputs/), added .gitignore file and ran git init before creating any files that might contain sensitive information, and proved that ignoring works as I wanted it to by committing a test secret file and then verifying that it does not appear in git status.
 
Floci runs with Docker Compose, and not with the `floci start` command, since the latter does not activate durable storage mode by default and its state is stored in RAM. I activated that mode in docker-compose.yml by setting FLOCI_STORAGE_MODE=hybrid and a bind mount in the container (~/floci-data) and created simple floci-up.sh / floci-down.sh scripts that allow me to run up and shut down the floci container without having to remember the flag every time.



Then I had to prove two different facts, not interchangeable: that my commands never hit the real AWS (the account ID is the dummy `000000000000`, --debug option showed me that every request is being sent to localhost:4566), and that the data is indeed persistent between the reboots (created a test IAM user, restarted the container, and the user was still there after that). 


**Part B - Building the IAM infrastructure.**

Having successfully created the environment, I started with creating the groups and then users (tagging and assigning them into the corresponding group). I attached the `ReadOnlyAccess` managed AWS policy to the auditors group, then created a customer managed policy `USMSDeveloperBase`, which grants the developers broad read permissions, along with a narrow set of networking actions they will need during the VPC lab, with an `explicit Deny` of identity escalation actions such as `iam:CreateUser`.


Also, I created the second customer managed policy, `USMSStudentDataReadWrite`, that grants access to the specific S3 bucket. It required careful handling of the difference between the bucket arn (arn:...:usms-student-data) and the objects within it (arn:...:usms-student-data/*), since `s3:ListBucket` works with the former, while `s3:GetObject` works with the latter.

Finally, I attached an inline policy to usms-dev-01 allowing to manage access keys, and used the ${aws:username} variable to make the same policy fit any username it is attached to.
 

Next, I made a second copy of the `USMSDeveloperBase` stack that gives additional permissions but still allows for rollback, created the two service roles (EC2 and Lambda, each with its own trust policy identifying the correct service), wrapped the EC2 role in an instance profile because EC2 cannot assume a role directly, and finally created the `usms-developer-role` that humans can assume for limited time periods - which requires both a trust policy pointing at `usms-dev-01` and another policy that enables the developers group to AssumeRole.


I executed `sts assume-role`, looked at the temporary credentials returned by it (an ASIA-prefixed key, a session token, and an expiry time of one hour), used the credentials temporarily, and reverted to my regular identity. Last I generated an actual access key for `usms-dev-01`, redirected it to `outputs/`, which means it will not get displayed anywhere, set the permissions on it to 600, and verified via git check-ignore that it is not accidentally included in any commits.



## 6. Results and Evidence

### 6.1 CLI Output

**Environment bootstrap - `.gitignore` and Git init, before any secret existed**
![.gitignore write, git init, and proof that a fake secret was blocked](../../screenshots/01-gitignore-secret-proof.png) 
`.gitignore` was written and the repository initialised first. A fake secret file was
written to `outputs/` to prove the ignore rule worked (`git status` never showed it, and
`git check-ignore -v` named the exact rule that blocked it) before it was deleted again.

**`configs/course.env` committed, and the first Git commit**
![git commit of .gitignore, and the full contents of configs/course.env](../../screenshots/02-git-commit-course-env.png)
The first commit (`chore: ignore secrets before the repo can hold any`) is visible in
`git log`, followed by the shared, secret-free `course.env` configuration file.

**`floci-up.sh` / `floci-down.sh` written**
![Creation of the idempotent start/stop scripts](../../screenshots/03-floci-up-down-scripts.png)
The two lifecycle scripts that bring Floci up on durable storage and pause it without losing
state.

**Environment verification (Docker Compose, Floci status, AWS CLI profile)**
![docker compose ps, floci status, health check, aws --version, and the floci CLI profile files](../../screenshots/04-environment-verification.png)
Three independent confirmations that Floci is healthy (`docker compose ps`, `floci status`,
and a raw `curl` health check), followed by the AWS CLI version check and the `floci`
profile's `~/.aws/config` / `~/.aws/credentials` contents.

**Identity check - confirming the Floci root account**
![aws sts get-caller-identity returning account 000000000000](../../screenshots/05-identity-check-root.png)
Confirms the AWS CLI is authenticating against Floci's dummy account
(`000000000000`), not a real AWS account.

**`whoami.sh` helper and `--debug` endpoint proof**
![whoami.sh output plus the --debug log confirming requests are sent to localhost](../../screenshots/06-whoami-debug-endpoint.png)
The `whoami.sh` diagnostic script confirms profile, endpoint, and identity in one call. The
`--debug` log beneath it independently confirms the CLI is resolving requests through the
local profile rather than reaching out to real AWS.

**Persistence and isolation proof**
![floci-down.sh breaking connectivity, floci-up.sh restoring it, and a user surviving a full container restart](../../screenshots/07-persistence-proof.png)
This single screenshot proves two separate claims required by the lab: **isolation**
(`Could not connect to the endpoint URL` appears immediately after stopping the container,
proving the CLI only ever reached the local emulator) and **persistence** (`persistence-check`
was created, the container was fully restarted via `docker compose restart`, and the user
was still retrievable afterward).

**Persistent data on disk, and AWS CLI exit codes**
![ls -la ~/floci-data showing real files, and exit code checks for success (0) and NoSuchEntity (254)](../../screenshots/08-floci-data-contents.png)
Confirms `~/floci-data` contains genuine files (not an empty directory), and demonstrates
the AWS CLI's exit-code convention: `0` for success, `254` for a service-level error such as
a missing IAM entity.

**Storage diagnostic script - all six checks passing**
![floci-storage-check.sh output showing six ok sections](../../screenshots/09-storage-check-script.png)
The custom diagnostic script confirms every layer of the durability configuration
independently: container ownership, storage mode, bind mount, sidecar storage path, no
orphaned volumes, and a non-empty host state directory.

**Part A committed, with Git secret-hygiene confirmed**
![git add/commit for Part A, and git ls-files confirming only safe files are tracked](../../screenshots/10-part-a-commit-git-hygiene.png)
The full environment bootstrap was committed, and `git ls-files | grep` confirms only
`configs/course.env` (secret-free) and `outputs/.gitkeep` (an empty placeholder) are tracked
under those two sensitive paths.

**Empty IAM account, then group creation**
![list-users returning an empty array, and create-group for all three groups](../../screenshots/11-list-users-create-groups.png)
Confirms the account started with zero IAM users before any resources were created, then
shows the three `usms-` groups being created.

**All three groups verified**
![list-groups --output table showing usms-admins, usms-developers, usms-auditors](../../screenshots/12-list-groups-table.png)

**User creation with captured ARNs**
![create-group, create-user x3 with ARN capture, and list-users in table format](../../screenshots/13-create-users-list-table.png)
All three IAM users (`usms-admin-01`, `usms-dev-01`, `usms-audit-01`) created with tags, ARNs
captured into shell variables, and confirmed via `list-users --output table`.

**`USMSDeveloperBase` created and attached to two groups**
![create-policy for USMSDeveloperBase, list-attached-group-policies, and get-policy showing AttachmentCount 2](../../screenshots/15-developer-base-policy-attach.png)
`get-policy` confirms `AttachmentCount: 2`, proving the policy was successfully attached to
both `usms-developers` and `usms-admins`.

**S3 data policy creation**
![usms-student-data-rw-policy.json and its creation via create-policy](../../screenshots/16-s3-policy-creation.png)
The `USMSStudentDataReadWrite` policy, distinguishing bucket-level and object-level S3 ARNs.

**`--generate-cli-skeleton` discovery**
![aws iam create-role --generate-cli-skeleton output](../../screenshots/17-generate-cli-skeleton.png)

**Inline policy with a policy variable**
![usms-self-manage-credentials.json using ${aws:username}, put-user-policy, and list-user-policies](../../screenshots/18-inline-policy-self-manage.png)
The `${aws:username}` variable survived the heredoc unexpanded (confirmed via `grep` before
attaching), and `list-user-policies` confirms the inline policy attached to `usms-dev-01`.

**Auditing a user's full permission picture**
![groups/attached/inline/access-keys audit commands, and get-policy-version reading back the actual policy document](../../screenshots/19-audit-policy-document.png)
Demonstrates that a complete permissions audit requires checking group membership, attached
policies, and inline policies separately — no single call gives the full picture.

**Policy versioning**
![list-policy-versions showing v1 and v2, with v2 as the new default](../../screenshots/20-policy-versions-v1-v2.png)
`USMSDeveloperBase` after `create-policy-version --set-as-default`: v1 preserved for
rollback, v2 now the active default.

**EC2 role, permissions attachment, and instance profile**
![get-role showing ec2.amazonaws.com trust, list-attached-role-policies, and get-instance-profile confirming the role is wrapped correctly](../../screenshots/21-ec2-role-instance-profile.png)
`usms-ec2-app-role` trusts `ec2.amazonaws.com`, has `USMSStudentDataReadWrite` attached, and
is correctly wrapped inside `usms-ec2-app-profile` — the wrapper an EC2 instance actually
attaches to, since a role cannot be assigned to an instance directly.

**Developer role (trust + assume-permission handshake)**
![trust-account-developers.json, create-role usms-developer-role, and the separate USMSAssumeAppRoles policy granting groups permission to call AssumeRole](../../screenshots/22-developer-role-trust-assume.png)
Demonstrates the two-sided handshake required for role assumption: the role's trust policy
names `usms-dev-01` specifically, and a *separate* policy (`USMSAssumeAppRoles`) grants
`usms-developers`/`usms-admins` permission to actually call `sts:AssumeRole` on it.

**Lambda execution role**
![usms-lambda-basic-policy.json, role creation, and list-roles filtered to usms- resources](../../screenshots/23-lambda-role-creation.png)
`usms-lambda-exec-role`, trusted by `lambda.amazonaws.com`, with permissions to write its own
CloudWatch Logs and read student data for notification purposes.

**Temporary credentials via STS `assume-role`**
![assume-role output showing an ASIA-prefixed access key, session token, and one-hour expiration](../../screenshots/24-sts-assume-role-temp-creds.png)
The four tell-tale signs of temporary credentials: an `ASIA`-prefixed access key (vs. `AKIA`
for permanent keys), a `SessionToken`, an `Expiration` roughly one hour out, and an
`AssumedRoleUser.Arn` in the distinct `assumed-role/...` ARN shape.

**Acting as the assumed role, then reverting**
![get-caller-identity showing the assumed-role ARN while temp creds are exported, followed by unset and whoami.sh confirming the return to the root identity](../../screenshots/25-using-temp-creds-and-reverting.png)
Confirms the temporary credentials were genuinely usable (the identity check reflects the
assumed role, not the original user), and that reverting via `unset` correctly restored the
default identity afterward.

**Access key creation and secret protection**
![create-access-key redirected straight to outputs/, chmod 600, git check-ignore naming the exact rule, and the resulting usms-dev profile working](../../screenshots/26-access-key-secret-protection.png)
The real, generated access key was never displayed on screen, was set to owner-only
permissions (`600`), and `git check-ignore -v` confirms it is blocked from being tracked by
the `*-access-key.json` rule. A second AWS CLI profile (`usms-dev`) was then configured using
this key and confirmed working.

**Policy simulator**
![simulate-principal-policy showing allowed/explicitDeny/implicitDeny decisions for three test actions](../../screenshots/27-simulate-principal-policy.png)
`iam:CreateUser` correctly returns `explicitDeny` (blocked by the `DenyDangerousIdentityChanges`
guardrail statement) and `s3:GetObject` correctly returns `implicitDeny`. `ec2:CreateVpc`
unexpectedly also returned `implicitDeny`, despite the permission being genuinely granted via
group membership — discussed as a documented Floci limitation in Section 7.

**`configs/lab-01.env` generated**
![Full contents of configs/lab-01.env, capturing every ARN built in this lab for reuse by future labs](../../screenshots/28-lab01-env-generated.png)

**Emulator state archived as a fallback snapshot**
![tar -czf archiving ~/floci-data after floci native snapshot commands proved unsupported](../../screenshots/29-snapshot-tar-fallback.png)
Floci's native `snapshot save`/`list` commands returned "Snapshot API not available on this
server version," so a `tar`-based archive of `~/floci-data` was used instead — a fallback
that works on every Floci version, since all durable state lives in one directory.

**Final end-to-end verification script**
![verify-lab-01.sh script creation and its first full run, ending in PASS=34 FAIL=0](../../screenshots/30-final-verification-script.png)
The complete 34-check verification script, covering environment health, persistence
configuration, every group/user/policy/role, and Git secret hygiene — all passing on the
first full run after the core lab was completed.

<!-- ### 6.2 AWS Management Console Verification

Floci is a CLI/API-only local emulator with no graphical console, so console screenshots are
not applicable to this practical (see Section 7 for further discussion of Floci vs. real
AWS). All verification in this practical was performed via AWS CLI commands, which produce
the same JSON responses a real AWS account would return. -->


<!-- 
### 6.2 Floci vs. Real AWS - Fidelity Observed in This Practical

| Aspect | Behaved like real AWS? | Notes |
|---|---|---|
| CLI commands, flags, JSON response shape | Yes | Identical throughout |
| ARN format | Yes | Account fixed at `000000000000` instead of a real 12-digit ID |
| Policy document syntax, versioning (5-version limit) | Yes | `create-policy-version` behaved exactly as documented |
| STS `assume-role` response shape (`ASIA` prefix, session token, expiration) | Yes | Fully faithful |
| `MaxSessionDuration` minimum enforcement (3600s floor) | Yes | Caught a real design constraint during Exercise 3 |
| IAM authorization actually enforced on requests | **No** | Floci accepts any non-empty credentials; policies are stored and syntactically validated but not enforced by default |
| `GetAccountAuthorizationDetails` | **No** | Returned `UnsupportedOperation` on this build |
| `simulate-principal-policy` with group-inherited permissions | **Partial** | Returned `implicitDeny` for a permission genuinely granted via group membership |
| `floci snapshot save/list` | **No** | Unsupported on this server version; `tar`-based fallback used instead |
| AWS Management Console | **N/A** | Floci is CLI/API-only; no graphical console exists |

This table is the practical evidence behind the general caution raised in Section 7: a
command succeeding inside Floci is proof that the *syntax and API shape* are correct, but is
**not** proof that a policy would correctly permit or deny a real request on live AWS. -->


## 7. Analysis and Discussion

Everything I had to built was built successfully: three groups, three users, four of my policies plus AWS-managed one, three roles (with the instance profile connection) and STS process works fine.

There were a couple of issues, however, and these were the cases when I had unexpected behavior which was worthy of attention. 
The first one is `get-account-authorization-detail` s call returning an error of type `UnsupportedOperation` - this function is simply not implemented in Floci version I use. 
The second one is `simulate-principal-policy`: I called it with `usms-dev-01` for `ec2:CreateVpc` permission, and it returned me an `implicitDeny` result, even though I knew this user does have the permission due to his group. After looking into the actual policy document via `get-policy-version `call, I found that it indeed contains the permission. So this seems to be a case of Floci simulator not taking into account inherited permissions of the user. This is a good case of showing that a negative response from any tools is not proof of invalid policy itself - you still should look into the policy document.
 
The only error appeared because of a mistake in my part in the previous exercise: I used `floci start` command instead of using Compose, and thus got some `AWS_*` variables left around and a container without a volume backing it up. I detected that it was created outside of Compose by an empty value of Compose project label in its description, removed it, and then un-set all leftover environment variables and rebuilt properly.

The second real error occurred while executing one of the independent exercises: creation of a role with `--max-session-duration 1800 ` failed due to AWS requirement of minimum one hour for this parameter. I left the role ceiling as is (3600) but instead limited the session with assume-time and `--duration-seconds 1800`.


**Observations.**  The most important practical takeaway is the difference between the **trust policy** and the **permissions policy** for a role. Both should separately allow the operation in question, meaning that the role should trust the caller **and** the caller should have permissions to call sts:AssumeRole for the assumption to be possible. The double handshake aspect can easily be overlooked from a conceptual point of view but it is easy to check once it is clear. The same applies to auditing the permissions of a single user since there are three separate API calls that should be made.



## 8. Reflection

I expected IAM to be mostly about creating user and then assigning the policy. But manually creating those policy documents changed my understanding that there is a difference between permission and trust policy on a role. And while the difference is clear now, it took some time to realize that AWS intentionally does not merge the two: one is used to say "what the resource may do" and another to specify "who may attempt to do". And missing any one of those will break the role, and error message won't tell you which part is broken.
 
The actual problem of mine was related to heredoc quoting of the policy file content. While trying to include `${aws:username}`, I forgot to quote the marker of the heredoc and the shell happily expanded the variable to an empty string, leaving the JSON without a value I needed. The policy was created with success, but did nothing, which taught me the good lesson about validating the actual file content, and not just the success of the command.

Another point that was quite interesting is the non-existence of `s3:CopyObject` action, since it turns out to be just a combination of `GetObject` action on one path and `PutObject` action on another. It becomes quite clear once you understand the separation between bucket and object ARNs.
 
And lastly, in terms of this lab, the most important thing I learned is to not trust Floci's "yes" or "no" result as validation of something. Since the policies are not enforced by default, a broad `Action: *` policy works exactly like a narrowly scoped policy here: you should validate the policy manually by reading it.

In a real working environment, this kind of structure will probably matter much more due to group membership being the primary method of granting permissions and because using roles instead of access keys on the server means that no permanent secret is stored there anymore.
 

## 9. Conclusion

Objectives of the lab were achieved. I set up an effective IAM infrastructure for USMS (groups, users, customer managed and inline policies, service roles, role assumed by humans, temporary STS credentials and an access key which was never stored in Git). All these components were verified using the CLI. There were two instances when Floci did not behave as expected (the implicitDeny in simulator and the authorization-details API call), but it proved to be a blessing in disguise as it required me to verify all the steps by actually looking at the policy.


## 10. Appendix

**Policy documents** (`policies/`): `usms-developer-base-policy.json` (v1/v2),
`usms-student-data-rw-policy.json`, `usms-self-manage-credentials.json`,
`usms-lambda-basic-policy.json`, trust policies for EC2, Lambda, and the
developer role.
 
**Scripts** (`scripts/`): `floci-up.sh`, `floci-down.sh`, `whoami.sh`,
`floci-storage-check.sh`, `verify-lab-01.sh`.
 
**Config** (`configs/`): `course.env`, `lab-01.env`.