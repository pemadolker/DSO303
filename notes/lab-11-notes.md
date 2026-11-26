# Lab 11 Notes: CI/CD Pipeline with CodePipeline and CodeBuild

Support path: see `outputs/lab-11-support-probe.txt` (`USMS_CICD_SUPPORT_PATH`).

## Steps 1-4
- Ten env files sourced; Lab 04/05 names (cluster, service, container `enrolment-api`, target group, exec role) all present.
- The probe creates `usms-probe-delete-me` with `NO_SOURCE` and `NO_ARTIFACTS` (the smallest legal project) and deletes it. The role ARN in it does not exist on purpose; Floci does not authorise.

## Steps 5-6: Artifact bucket
- Versioning on, tags, public access block on all four settings.
- Proof: two `put-object` calls to `probe/versioning.txt` → two version IDs. Then deleted each by `--version-id`, which really removes them (a plain delete on a versioned bucket only adds a delete marker).

## Steps 7-8: Source and buildspec
- `src/index.html` has `__RELEASE__` and `__BUILT_AT__` placeholders that the build replaces.
- Heredoc rule: `<< 'BUILDSPEC'` (quoted) writes the text exactly, so `$USMS_RELEASE` reaches the file as text and CodeBuild expands it at build time. The inner `<< META` is unquoted because it runs inside the build, where expansion is wanted. Step 21's `<< EOF` is unquoted because I want the values now.
- A grep pattern with `: ` inside YAML has to go in a `- |` block, otherwise YAML reads it as a mapping.
- Your turn: port check `grep -Eq '"port": 80([^0-9]|$)'`. Plain `"port": 80` would also match 8080.

## Steps 9-10: CodeBuild role and project
- Trust: `codebuild.amazonaws.com` with `aws:SourceAccount`. Policy: own log group (both the group ARN and `:*`), the artifact bucket, and an explicit `Deny s3:*` on `usms-student-data`. An explicit Deny wins over any Allow attached later, so builds can never read student records even if someone widens the policy.
- Project template written with an unquoted heredoc; `grep -c '\$'` = 0 proves `${BUILD_ROLE_ARN}` was substituted.
- Build image: Floci pulls the project image by name; `aws/codebuild/standard:7.0` is not public. Tagged `python:3.12-slim` locally as that name. It has bash, python3, sed and coreutils, which is all the buildspec uses. It has no Docker, which matters in Lab 12.

## Steps 11-13: Package, standalone build, logs
- `usms-pack-source.sh` zips the **contents** of the app dir so `buildspec.yml` is at the zip root. If the zip had `app/buildspec.yml` the build would fail with "buildspec not found".
- The standalone build: polled `batch-get-builds` until a terminal status; read phases, log group `/aws/codebuild/usms-enrolment-build`, and the artifact at `build/usms-enrolment-build.zip`.

## Step 14: Local runner
- `usms-buildspec-run.sh` turns the buildspec into one bash script (`set -Eeuo pipefail`) and runs phases in order. It uses PyYAML if installed, otherwise a minimal parser for exactly the subset this course writes. It does not implement `finally` (Exercise 2).
- `labs/lab-11-cicd/app/dist/` added to `.gitignore` (backed up `.gitignore` first).
- Your-turn test: port 8080 → stops in pre_build with my message; back to 80 → passes.

## Steps 15-18: Pipeline
- `usms-codepipeline-role`: trust `codepipeline.amazonaws.com`; policy = artifact store, start/watch **one** project, `iam:PassRole` on `usms-codebuild-role` only with `iam:PassedToService = codebuild.amazonaws.com`.
- Pipeline: Source (S3, `PollForSourceChanges=false`) → SourceOutput → Build (CodeBuild) → BuildOutput.
- After `update-project` to `CODEPIPELINE`, a plain `start-build` fails ("Project cannot be built directly"), which is the evidence the project now belongs to the pipeline. A source override still works.

## Step 19: r4, then r5
- r4: execution polled to completion; newest BuildOutput zip has `build-metadata.json` with release r4.
- Your turn r5: three uploads by then (r3, r4, r5) plus whatever later steps add. Source versions = uploads. BuildOutput objects = executions that finished Build. They differ because an upload does not start anything with polling off, and a failed build leaves no artifact. (The exact counts are in the r5 screenshot and in the report.)

## Step 20: Deliberate failure
- Container renamed to `enrolment-api-v2` → Build stage Failed → `batch-get-builds` phases → `PRE_BUILD FAILED` → the container check. Fixed, local runner passes, pipeline re-run.

## Step 21 / Section 8
- `configs/lab-11.env`: 26 exports.
- `verify-lab-11.sh` and `lab-11-cleanup.sh` (not run).

