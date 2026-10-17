# Lab 01 Notes - IAM

## Step 7 - storage modes

`--persist` only decides *where* Floci is allowed to write; the storage mode decides *whether* it writes anything durable at all. In memory mode every user, group and policy lives in the container's RAM, so the mounted directory exists but stays almost empty, and all of it disappears when the container stops.

Checked in Step 14: after switching to `FLOCI_STORAGE_MODE=hybrid` through Compose, `~/floci-data` filled up with real files, and the `persistence-check` user survived a restart.

<!-- In memory mode the mount exists but Floci keeps state in RAM and never writes it to that directory, so it stays nearly empty. Check this against what you saw in Step 14. -->

## Step 32 - policy simulator prediction

My prediction for `usms-audit-01`, written before running anything. The auditors group only has `ReadOnlyAccess`:

- `ec2:DescribeVpcs`: **allowed**, because `ReadOnlyAccess` grants `ec2:Describe*`.
- `ec2:CreateVpc`: **implicitDeny**. Nothing attached to the auditor allows it, and no Deny statement names it either, so it falls through to the default deny.

What the simulator (or the policy JSON) actually said: `ec2:CreateVpc` → `implicitDeny`, `ec2:DescribeVpcs` → `allowed`. My prediction was right.


Earlier in Step 32, the simulator returned `implicitDeny` for `usms-dev-01` on `ec2:CreateVpc`, although the developers group does grant it. Reading the policy version showed the permission is there, so on this build the simulator does not seem to count permissions a user inherits from a group. That is why I trusted the JSON over the tool.

<!-- write the prediction as a prediction. usms-audit-01 has ReadOnlyAccess, so ec2:DescribeVpcs is allowed and ec2:CreateVpc is implicitDeny: nothing allows it, and no Deny names it. Then record what the simulator returned. If Floci didn't run it, quote the policy statement. -->

## Attached vs inline policies

An attached (managed) policy is its own object with its own ARN. It can be attached to many users, groups and roles, and it keeps versions, so I could roll `USMSDeveloperBase` back from v3 to v2 or v1. An inline policy is written directly into one identity. It has no ARN of its own and no versions, and it is deleted together with that identity. I used inline only for `USMSSelfManageCredentials`, because "manage your own keys" belongs to exactly one user and should never be reused by accident.
<!-- 
managed policies are standalone, versioned and reusable across many identities. Inline policies live inside one identity, have no versions, and are deleted with it. -->

<!--  inline USMSSelfManageCredentials allows iam:CreateAccessKey, but USMSDeveloperBase explicitly denies it. Explicit deny wins, so on real AWS usms-dev-01 could not create its own keys. -->

One thing I noticed while writing this: the inline policy allows `iam:CreateAccessKey`, but `USMSDeveloperBase` has an explicit Deny on the same action. Explicit deny always wins, so on real AWS `usms-dev-01` could not actually create its own access keys. The two policies contradict each other. To let developers rotate their own keys, the Deny would have to be narrowed, for example to deny `CreateAccessKey` only on other users' ARNs.

## Exercise 3 - should the analytics role use `sts:ExternalId`?

Not here. `ExternalId` protects against the confused deputy problem, which only appears when an outside company assumes roles in many customers' accounts using one shared role ARN. Here the trust policy names one user inside our own account (`usms-audit-01`), so there is no third party that could be tricked. If the role were ever opened to a real partner's AWS account, I would add `"Condition": {"StringEquals": {"sts:ExternalId": "<shared-secret>"}}` to the trust policy and the partner would pass `--external-id` on every `assume-role`.

## Exercise 4 - user, group, or role? (one paragraph)

A role. The backup job is a machine running unattended every night, not a person, so it should never hold a permanent access key that someone has to store, rotate and protect. A role gives it temporary credentials that expire on their own, and the trust policy limits who can use it (`lambda.amazonaws.com`). A group is not an option on its own, because a group is not an identity: nothing can log in "as a group", it only hands permissions to users. A user would work technically, but it would mean a long-lived key sitting in the job's configuration, which is exactly what this course keeps saying to avoid.

