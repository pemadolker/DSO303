# Lab 12 Notes: Deploying to Amazon ECS from the Pipeline

Deploy path: A, CodeDeploy answered yes (`outputs/lab-12-deploy-probe.txt`). Observed vs recorded: ECR is real (push, pull by digest, immutability enforced); CodeBuild is recorded only (Lab 11), so images were pushed by the local runner; the pipeline's Deploy stage failed both runs, so the service only moved by hand.

## Steps 1-3
- Lab 11's readiness file says there is no BuildOutput object in Floci (the artifact was rebuilt locally from the pipeline's source version) and that `imagedefinitions.json` is an array at the artifact root.
- Probe: Docker reachable, ECR answers and creates/deletes a probe repo, ECS answers; CodeDeploy result recorded.

## Step 4: ECR port range
- My `docker-compose.yml` had no commented range, so I added `- "5100-5104:5100-5104"`. Backups: `docker-compose.yml.bak-<time>` and `outputs/backup-lab-12/`.
- `floci-up.sh` failed: `Bind for 127.0.0.1:5100 failed: port is already allocated`. `docker ps` showed `floci-aws-floci-course-ecr-registry` on `127.0.0.1:5100->5000`, Floci 2.2's own registry container, and `ss -ltnp` showed docker-proxy on 5100. So the range is not needed on the main container; I commented the line out again and Floci started. ECS service still ACTIVE (hybrid storage).

## Steps 5-9: Registry and image
- `--image-tag-mutability MUTABLE` (the default, kept so the lab can retag), `scanOnPush=true`, `AES256`.
- Registry host = everything before the first `/` of the repository URI (`${ECR_URI%%/*}`).
- `docker login --password-stdin` from a pipe: the token never appears in `ps` or history. Docker stores a reference in `~/.docker/config.json`.
- First push failed: `server gave HTTP response to HTTPS client`. Docker only trusts plain HTTP for `localhost`/`127.0.0.1`, not `000000000000.dkr.ecr.us-east-1.localhost:4566`. Added that one host to `insecure-registries` in `/etc/docker/daemon.json` (kept my `dns` entry), restarted Docker and Floci, pushed again. Real ECR is HTTPS.
- Dockerfile copies `dist/` (built output) into `nginx:1.27-alpine`. `.dockerignore` keeps the source, tests and buildspec out of the image.
- r6: built, tagged with the full repository URI, pushed: `sha256:75c3fcbe...`. Digest recorded with a timestamp in `outputs/lab-12-image-digest.txt`. Deleted the local copies and pulled `ECR_URI@sha256:...` back. `describe-images` size = 0 (Floci does not compute it).

## Steps 10-11: Task definition
- describe → remove the eight read-only fields (`taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`, `deregisteredAt`) → change the image of `enrolment-api` → register. `grep -c '\$'` = 0.
- Deployed the returned ARN (not `:3`, my family has more revisions). `usms-ecs-watch.sh` polls deployments until one PRIMARY with running == desired, or gives up.

## Step 12: CodeBuild policy v2
- Adds `ecr:GetAuthorizationToken` on `*` (it is account-level, cannot be scoped) and push/pull actions on `repository/usms-enrolment` only. Explicit Deny on student data kept. `--set-as-default`; v1 still listed.
- **Your turn - my draft vs Step 15.** My draft (`notes/lab-12-my-pipeline-policy.json`) has five statements. Three match Step 15 exactly (artifact store, start the one build, pass the build role). Two differ:
  1. I put `DescribeTaskDefinition` and `RegisterTaskDefinition` in the same statement as the service actions and scoped them to `task-definition/usms-enrolment:*`. The handout puts them in a separate statement on `Resource: "*"` and adds `ListTaskDefinitions`. The reason is that `RegisterTaskDefinition` (and the list/describe calls) do not support resource-level permissions in IAM, so my scoped ARN would make the deploy action fail with AccessDenied on real AWS. That is why the handout splits them.
  2. My PassRole statement is the same idea as the handout's, just a different Sid. So in practice only one difference matters, and it is the one about which actions accept a resource ARN.