---

## Review questions

### 1. Source and Build succeed, application unchanged
First explanation, `artifacts.base-directory`: if it is missing or wrong, the artifact contains `dist/index.html` (or the whole source tree) instead of `index.html` at the root, so whatever consumes it never finds the new file at the path it expects and keeps serving the old one. One command shows it: download the newest BuildOutput zip and list it (`python3 -m zipfile -l`); if the names start with `dist/`, that is the cause. Second explanation, the source zip's layout: if the zip was made from the parent folder, its root is `app/`, so the build ran against a buildspec it found elsewhere or an old copy, and my change never entered it. Listing the source zip the same way shows `app/buildspec.yml` instead of `buildspec.yml`. The first is a problem in what leaves the build, the second in what enters it.

### 2. Why CodePipeline requires versioning on an S3 source
An execution has to record exactly which input it ran on, because every later stage, retry and audit refers back to it. With versioning, "the source" for an execution is a bucket, a key and a version ID, which can never change. Without versioning the key is only a name for whatever was uploaded last; if someone uploads again while the pipeline is running, the Build stage might read different bytes from the ones the Source stage saw, and afterwards nobody could say what was built. Versioning turns a mutable name into an immutable reference, which is what an execution record needs.

### 3. iam:PassRole for the sceptic
The objection is fair: creating a project and choosing its role feel like one action. But the role decides what the project can do when it runs, and that can be far more than I can do myself. If I can create a project and attach any role, I can attach an administrator role, put `aws iam attach-user-policy ...` in the buildspec, and CodeBuild runs it as administrator for me. That is privilege escalation through a service. `iam:PassRole` separates "may create a project" from "may give this project this identity", and the `iam:PassedToService` condition also limits which service the role can be handed to. In this lab the pipeline can pass exactly one role to exactly one service, so even a compromised pipeline cannot make anything more powerful than the build role.

### 4. Two roles versus one
For two roles: each role only has what its job needs. The build role can read source and write artifacts and logs but cannot start pipelines or pass roles; the pipeline role can start one build but cannot run arbitrary commands. A compromised buildspec (the most exposed part, because it is code from the repository) only gets the build role. Audit is clearer too, because CloudTrail shows which identity did what. The strongest argument against: the two policies overlap heavily (both need the artifact bucket), two roles is twice the policies to review and keep in sync, and in a small team a single mistake in either one breaks the pipeline in ways that are harder to debug; plus, in this design, the pipeline can already start the build that runs as the build role, so the separation does not stop someone who controls the pipeline from running build code. It limits blast radius for the build, not for the pipeline.

### 5. Three heredoc forms
`<< 'BUILDSPEC'` (quoted): if it were unquoted, bash would expand `$USMS_RELEASE`, `$(date ...)` and `${CODEBUILD_BUILD_ID:-local}` while writing the file, on my laptop, where they are empty or wrong. The buildspec would then contain literal blank values and a fixed date, and every build would stamp the same wrong release. `<< META` (unquoted, inside the build): if it were quoted, `build-metadata.json` would contain the text `$USMS_RELEASE` instead of `r4`. `<< EOF` in Step 21 (unquoted): if it were quoted, `configs/lab-11.env` would contain `$(aws s3api ...)` commands instead of values, which would re-run on every `source`. None of these produce an error message, because in every case bash or the build did exactly what it was told; the file is just different from what was meant. The only way to catch it is to read the output file.

### 6. Removing pre_build validation
They are right when the check really is duplicated by something that runs before any cost or any traffic, for example if the deploy stage validates the container name and refuses to deploy, and the build is cheap. They are expensively wrong when the build is long or the deploy check comes late: a wrong container name passes the build, produces an image and an artifact, and then fails in Deploy, possibly after a partial rollout, which wastes build minutes, needs a rollback, and points the investigation at Deploy when the mistake is in the source. Failing fast in `pre_build` costs seconds and names the actual cause. Lab 12 Step 16's "Your turn" is the same lesson: errors surface in the stage after the one where they were made.

### 7. Proving r4 was built from the repository on a date
Evidence chain: the S3 object version of `source/usms-enrolment-src.zip` with its `LastModified` time and version ID; the pipeline execution that consumed it (`list-pipeline-executions` shows the source revision); the CodeBuild build ID for that execution and its log; and the BuildOutput artifact whose `build-metadata.json` contains `release: r4`, the build ID and the source version. The weakest link is the first: the zip in S3 is only claimed to be "what was in the repository". It was made on my laptop by `usms-pack-source.sh` from a working directory that may have had uncommitted changes, and nothing records which Git commit it came from. Recording the commit hash in the zip (or using a Git-based source) would close that gap.