## Exercise 4 - three ways the policy could still be abused, and how to close each

1. **Overwriting is a kind of deleting.** The Deny blocks `DeleteObject`, but `PutObject` on `usms-archive/*` can still overwrite an existing archive file with garbage, and the old copy is gone. Fix: turn on versioning (or S3 Object Lock) on `usms-archive`, so an overwrite creates a new version instead of destroying the old one.
2. **It can write anywhere in the archive.** `PutObject` is allowed on every key, not just the nightly backup folder. Fix: narrow the Resource to a prefix such as `arn:aws:s3:::usms-archive/nightly/*`.
3. **"Verify" is only "can read it back".** A buggy or tampered job could copy wrong data and still pass its own check. Fix: this is mostly an application fix (compare checksums or ETags of source and copy), and the policy can help by requiring encryption headers on `PutObject` with a Condition.

## Exercise 5 - updating verify-lab-01.sh to v3

`verify-lab-01.sh` checked that `USMSDeveloperBase` defaults to v2. After Exercise 5 the correct default is v3, so the check was failing even though nothing was wrong. I changed the expected version to v3, so the script describes the system as it is now. A verification script that is never updated stops being trusted.

## Review questions

### 1. Trust vs permissions

Almost certainly the trust policy is missing, or it does not name the person or service trying to use the role. A role needs two separate things: a trust policy that says who may *become* the role, and a permissions policy that says what the role may *do* once someone has become it. A perfect permissions policy is useless if nobody is allowed through the door. (On the caller's side, the user also needs permission to call `sts:AssumeRole`, which is the second half of the handshake I built in Step 30.)

<!-- the trust policy is missing or doesn't name the caller (and the caller may also lack sts:AssumeRole). The documents are separate because "who may become this role" and "what the role may do" are different questions, often owned by different people. -->

IAM keeps the two documents separate because they answer different questions and are often owned by different people. In a cross-account setup, the account that owns the role decides who can enter, while what the role can do is about that account's own resources. Keeping them apart also means you can change who is allowed in without touching what they can do, and the other way round.

### 2. Explicit vs implicit deny

`iam:CreateUser` fails because of an **explicit deny**: the `DenyDangerousIdentityChanges` statement in `USMSDeveloperBase` names it. `dynamodb:PutItem` fails because of an **implicit deny**: no policy attached to `usms-dev-01` mentions DynamoDB at all, so it falls through to the default "no".

To tell them apart, the policy simulator reports `explicitDeny` or `implicitDeny` in `EvalDecision`. On real AWS the error message also differs: "with an explicit deny in an identity-based policy" versus "because no identity-based policy allows the action".

The fix is different because of the evaluation order. An implicit deny is fixed by adding an Allow. An explicit deny cannot be fixed with any Allow, however many you attach; you have to change or remove the Deny statement itself. That is exactly why we put the guardrail in as an explicit Deny.


<!-- iam:CreateUser hits your DenyDangerousIdentityChanges statement, an explicit deny that no Allow can override. dynamodb:PutItem is denied only because nothing allows it. To tell them apart, look at the simulator's explicitDeny vs implicitDeny, or real AWS's error text ("with an explicit deny" vs "because no identity-based policy allows"). The fixes: change or remove the Deny, versus add an Allow. -->

### 3. Roles over keys

First, an access key in a configuration file is a permanent secret on disk. It works until someone deletes it, it gets copied into backups and images, and sooner or later it ends up in a git commit. The role hands the server temporary credentials through the metadata service, which expire after a few hours and are replaced automatically, so there is nothing long-lived to steal or rotate.

Second, it is the wrong identity. With `usms-dev-01`'s key, the application would act *as a human developer*, with every permission that person has, and the logs would show Pema doing things the server actually did. The role gives the server its own identity with only the S3 permissions it needs, and audit logs name the role, so you can tell who did what.

<!-- two distinct reasons. The credentials are temporary and rotate themselves, so nothing long-lived sits in a file or in git. And the server acts as its own identity with its own narrow permissions, not as a human user, which also makes audit logs show the role, not usms-dev-01. -->

### 4. The S3 ARN trap

`s3:ListBucket` is a bucket-level action, so it needs the bucket ARN, `arn:aws:s3:::usms-student-data`. `s3:GetObject` is an object-level action, so it needs the object ARN, `arn:aws:s3:::usms-student-data/*`. With only the bucket ARN, listing works but every download fails, because no object matches the Resource. The policy needs both values in Resource, ideally in two statements, as I did in `USMSStudentDataReadWrite`.


<!-- s3:ListBucket needs the bucket ARN and s3:GetObject needs the object ARN, …/usms-student-data/*. You need both Resource values. -->

### 5. The Floci illusion

Floci accepts any request from any credentials; it does not evaluate IAM policies at all. A successful command only proves the syntax was valid. An `Action: "*"` policy and a carefully scoped one behave the same here, so success says nothing about whether the policy is correct or safe.

Two ways to gain confidence before real AWS:

1. **Read and review the JSON yourself**, statement by statement: is every action needed, is every Resource as narrow as possible, are the bucket and object ARNs right, is there an explicit Deny where something must never happen? Then use **IAM Access Analyzer policy validation** (`aws accessanalyzer validate-policy`), which flags errors, security warnings and overly broad permissions.
2. **Test it in a real sandbox AWS account**, with the IAM policy simulator and with real calls, including calls that *should fail*. A policy is only proven when the expected denials actually happen.

<!-- Floci doesn't enforce policies, so success only proves the syntax. Two techniques: read and review the JSON (and run the IAM policy simulator on real AWS), and IAM Access Analyzer policy validation, or a sandbox account with deliberate should-fail tests. -->

### 6. The persistence trap

The three reasons, from Step 7:

1. **A directory is not a storage mode.** `--persist` mounts the folder, but `FLOCI_STORAGE_MODE` stays at its default, `memory`. Floci writes almost nothing there, and the users only ever lived in RAM.
2. **Sidecar services use a different setting.** Services that run as child containers need `FLOCI_STORAGE_HOST_PERSISTENT_PATH`, and it must be an absolute path. `~` is not expanded, so `~/floci-data` creates a folder literally named `~`.
3. **Command-line flags are not remembered.** A plain `floci start`, a restart, or Docker Desktop restarting overnight brings the container back on defaults: memory mode and no mount.

The single test that would have caught it in under a minute is Step 14's: create a test user, restart the container, and look the user up again. If it's gone, persistence is broken.

<!-- the handout's Step 7 lists the three causes. A directory is not a storage mode, so --persist leaves the mode at memory. Sidecars need FLOCI_STORAGE_HOST_PERSISTENT_PATH as an absolute path. CLI flags aren't remembered, so any plain restart comes back on defaults. The one-minute test is Step 14's: create a user, restart, look it up. -->

### 7. Configuration as evidence

A committed `docker-compose.yml` is the written proof of how the environment runs: the storage mode (`hybrid`), the exact bind mount, the image version and the published port are all in a file that anyone can read, review and diff. A colleague can check from my repository that persistence is configured correctly, that only port 4566 is exposed, and when any of that changed and why (`git log`), and they can rebuild the identical environment on their own machine. A command I typed once leaves no record. Nobody can review it, it can't be reproduced exactly, and if I mistype a flag one morning, nothing shows it. That is why it is a security and reproducibility property, not a convenience.


<!-- a committed docker-compose.yml shows the storage mode, mount, image and ports, and every change to them has a reviewable history. A command you typed leaves nothing anyone can check. -->