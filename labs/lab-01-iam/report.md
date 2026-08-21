# AWS Practical Laboratory Report

**Course:** DSO303
**Lab:** Lab 1 — Identity and Access Management (IAM)
**Student:** Pema Dolker
**Date:** 20/8/26

---

## Tools and Technologies Used

| Tool | Version (this session) | Purpose |
|---|---|---|
| Docker | 29.3.1 | Runs the Floci emulator as a container |
| Docker Compose | v2.32.4-3 | Declarative, reproducible container lifecycle management |
| Floci | CLI 0.2.0 / Server 1.5.34 | Local AWS emulator — IAM, S3, EC2, Lambda, STS, etc. |
| AWS CLI | 2.32.10 | Issues signed API requests against Floci (or real AWS) |
| Git | — | Version control; secret-safe repository from the first commit |
| `jq` | 1.8.1 | Parses JSON credential output (e.g. extracting STS temporary keys) |
| `python3` (`json.tool`, scripting) | — | Local JSON validation and programmatic policy-document edits |
| zsh | — | Shell used for all CLI work |

---

## 1. Aim / Objective

To create and manage IAM users, groups, roles, and policies for the University Student
Management System (USMS) using the AWS CLI against a local AWS emulator (Floci), and to
verify that identities, permissions, and trust relationships were configured correctly and
persist reliably across environment restarts.

Specifically, this practical aimed to:

- Set up a reproducible, durable local AWS environment (Docker Compose + Floci)
- Create IAM groups, users, and group memberships following the principle of least privilege
- Author customer managed and inline IAM policies from scratch
- Create IAM roles with separate trust and permissions policies for both AWS services
  (EC2, Lambda) and human users
- Obtain temporary credentials via STS `assume-role`
- Safely handle IAM access keys without ever committing secrets to version control
- Apply IAM concepts independently to five original scenarios (Independent Exercises 1–5)

---

## 2. Introduction

