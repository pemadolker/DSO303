# Lab 04 Notes - Amazon ECS on Fargate

## Step 3 support path: **Path B - ECS only**

ECS, CloudWatch and CloudWatch Logs answered the Step 3 probe. All three `application-autoscaling` calls were "not available". (`describe-services` also showed "not available", but only because the probe names a cluster that does not exist.) Every step in Lab 04 is ECS-only and unaffected. Lab 06 will need its documented fallback.

## Floci limitations observed

1. `containerInsights` was requested but `describe-clusters` returned `Settings: null`. Lab 06's CPU metric would not exist.
2. The security group rule's source group was not retained (`UserIdGroupPairs` came back empty).
3. `aws ecs wait services-stable` failed with a JMESPath `None` error, so I checked state manually.
4. The service `events` list returned `null`.
5. After `--desired-count 3`, `runningCount` stayed 2 (real Fargate would start a task in 20-60 seconds).
6. `assume-role` ignored my session name (`floci-session`).
7. Application Auto Scaling is unavailable.
8. `logConfiguration` is accepted but not returned: `describe-task-definition` shows `null` for it on both revisions, although the template contains the correct `awslogs-group`.

## Other findings

- Step 2 verifiers for Labs 02 and 03 did not reach FAIL=0. These are documented in my Lab 02 and Lab 03 notes and are unchanged by this lab.
- Step 9, revision 1 was registered with an empty `executionRoleArn`: `$EXEC_ROLE_ARN` was empty when I wrote the template, and my own template still shows `"executionRoleArn": ""`. The `grep -c '\$'` check printed 0 and the "roles are DIFFERENT" verifier check passed, because neither can detect an empty value. On real AWS the task could not have pulled its image or opened its log stream. Revision 2 sets the role explicitly and is the revision the service runs. Lesson: check the registered value, not just that the command succeeded.
- Final verifier: **PASS=36 FAIL=2**, both documented as benign: the missing security group source (limitation 2), and the `outputs/.gitkeep` match in the git check.

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