## Steps 13-14: Build project and buildspec
- `update-project --cli-input-json` replaces the whole `environment` block, so all four variables are in the template. `source.type` stays `CODEPIPELINE` because `source` was not in the update.
- New buildspec: `pre_build` logs Docker in if a daemon is reachable; `build` makes `dist/`, builds and pushes `${IMAGE_REPO_URI}:$USMS_RELEASE` if Docker is there, and always writes `imagedefinitions.json` from `config/service.json` with Python (no `: ` YAML problem, name not typed twice). The Lab 11 version is kept as `buildspec.yml.lab08a`.
- The 8th smoke assertion was already there from my Lab 11 Exercise 5, so the Step 14 Python said "already present".
- Local run with `IMAGE_REPO_URI=$ECR_URI` built and pushed the image (my laptop has Docker).

## Step 15: Pipeline policy v2
- Adds `ecs:DescribeServices` + `UpdateService` on one service ARN, task definition calls on `*`, and a second scoped PassRole: the two ECS roles, only to `ecs-tasks.amazonaws.com`.

## Step 16: Deploy stage
- `get-pipeline` → append Deploy (provider ECS, cluster, service, `FileName: imagedefinitions.json`, input `BuildOutput`) → `update-pipeline` with the whole document wrapped as `{"pipeline": ...}`.
- **Your turn - Deploy reading SourceOutput.** The ECS action looks for `imagedefinitions.json` at the root of its input artifact. SourceOutput is the source zip: its root has `buildspec.yml`, `VERSION`, `src/`, `config/`, `tests/`, `Dockerfile`, but no `imagedefinitions.json` (that file only exists in `dist/` after a build). So Build would succeed, and **Deploy** would fail saying the file was not found in the input artifact. The mistake is in the Deploy action's configuration, but the symptom looks like a build problem ("the build did not produce the file") and sends you to the wrong place.

## Step 17: End to end
- Floci does not run builds, so I pushed r7 from my machine with the local runner (`sha256:cb6cc079...`) before starting the pipeline.
- Execution: Source Succeeded, Build Succeeded, **Deploy Failed**. Service before `:3`, after `:3`, image still `:r6` (`outputs/lab-12-deploy-evidence.txt`). Floci gives no error (`errorDetails` empty in `get-pipeline-state`). Most likely reason: Deploy reads `imagedefinitions.json` from BuildOutput, and Floci's Build stage writes no BuildOutput (Lab 11). On real AWS: new revision `:4` naming `:r7`, service rolled to it.

## Step 18: Rollback drill
- r8 uploaded; the registry has no r8. The pipeline ran and Deploy **Failed** again (same reason), so no `:r8` revision was registered and the service stayed on `:3`. On real AWS Deploy would succeed, the service would point at a revision naming a missing tag, tasks would fail with `CannotPullContainerError` and the circuit breaker would roll back.
- Ran the rollback anyway: `update-service --task-definition usms-enrolment:3` (a no-op here, same revision). Source set back to r7 so the next run does not redeploy r8.
- **Your turn - the bad revision** (answered for real AWS, where it would exist; on Floci none was registered). I would leave the bad revision registered and not deregister it. Deregistering only marks it INACTIVE (it cannot be deleted from history anyway), and keeping it ACTIVE keeps the evidence of the failed release next to the good ones, which is useful in a post-incident review. The risk is that someone later deploys "the latest revision" and gets the broken one. How someone would notice in six months without being told: an audit that, for every ACTIVE revision, checks its image tag exists in ECR (`describe-images --image-ids imageTag=...`) would flag it immediately. If I wanted to remove the risk instead, `aws ecs deregister-task-definition` is the one command, and it is reversible in the sense that it deletes nothing.

## Step 19: Blue/green on paper
- `appspec.yaml` with `<TASK_DEFINITION>` (a placeholder CodeDeploy fills in itself), container `enrolment-api:80`, five lifecycle hooks; `AfterAllowTestTraffic` is the one that tests green on the test listener before production traffic moves.
- Deployment group: `ECSLinear10PercentEvery1Minutes`, terminate blue after 5 minutes, auto-rollback on failure and on alarm, two target groups, prod and test listeners (placeholders until Exercise 3).
- Switching the service's deployment controller to `CODE_DEPLOY` is not done: it cannot be changed on an existing service and would break the ECS deploy action.

## Step 20-21
- `configs/lab-12.env`; `USMS_ROLLBACK_REVISION` from the captured good revision.
- `.gitignore` gets `docker-compose.yml.bak-*` (backed up first). Committed with the Lab 12 message.

---

## Review questions