AWS Identity and Access Management (IAM) is a global AWS service that controls
**authentication** (who you are) and **authorization** (what you're allowed to do) across an
AWS account. IAM has no regional scope — unlike EC2 or S3, an IAM user, group, role, or
policy created in the account is visible identically everywhere, though every API call still
requires a region to be specified.

IAM's core building blocks are:

- **Users** — identities for people or long-lived programs, with permanent credentials
- **Groups** — containers for users; policies attached to a group apply to every member;
  groups have no credentials of their own and cannot be "assumed"
- **Roles** — identities with no permanent credentials, *assumed* to obtain temporary,
  auto-expiring credentials (used by EC2 instances, Lambda functions, and humans needing
  elevated, time-boxed access)
- **Policies** — JSON documents that explicitly Allow or Deny specific actions on specific
  resources, optionally under specific conditions

IAM is free to use and is considered the foundational security layer of any AWS account: no
other AWS service can be safely used without a correctly designed IAM structure underneath
it. Two policy-evaluation rules govern every decision IAM makes: **default deny** (no policy
means no access) and **explicit deny always wins** (a Deny statement overrides any number of
Allow statements, which is how organisations build unbreakable guardrails).

---

## 3. Use Case

The lab modeled a real university's cloud infrastructure — the **University Student
Management System (USMS)** — with three human roles and three service roles:

| Identity | Type | Represents | Permission level |
|---|---|---|---|
| `usms-admin-01` | User → `usms-admins` | Lead cloud engineer | Broad, course-scoped |
| `usms-dev-01` | User → `usms-developers` | Infrastructure builder | Build + inspect USMS resources |
| `usms-audit-01` | User → `usms-auditors` | University auditor | Read-only, everywhere |
| `usms-ec2-app-role` | Role | USMS application server | Read/write student data in S3 |
| `usms-lambda-exec-role` | Role | Notification functions | CloudWatch Logs + S3 read |
| `usms-developer-role` | Role | Temporarily assumed by developers | Elevated build permissions |

This mirrors common real-world patterns: developers, auditors, and administrators are
segmented by **group**, not by individually attached policies, so permissions scale cleanly
as the team grows or changes. Application servers and functions use **roles** instead of
permanent access keys, so credentials rotate automatically and are never stored on disk.

---

## 4. System Architecture / Design

```
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
```

*(Insert a screenshot or exported diagram here if a visual is required by your instructor —
the AWS CLI / IAM has no native diagram export, so this ASCII layout summarises the identity
hierarchy actually built.)*

---

## 4.1 IAM Concepts Quick Reference

Two pieces of IAM theory were essential to every step of this practical and are summarised
here for reference.

**Anatomy of an ARN** (Amazon Resource Name — the globally unique address of any AWS
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

**Policy evaluation logic** — the two rules that govern every access decision in AWS:

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

1. **Default deny** — no matching policy statement means no access; permissions are never
   implicit.
2. **Explicit deny always wins** — a single `Deny` statement overrides any number of `Allow`
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

---

## 5. Implementation Procedure

**Part A — Environment setup**
1. Verified Docker, Docker Compose v2, and the Floci CLI were installed and functioning.
2. Built the project directory structure (`policies/`, `configs/`, `scripts/`, `outputs/`,
   `labs/lab-01-iam/`, etc.) at the project root, so shared files (policies, configs) could
   be reused by later labs rather than nested inside a single lab's folder.
3. Wrote `.gitignore` and ran `git init` **before** any secret existed, and proved the
   ignore rule worked using both a fake test file and, later, a real IAM access key.
4. Wrote `docker-compose.yml` pinning Floci to `FLOCI_STORAGE_MODE=hybrid` with an absolute
   host bind mount (`~/floci-data`), replacing the non-durable `floci start` pattern used in
   a previous session (Lab 0).
5. Wrote `scripts/setup/floci-up.sh` and `floci-down.sh` to bring the environment up/down
   idempotently, with the up-script self-verifying that the bind mount is real.
6. Configured a named AWS CLI profile (`floci`) pointing at `http://localhost:4566`, rather
   than using environment-variable credentials, to avoid ambiguity about which credentials
   were actually in effect.
7. **Proved isolation from real AWS** three ways: confirmed the account ID was the dummy
   `000000000000`; inspected the actual request URL via `--debug`; and confirmed that
   stopping the local container broke all AWS CLI connectivity.
8. **Proved persistence**: created an IAM user, fully restarted the Floci container, and
   confirmed the user still existed afterward, with real files visible on disk in
   `~/floci-data`.
9. Wrote a diagnostic script (`floci-storage-check.sh`) covering six independent checks of
   the storage configuration, and committed all of Part A to Git.

**Part B — IAM foundation**
10. Created three IAM groups: `usms-admins`, `usms-developers`, `usms-auditors`.
11. Created three IAM users, each tagged with `Project` and `Role`, and captured their ARNs
    into shell variables rather than copying them by hand.
12. Added each user to its corresponding group and verified membership from both directions
    (`get-group` and `list-groups-for-user`).
13. Attached the AWS managed `ReadOnlyAccess` policy to `usms-auditors`.
14. Authored `USMSDeveloperBase`, a customer managed policy combining broad read access,
    scoped VPC-building permissions (region-restricted), and an explicit Deny statement
    blocking dangerous identity-escalation actions (e.g. `iam:CreateUser`,
    `iam:AttachUserPolicy`) as a guardrail against privilege escalation.
15. Authored `USMSStudentDataReadWrite`, an S3 policy correctly distinguishing
    **bucket-level** ARNs (for `ListBucket`) from **object-level** ARNs (for `GetObject` /
    `PutObject`), plus an explicit Deny on bucket deletion.
16. Attached an **inline** policy (`USMSSelfManageCredentials`) to `usms-dev-01`, using the
    `${aws:username}` policy variable so the document generically scopes to "whichever user
    it's attached to" — this required using a quoted heredoc (`<< 'EOF'`) to prevent the
    shell from prematurely expanding the variable.
17. Audited the built identities using `list-groups-for-user`, `list-attached-user-policies`,
    and `list-user-policies` together — demonstrating that a full permissions picture
    requires checking multiple, separate API calls.
18. Created a new policy version (v2) of `USMSDeveloperBase` using
    `create-policy-version --set-as-default`, adding two more networking actions without
    destroying the rollback-capable v1.
19. Created `usms-ec2-app-role` (trust: `ec2.amazonaws.com`) and wrapped it in an instance
    profile (`usms-ec2-app-profile`), since EC2 instances cannot be assigned a role directly.
20. Created `usms-lambda-exec-role` (trust: `lambda.amazonaws.com`) with permissions to write
    its own CloudWatch Logs and read student data.
21. Created `usms-developer-role`, trusted specifically by `usms-dev-01`, and separately
    granted `usms-developers`/`usms-admins` permission to call `sts:AssumeRole` on it — the
    "two-sided handshake" required for any role assumption to succeed.
22. Called `sts assume-role` and inspected the resulting temporary credentials
    (`AccessKeyId` starting with `ASIA`, a `SessionToken`, and a one-hour `Expiration`),
    used them via environment variables, then explicitly reverted to the default identity.
23. Created a permanent access key for `usms-dev-01`, redirected the output directly into
    `outputs/` (never displayed on screen), set file permissions to `600`, and confirmed via
    `git check-ignore -v` that the real secret file was blocked from being tracked by Git.
24. Ran `simulate-principal-policy` to test hypothetical permissions without executing them.
25. Wrote `configs/lab-01.env` capturing every created ARN for reuse by future labs, and
    archived the emulator's data directory as a fallback snapshot (Floci's native
    `snapshot save` command was unsupported on this server build).
26. Wrote and ran a 34-check end-to-end verification script covering environment health,
    persistence configuration, every group/user/policy/role, and Git secret hygiene.

**Independent Exercises**
27. Completed all five independent exercises (see Section 7 for design reasoning):
    the QA identity, a prefix-restricted read-only reporting policy, a time-boxed
    third-party analytics role, a least-privilege backup-operator role designed from a job
    description, and a policy-version update preparing the developer identity for Lab 2.

---

## 6. Results and Evidence

### 6.1 CLI Output

**Environment bootstrap — `.gitignore` and Git init, before any secret existed**
![.gitignore write, git init, and proof that a fake secret was blocked](../screenshots/01-gitignore-secret-proof.png)
`.gitignore` was written and the repository initialised first. A fake secret file was
written to `outputs/` to prove the ignore rule worked (`git status` never showed it, and
`git check-ignore -v` named the exact rule that blocked it) before it was deleted again.

**`configs/course.env` committed, and the first Git commit**
![git commit of .gitignore, and the full contents of configs/course.env](screenshots/02-git-commit-course-env.png)
The first commit (`chore: ignore secrets before the repo can hold any`) is visible in
`git log`, followed by the shared, secret-free `course.env` configuration file.

**`floci-up.sh` / `floci-down.sh` written**
![Creation of the idempotent start/stop scripts](screenshots/03-floci-up-down-scripts.png)
The two lifecycle scripts that bring Floci up on durable storage and pause it without losing
state.

**Environment verification (Docker Compose, Floci status, AWS CLI profile)**
![docker compose ps, floci status, health check, aws --version, and the floci CLI profile files](screenshots/04-environment-verification.png)
Three independent confirmations that Floci is healthy (`docker compose ps`, `floci status`,
and a raw `curl` health check), followed by the AWS CLI version check and the `floci`
profile's `~/.aws/config` / `~/.aws/credentials` contents.

**Identity check — confirming the Floci root account**
![aws sts get-caller-identity returning account 000000000000](screenshots/05-identity-check-root.png)
Confirms the AWS CLI is authenticating against Floci's dummy account
(`000000000000`), not a real AWS account.

**`whoami.sh` helper and `--debug` endpoint proof**
![whoami.sh output plus the --debug log confirming requests are sent to localhost](screenshots/06-whoami-debug-endpoint.png)
The `whoami.sh` diagnostic script confirms profile, endpoint, and identity in one call. The
`--debug` log beneath it independently confirms the CLI is resolving requests through the
local profile rather than reaching out to real AWS.

**Screenshot — Persistence and isolation proof**
![floci-down.sh breaking connectivity, floci-up.sh restoring it, and a user surviving a full container restart](screenshots/07-persistence-proof.png)
This single screenshot proves two separate claims required by the lab: **isolation**
(`Could not connect to the endpoint URL` appears immediately after stopping the container,
proving the CLI only ever reached the local emulator) and **persistence** (`persistence-check`
was created, the container was fully restarted via `docker compose restart`, and the user
was still retrievable afterward).

**Persistent data on disk, and AWS CLI exit codes**
![ls -la ~/floci-data showing real files, and exit code checks for success (0) and NoSuchEntity (254)](screenshots/08-floci-data-contents.png)
Confirms `~/floci-data` contains genuine files (not an empty directory), and demonstrates
the AWS CLI's exit-code convention: `0` for success, `254` for a service-level error such as
a missing IAM entity.

**Storage diagnostic script — all six checks passing**
![floci-storage-check.sh output showing six ok sections](screenshots/09-storage-check-script.png)
The custom diagnostic script confirms every layer of the durability configuration
independently: container ownership, storage mode, bind mount, sidecar storage path, no
orphaned volumes, and a non-empty host state directory.

**Part A committed, with Git secret-hygiene confirmed**
![git add/commit for Part A, and git ls-files confirming only safe files are tracked](screenshots/10-part-a-commit-git-hygiene.png)
The full environment bootstrap was committed, and `git ls-files | grep` confirms only
`configs/course.env` (secret-free) and `outputs/.gitkeep` (an empty placeholder) are tracked
under those two sensitive paths.

**Screenshot — Empty IAM account, then group creation**
![list-users returning an empty array, and create-group for all three groups](screenshots/11-list-users-create-groups.png)
Confirms the account started with zero IAM users before any resources were created, then
shows the three `usms-` groups being created.

**Screenshot — All three groups verified**
![list-groups --output table showing usms-admins, usms-developers, usms-auditors](screenshots/12-list-groups-table.png)

**Screenshot — User creation with captured ARNs**
![create-group, create-user x3 with ARN capture, and list-users in table format](screenshots/13-create-users-list-table.png)
All three IAM users (`usms-admin-01`, `usms-dev-01`, `usms-audit-01`) created with tags, ARNs
captured into shell variables, and confirmed via `list-users --output table`.

**Screenshot — `USMSDeveloperBase` created and attached to two groups**
![create-policy for USMSDeveloperBase, list-attached-group-policies, and get-policy showing AttachmentCount 2](screenshots/15-developer-base-policy-attach.png)
`get-policy` confirms `AttachmentCount: 2`, proving the policy was successfully attached to
both `usms-developers` and `usms-admins`.

**Screenshot — S3 data policy creation**
![usms-student-data-rw-policy.json and its creation via create-policy](screenshots/16-s3-policy-creation.png)
The `USMSStudentDataReadWrite` policy, distinguishing bucket-level and object-level S3 ARNs.

**Screenshot — `--generate-cli-skeleton` discovery**
![aws iam create-role --generate-cli-skeleton output](screenshots/17-generate-cli-skeleton.png)

**Screenshot — Inline policy with a policy variable**
![usms-self-manage-credentials.json using ${aws:username}, put-user-policy, and list-user-policies](screenshots/18-inline-policy-self-manage.png)
The `${aws:username}` variable survived the heredoc unexpanded (confirmed via `grep` before
attaching), and `list-user-policies` confirms the inline policy attached to `usms-dev-01`.

**Screenshot — Auditing a user's full permission picture**
![groups/attached/inline/access-keys audit commands, and get-policy-version reading back the actual policy document](screenshots/19-audit-policy-document.png)
Demonstrates that a complete permissions audit requires checking group membership, attached
policies, and inline policies separately — no single call gives the full picture.

**Screenshot — Policy versioning**
![list-policy-versions showing v1 and v2, with v2 as the new default](screenshots/20-policy-versions-v1-v2.png)
`USMSDeveloperBase` after `create-policy-version --set-as-default`: v1 preserved for
rollback, v2 now the active default.

*(Additional screenshots — role creation, the instance profile, STS temporary credentials,
access-key secret protection, and the final 34-check verification script — to be inserted
here once provided.)*

### 6.2 AWS Management Console Verification

Floci is a CLI/API-only local emulator with no graphical console, so console screenshots are
not applicable to this practical (see Section 7 for further discussion of Floci vs. real
AWS). All verification in this practical was performed via AWS CLI commands, which produce
the same JSON responses a real AWS account would return.

### 6.3 Automated Verification Summary

A 34-point verification script (`scripts/utilities/verify-lab-01.sh`) was written and run
against the completed environment. Every check passed on the final run:

| Category | Checks | Result |
|---|---|---|
| Environment (Docker, Compose, Floci health, account ID) | 7 | ✔ 7/7 |
| Persistence configuration (storage mode, bind mount, non-empty state dir) | 3 | ✔ 3/3 |
| Groups (`usms-admins`, `usms-developers`, `usms-auditors`) | 3 | ✔ 3/3 |
| Users (`usms-admin-01`, `usms-dev-01`, `usms-audit-01`) | 3 | ✔ 3/3 |
| Group membership | 1 | ✔ 1/1 |
| Policies (existence, default version, inline policy) | 6 | ✔ 6/6 |
| Roles + instance profile | 4 | ✔ 4/4 |
| Files and Git secret hygiene | 7 | ✔ 7/7 |
| **Total** | **34** | **✔ PASS=34  FAIL=0** |

### 6.4 Floci vs. Real AWS — Fidelity Observed in This Practical

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
**not** proof that a policy would correctly permit or deny a real request on live AWS.

---

## 7. Analysis and Discussion

**What was achieved.** A complete, working IAM foundation was built and independently
verified: three groups, three users, four customer managed policies plus one inline policy,
three roles (including a correctly wired instance profile), and a working STS
assume-role flow. A 34-point automated verification script confirmed every checkpoint passed,
including Git-hygiene checks proving that a real, generated access key was correctly
excluded from version control.

**Did results match expectations?** Mostly yes, with two notable, informative exceptions:

1. `aws iam get-account-authorization-details` returned `UnsupportedOperation` on this Floci
   build. This is a documented Floci limitation — a bulk-export API not implemented on this
   emulator version — rather than a configuration error.
2. `simulate-principal-policy`, when run against `usms-dev-01` for `ec2:CreateVpc`, returned
   `implicitDeny` even though the permission is genuinely granted through the user's
   membership in `usms-developers`. This was investigated by attempting to simulate directly
   against the group ARN (which real AWS's simulator does not support either — it requires a
   user or role ARN specifically) and by re-reading the actual policy document via
   `get-policy-version`, which confirmed the permission genuinely exists. This is best
   explained as Floci's simulator not fully replicating real AWS's group-policy inheritance
   during simulation — a useful, concrete illustration of the general caution the lab raises:
   **a command succeeding (or a simulator result) in Floci is not proof that a policy is
   correct; policies must be read and reasoned about directly.**
3. Floci's native `snapshot save`/`snapshot list` commands were unavailable on this server
   version (`Error: Snapshot API not available on this server version`). A `tar`-based
   fallback of the `~/floci-data` directory was used instead, which is format-agnostic and
   worked on every Floci version by design (all durable state lives in one directory).

**Errors encountered and resolved.**
- An earlier session (Lab 0) had started Floci with `floci start` directly and
  `eval $(floci env)`, bypassing Docker Compose and leaving stray `AWS_*` environment
  variables active. This was diagnosed by inspecting the container's Compose project label
  (empty = not Compose-managed) and resolved by removing the container
  (`floci stop --remove`) and unsetting the leftover environment variables before building
  the Compose-managed environment fresh.
- In Independent Exercise 3, `create-role --max-session-duration 1800` failed parameter
  validation (`valid min value: 3600`) — AWS enforces a one-hour floor on a role's own
  session-duration ceiling. This was resolved by setting the role's `MaxSessionDuration` to
  the permitted minimum (3600) and instead enforcing the actual 30-minute cap at
  assume-time via `--duration-seconds 1800`, confirmed by checking that the returned
  `Expiration` timestamp was ~30 minutes out, not an hour.

**Observations.** The clearest practical lesson was the distinction between a **trust
policy** and a **permissions policy** on a role — both must independently permit an action
(the role must trust the caller, *and* the caller must be permitted to call
`sts:AssumeRole`) before an assumption will succeed. This "two-sided handshake" was easy to
miss conceptually but straightforward to verify once understood. Similarly, auditing a
single user's effective permissions required checking three separate API calls
(group membership, attached policies, and inline policies) — a single command never gives
the full picture, which mirrors how real-world IAM audits must be performed.

---

## 8. Reflection

**1. What did you learn about this AWS service?**
IAM's permission model is deliberately layered and composable: users inherit permissions
from groups, roles separate "who can become this identity" from "what this identity can do,"
and every decision resolves through a strict default-deny-unless-explicitly-allowed rule
with explicit Deny always overriding. I also learned that policy authoring has sharp,
easy-to-miss edge cases — such as S3's bucket-ARN-vs-object-ARN distinction, or a role's
`MaxSessionDuration` having a real AWS-enforced floor — that only become obvious by writing
and testing real policy documents rather than reading about them abstractly.

**2. What challenges did you encounter?**
The main challenges were subtle rather than large: correctly quoting heredocs so that
`${aws:username}` survived into the policy file unexpanded; reasoning through why
`s3:CopyObject` doesn't exist as an action and a "copy" is really a `GetObject` plus a
`PutObject` on two different resources; and recognising that a policy simulator returning an
unexpected result in an emulator is a prompt to re-verify by reading the actual policy
document, not necessarily proof the policy itself is wrong.

**3. How would you apply this service in a real-world cloud environment?**
In a real organisation, this exact group-based structure (developers, auditors, admins)
would scale to dozens or hundreds of employees without requiring individual policy
attachments per person — onboarding or offboarding someone becomes a single group-membership
change. Roles would be used for every service (EC2, Lambda, CI/CD pipelines) instead of
long-lived access keys, eliminating an entire class of credential-leak risk. The explicit-deny
guardrail pattern used in `USMSDeveloperBase` (blocking `iam:CreateUser`,
`iam:AttachUserPolicy`, etc.) is a realistic technique for preventing privilege escalation
even if a broader policy is mistakenly attached later.

**4. What additional concepts or features would you like to explore?**
Multi-Factor Authentication (MFA) enforcement, Permission Boundaries and Service Control
Policies (SCPs) for guardrails at the organization level, Attribute-Based Access Control
(ABAC) using tags instead of static resource ARNs, and IAM Identity Center (AWS SSO) for
federated human access instead of individually managed IAM users.

---

## 9. Conclusion

The objectives of this practical were fully achieved. A durable, verifiable local AWS
environment was built and proven persistent across restarts, and a complete IAM foundation
for a realistic university system (USMS) was constructed from first principles: groups,
users, customer managed and inline policies, service and human-assumable roles, temporary
STS credentials, and safely-handled access keys. All 34 automated verification checks passed,
and five independent exercises extended the core lab material into original scenarios,
including designing a least-privilege policy from a plain-English job description and
correctly navigating a real AWS parameter-validation constraint.

This laboratory reinforced that IAM is the non-negotiable foundation of AWS security: every
other service's safety depends on IAM being configured correctly first. The practical also
demonstrated a broader, transferable skill — verifying infrastructure claims independently
rather than trusting that "the command succeeded" is sufficient evidence of correctness,
whether that meant proving persistence with a real restart test, or catching a simulator
result that didn't match the underlying policy document.

---

## 10. Appendix

**Policy documents** (in `policies/`):
- `usms-developer-base-policy.json` (v1), `usms-developer-base-policy-v2.json`,
  `usms-developer-base-policy-v3.json`
- `usms-student-data-rw-policy.json`
- `usms-self-manage-credentials.json`
- `usms-lambda-basic-policy.json`
- `usms-reporting-readonly-policy.json` (Exercise 2)
- `usms-analytics-partner-policy.json`, `usms-assume-analytics-role-policy.json` (Exercise 3)
- `usms-backup-operator-policy.json` (Exercise 4)
- Trust policies: `trust-ec2.json`, `trust-lambda.json`,
  `trust-account-developers.json`, `trust-analytics-partner.json`,
  `trust-backup-operator.json`

**Scripts** (in `scripts/`):
- `scripts/setup/floci-up.sh`, `scripts/setup/floci-down.sh`
- `scripts/utilities/whoami.sh`, `scripts/utilities/floci-storage-check.sh`,
  `scripts/utilities/verify-lab-01.sh`

**Configuration** (in `configs/`):
- `configs/course.env`, `configs/lab-01.env`

**Lab notes:** `notes/lab-01-notes.md` (includes the `sts:ExternalId` reflection and
Exercise 4 abuse-vector analysis)

**Git repository:** three commits — `.gitignore` committed first (before any secret
existed), followed by the environment bootstrap and the full IAM foundation build.

---

## Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described
- [x] System architecture included
- [x] All implementation steps documented
- [ ] CLI/SDK screenshots included *(insert from your own terminal — see Section 6.1)*
- [x] AWS Console verification — not applicable (Floci has no console; explained in Section 7)
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Appendix attached