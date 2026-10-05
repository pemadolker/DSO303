# Lab 04 Notes - Amazon ECS on Fargate

## Step 3 support path: **Path B - ECS only**

The Step 3 probe (screenshot `step3.png`) showed:

| Area | Result |
|---|---|
| `ecs list-clusters`, `register-task-definition` | SUPPORTED |
| `ecs describe-services` (against a cluster that does not exist) | "not available" |
| All three `application-autoscaling` calls | not available |
| CloudWatch (`put-metric-data`, `describe-alarms`) and Logs | SUPPORTED |

`describe-services` failed in the probe only because the probe names a cluster called `probe` that does not exist. ECS itself works: `create-cluster`, `register-task-definition`, `create-service` and `describe-services` all succeeded later. The real limitation is that **Application Auto Scaling is absent from this Floci build**. Every step in Lab 04 is ECS-only and unaffected, but this must be carried into Lab 06, which will need its documented fallback.

## Observed results vs limitations (what actually happened)

**Observed**
- Cluster `usms-ecs-cluster` ACTIVE; log group `/usms/ecs/enrolment` with 7-day retention.
- `usms-ecs-exec-role` (with `USMSECSTaskExecution`) and `usms-ecs-task-role` (with Lab 01's `USMSStudentDataReadWrite`) created; exec role trusts `ecs-tasks.amazonaws.com`.
- `usms-enrolment` task definition registered, Fargate, awsvpc, 256 CPU / 512 MiB (revision 1), later revision 2 at 256 / 1024 MiB.
- `usms-enrolment-svc`: ACTIVE, FARGATE, two private subnets, `assignPublicIp` DISABLED, desired 2, running 2 (after initially showing running 0).
- `update-service --desired-count 3` then back to `2` both accepted.
- `configs/lab-04.env` has 17 exports, no empty values.
- `verify-lab-04.sh`: PASS=36 FAIL=2.

**Floci limitations (differs from real AWS)**
1. `containerInsights` was requested on `create-cluster` but `describe-clusters --include SETTINGS` returned `Settings: null`. Real AWS would store it and publish CPU/memory to `AWS/ECS`. Lab 06's target tracking would have no metric to read.
2. The security group rule created with `UserIdGroupPairs` came back with `FromGroup: null` and `FromCIDR: null`. The rule exists on port 80 but the source-group reference was not retained.
3. `aws ecs wait services-stable` failed with `In function length(), invalid type for value: None`. I checked the state manually with `describe-services` instead.
4. The service `events` list returned `null`, so the "service narrates what it did" part of the Step 11 "Your turn" task could not be shown. Real AWS would list each scaling event.
5. After `update-service --desired-count 3`, `runningCount` stayed 2 in the immediate response. Real Fargate would start a third task over 20-60 seconds.
6. `assume-role` ignored my session name: the ARN ended in `.../usms-developer-role/floci-session`, not `lab04-ecs-build`. The role assumption itself worked.
7. Task containers cannot fetch role credentials (documented in the lab); I did not test this.
8. Application Auto Scaling is unavailable (Path B above).

**Findings I want on record**
- At Step 2, `verify-lab-02.sh` reported PASS=31 FAIL=2 and `verify-lab-03.sh` PASS=32 FAIL=4 (`image.png`). The lab expects FAIL=0. These come from earlier labs and I did not repair them in this lab. They are already documented, check by check, in my Lab 02 and Lab 03 notes, so I do not repeat them here. They are the same known Floci limitations, unchanged by Lab 04.
- In the Step 9 verify output for revision 1, `Exec` printed as an empty string and `LogGroup` as `null`, while `Task` showed the task role ARN. The "roles are different" verifier check still passed, because an empty string is not equal to an ARN. So that check cannot tell "different" from "missing". Revision 2 set both roles explicitly. *[Confirm in your own terminal whether revision 2 now shows both ARNs and the log group.]*
- Final verifier: **PASS=36 FAIL=2**, both documented as benign:
  1. `usms-enrolment-sg is sourced from usms-app-sg` fails because of limitation 2.
  2. `no secret is tracked by git` fails because the check `git ls-files | grep '^outputs/'` also matches the intentionally tracked `outputs/.gitkeep`. This is a flaw in the check, not a leaked file.

---

## Review questions

**1. "I put auto scaling on the task definition."**
This is wrong in three ways. Auto scaling is not attached to the task definition at all. In Lab 06 it will be attached to the *service*, through a scalable target whose resource ID is `service/usms-ecs-cluster/usms-enrolment-svc`. What it modifies is one number, the service's `desiredCount`. The *service* does the real work, because its job is to keep `runningCount` equal to `desiredCount`, starting or stopping tasks until they match. The task definition is an immutable blueprint and cannot be scaled. A consequence is that ECS itself knows nothing about the scalable target: `describe-services` shows only a desired count, with no sign of who changed it. To see why it moved you must look at Application Auto Scaling's own scaling activities.

**2. The same policy on EC2 and on Fargate.**
`USMSStudentDataReadWrite` was written in Lab 01 for a bucket that did not exist. In Lab 03 it reached `usms-web-01` through `usms-ec2-app-role` and the instance profile. At runtime the instance asks the instance metadata service for temporary credentials for the role in its profile. In this lab it reaches the container through `taskRoleArn` and `usms-ecs-task-role`. At runtime, on real AWS, the task gets temporary credentials from a link-local endpoint whose address is injected as `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, and the SDK finds them automatically. Neither needs a key on disk because both mechanisms hand out short-lived credentials that rotate on their own, so there is nothing to store or leak. Both chains have the same shape: compute, role, policy, bucket ARN. The moment a bucket finally exists at `arn:aws:s3:::usms-student-data`, both start working at once, and neither the policy nor either role has to change, because the permission was always written against the ARN and not against the bucket's existence. (In Floci the container-credentials endpoint is not served, so this part is reasoning, not something I observed.)

**3. Execution role vs task role.**
- If the **execution role** is missing or wrong, the task never starts and `stoppedReason` mentions the image pull or the logs.
- If the **task role** is missing or wrong, the task starts fine and then the application gets `AccessDenied` at runtime.

Both share the same trust policy because the trust policy only says *who may assume the role*, and in both cases that is the ECS tasks service, `ecs-tasks.amazonaws.com`. The difference is not who assumes them but when and for what: the execution role is used by the infrastructure before the container exists, and the task role by the application code inside it. The permissions policies are what differ.

**4. Why a group reference and not a CIDR.**
Even with a fixed task count, naming `usms-app-sg` is correct because it expresses the real requirement, "only the web tier may call this", rather than a guess about addresses. If `usms-web-01` is replaced and gets a new IP, a group-based rule keeps working while a CIDR rule would silently break or be too wide. It also cannot admit other things in the same subnet. Once Lab 06 lets the task count change, it becomes close to mandatory, because tasks are created and destroyed on their own, each with a new network interface and address in either subnet, and nobody could keep a CIDR rule up to date. In my Floci run the reference itself was not retained (limitation 2), but the design reasoning stands.

**5. What Fargate removes and does not remove.**
Fargate removes the servers: no instances to launch, patch, size or scale, and no AMI, since I only state CPU and memory per task and pay per task. It does not remove networking or IAM. A Fargate task in awsvpc mode still gets its own network interface in my subnet, with my security group, and follows Lab 02's route tables. That is why the service sat in the private subnets and why the image pull depends on `usms-private-rt` reaching `usms-nat` (and the S3 endpoint for layers). It still needs its own execution role and task role too.

**6. Memory mode vs hybrid mode.**
A command that looks identical in both modes is anything run in a single session, such as `aws ecs describe-services` right after creating it, or `aws sts get-caller-identity` (the root ARN is a constant). Those only prove Floci is answering now. A command that would differ is one run after a restart: `list-task-definitions` or `describe-clusters` after `floci-down.sh` and `floci-up.sh` would still show `usms-enrolment:1` and the cluster in hybrid mode, and be empty in memory mode. The other is the verifier's own check that reads `FLOCI_STORAGE_MODE` from the container with `docker container inspect`, which reads the configuration directly rather than inferring it. I did not do a restart in this lab, so this is reasoning, not an observation.