### 1. Changes that cannot travel through this pipeline
The ECS deploy action only swaps the image. (a) A change to CPU or memory: the action copies the current revision's sizes, so it would never change them. I would register a revision with the new sizes by hand (Step 10's method) or, better, manage the task definition as code (a template the build fills in, or CloudFormation) so it changes through review. (b) A new environment variable or secret: same reason; again a new revision from a template, and secrets through Secrets Manager references in the task definition. (c) A new port or a change to the load balancer, health check or desired count: these are service or target group settings, not image settings; I would change them with `update-service` / `modify-target-group` in a reviewed change, or in an infrastructure-as-code stack, separately from the release.

### 2. GetAuthorizationToken on * versus RegisterTaskDefinition on *
They look the same in the policy but are not the same kind of exception. `ecr:GetAuthorizationToken` returns a token for the registry, which is account-wide by design; the token by itself lets you do nothing, and every push or pull is still checked against the repository-scoped actions in the next statement. So `*` here costs nothing. `ecs:RegisterTaskDefinition` on `*` is different: the action creates a document that, once deployed, decides what code runs with which role. On the other side, both are forced by the IAM service (neither supports a resource ARN), and the danger of `RegisterTaskDefinition` is bounded by `iam:PassRole` and by `UpdateService` being scoped to one service. My answer: not the same kind. The first is harmless because the real control is elsewhere; the second is a real grant whose control is only partly elsewhere (Exercise 4 shows what is left).

### 3. Digest versus tag
For the sceptic: a tag is a pointer that anyone with push rights can move. If the task definition says `:r7`, the bytes that run depend on what `r7` pointed at when the task started, so two tasks of the same revision can run different code, and a rollback to "r7" may not be the r7 that worked. A digest is the hash of the image itself: the same digest is the same bytes, always, so a revision pinned by digest is reproducible and an auditor can prove what ran. The strongest case against pinning: security patches. If the base image gets a fix and the tag is rebuilt, a digest-pinned task definition will never pick it up; every patch needs a new revision and a deployment, so pinning makes "we patched the image" untrue until someone redeploys. It also makes task definitions unreadable for humans. The usual answer is: build and tag immutably, deploy by digest, and automate the rebuild-and-redeploy.

### 4. A failure the circuit breaker does not catch
The circuit breaker counts tasks that fail to start or fail their health checks during a deployment. It does not catch an application that starts, passes a shallow health check (`/` returns 200), and then returns wrong data or errors on real requests, for example an enrolment page that loads but whose form posts fail. The deployment completes and the breaker is done. What catches it is a signal tied to user-visible behaviour: CloudWatch alarms on the load balancer's 5xx rate or latency attached to the deployment (CodeDeploy's `DEPLOYMENT_STOP_ON_ALARM`, or ECS deployment alarms), and blue/green with a smoke test on the test listener (`AfterAllowTestTraffic`) before production traffic moves.

### 5. Replace-only APIs
`update-pipeline`, `put-bucket-notification-configuration`, `update-assume-role-policy` and `put-bucket-policy` all store one document that describes the whole configuration of one thing, and the meaning of the document depends on all of its parts together (the order of stages, the set of notification targets, the set of trusted principals). Replacing the whole document is simple and makes the result predictable: what you send is exactly what is stored, and the call is idempotent. A merge-based `update-pipeline` would have to decide: is a stage missing from my document a stage to delete or one to keep? Are stages matched by name or position? If two actions conflict, whose wins? How do you change the order of stages, or rename one? Each of those needs its own rule, and a wrong guess silently changes a pipeline. Replace-only pushes that problem to the client, where get → modify → update makes it explicit.

### 6. Why create-policy-version is not default by default
Because publishing a version and activating it are different decisions. The workflow it protects is: write the new version, review it (or run the IAM policy simulator against it, or let someone else approve it), and only then make it the default; and if something breaks, set the default back to the previous version in one call. If every new version were active immediately, a typo in a policy attached to production roles would take effect the moment it was uploaded. Keeping up to five versions with one marked default gives staged rollout and instant rollback for permissions, the same way an alias does for Lambda code.

### 7. "Running code that was never reviewed"
`outputs/lab-12-deploy-evidence.txt` helps partly: it shows which task definition revision and which image tag the service moved to, and when. `outputs/lab-12-image-digest.txt` helps more: it records the digest each tag had at push time, so I can check whether the running tag still points at the same bytes. The pipeline execution history alone does not settle it: it shows that a run happened and which S3 source version it used, but nothing links that source to a reviewed change. To settle it in one command I would have needed to record, at build time, the Git commit hash of the reviewed merge inside the image (an image label or `build-metadata.json`) and the image digest inside the task definition. Then `docker inspect` on the running image, or `describe-task-definition`, would name the exact reviewed commit.
