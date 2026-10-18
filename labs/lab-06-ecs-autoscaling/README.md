# AWS Practical Laboratory 6 Report

**Student Name:** Pema Dolker
**Module:** DSO303
**Practical:** Lab 06 - Implementing Auto Scaling for an ECS-Based Application
**Environment:** Floci 2.2.0 (local AWS API emulator, Docker Compose, hybrid storage), account 000000000000, us-east-1

**Support path:** A for alarms and step scaling. The alarm I created went into ALARM by itself and the step policy really changed the desired count of the service. Scheduled actions are not supported on this build, and raising the minimum capacity is stored but not applied.

Step by step notes are in `notes/lab-06-notes.md` and the five exercises are in `labs/lab-06-ecs-autoscaling/exercises.md`.

> Labels used below:
> **Observed** = I ran it and saw it.
> **Floci limitation** = behaved differently from real AWS.

## 1. Aim / Objective

The aim of this practical is to make the USMS enrolment service from Lab 04 and Lab 05 scale by itself. I registered the service as a scalable target with a minimum of 2 and a maximum of 10 tasks, added two target tracking policies (CPU and requests per target), added a step scaling policy that is driven by my own CloudWatch alarm on a custom metric, and tried two scheduled actions. Then I fired the alarm to prove that something other than me changed the number of tasks, practised suspending and resuming scaling, and checked that the whole configuration survives a restart of Floci.

## 2. Introduction

Application Auto Scaling is the AWS service that changes the capacity of other services for you. For an ECS service the only thing it changes is one number, the desired count. It does not start containers, it does not register them in the load balancer and it does not touch the task definition. ECS and the load balancer from the earlier labs still do all of that, they just react to the new number.

The main parts I used in this lab:

- **Scalable target** - tells Application Auto Scaling which number it may change (here `ecs:service:DesiredCount` on `service/usms-ecs-cluster/usms-enrolment-svc`) and the lower and upper limit.
- **Target tracking policy** - you give a target value, for example 50% CPU, and AWS keeps the metric near that value. AWS creates and manages two CloudWatch alarms for it, one for scaling out and one for scaling in.
- **Step scaling policy** - you write your own alarm and say how many tasks to add depending on how far the metric is past the threshold. It is for rules that target tracking cannot express.
- **Scheduled action** - changes the minimum and maximum at a fixed time. It is the only kind of scaling that can be early, before the load arrives.
- **Suspended state** - three switches that stop scale in, scale out or scheduled scaling without deleting any policy.
- **Service-linked role** - the role AWS uses to call `ecs:UpdateService` for you.

This matters in cloud computing because traffic is not flat. Paying for 10 tasks all day when 2 is enough most of the time is a waste, and having only 2 when enrolment opens is an outage.

## 3. Use Case

- A student portal like USMS that is quiet most of the semester but gets a big rush when enrolment opens or results are published.
- Any web API behind a load balancer where the number of requests per task is a good sign of how busy the service is.
- Background workers that should grow with the length of a queue, like the enrolment queue depth metric in this lab.
- Services with a known daily pattern, for example more capacity during office hours and less at night, using scheduled actions.

## 4. System Architecture / Design

The only new thing in this lab is the control loop on the right. Everything else was built in Labs 02 to 05 and was not changed.

```text
 students -> usms-enrolment-alb (public subnets) -> usms-enrolment-tg -> tasks in the private subnets
                                                                            ^
                                                   ECS starts / stops tasks |
                                                                            |
 usms-enrolment-svc  desiredCount  <---- writes ONE number ---- Application Auto Scaling
                                                                 scalable target  min 2  max 10
                                                                  - CPU target tracking 50
                                                                  - requests target tracking 1000
                                                                  - step scaling +1 / +3
                                                                        ^
 put-metric-data -> USMS/Enrolment EnrolmentQueueDepth -> alarm usms-enrolment-queue-high (>= 100)
```

Data flow when the queue gets long: the metric goes above 100, the alarm goes to ALARM, the alarm calls the step policy, the policy writes a new desired count (clamped between 2 and 10), ECS starts the extra tasks in the private subnets and the service registers them in the target group.

## 5. Implementation Procedure

1. **Steps 1 to 3** - started Floci, sourced the six env files, recorded the Lab 05 verification as a baseline and ran the support probe. Every call answered except `describe-scheduled-actions`.
2. **Step 4** - created the service-linked role for ECS auto scaling and read it back.
3. **Step 5** - built the resource ID from the service ARN and registered the scalable target with min 2 and max 10.
4. **Step 6** - changed the bounds by registering again, tried raising the minimum to 5 and put it back to 2.
5. **Steps 7 and 8** - created the CPU target tracking policy (target 50, scale out cooldown 60 s, scale in cooldown 300 s) and looked at the two alarms AWS made for it.
6. **Step 9** - built the ResourceLabel from the load balancer and target group ARNs and created the requests per target policy (target 1000).
7. **Step 10** - created the step scaling policy (+1 for a breach of 0 to 100, +3 above that) and my own alarm `usms-enrolment-queue-high` on the custom metric, with the policy as its action.
8. **Step 11** - tried the two weekday scheduled actions and the one-off "results night" action.
9. **Step 12** - pushed the queue metric to 260, watched the alarm, read back the desired count and the scaling activities, saved the proof file and returned to the baseline.
10. **Step 13** - suspended scale in only, checked the policies were untouched, then resumed.
11. **Step 14** - restarted Floci and compared the configuration before and after.
12. **Step 15** - traced the whole path from the metric to a new task in the target group.
13. **Steps 16 and 17** - wrote `configs/lab-06.env`, checked the cleanup hint strings and committed.
14. **Section 8** - built and ran `verify-lab-06.sh`, and built (but did not run) `lab-06-cleanup.sh`.

## 6. Results and Evidence

### 6.1 CLI Output

**Steps 1 to 3 - environment and probe**

![Step 1](../../screenshots/lab6/step1.png)
![Step 2](../../screenshots/lab6/step2.png)
![Step 3](../../screenshots/lab6/step3.png)

**Observed:** all Application Auto Scaling, CloudWatch, IAM and ECS calls answered except `describe-scheduled-actions`, which was not available.

**Step 4 - service-linked role**

![Step 4](../../screenshots/lab6/step4.png)

**Observed:** the role exists with the path `/aws-service-role/ecs.application-autoscaling.amazonaws.com/` and the right trust principal. **Floci limitation:** its name is `AWSServiceRoleForEcsApplicationAutoscaling` instead of AWS's `AWSServiceRoleForApplicationAutoScaling_ECSService`, and no managed policy is attached.

**Step 5 - scalable target**

![Step 5](../../screenshots/lab6/step5.png)

**Observed:** one scalable target, resource ID `service/usms-ecs-cluster/usms-enrolment-svc` (three segments), dimension `ecs:service:DesiredCount`, min 2, max 10, all suspension switches false. The RoleARN was filled in by AWS, but it points at the AWS role name, not the one Floci created.

**Step 6 - bounds**

![Step 6](../../screenshots/lab6/step6.png)
![Step 6 your turn](../../screenshots/lab6/step6-yourturn.png)

**Observed:** the minimum of 5 was stored but the desired count stayed at 2 and no scaling activity was recorded. **Floci limitation:** on real AWS registering a higher floor raises the desired count straight away. I put the minimum back to 2.

**Steps 7 and 8 - CPU target tracking and its alarms**

![Step 7](../../screenshots/lab6/step7.png)
![Step 8](../../screenshots/lab6/step8.png)

**Observed:** policy created with target 50.0, out 60, in 300, DisableScaleIn false. Two managed alarms were created, AlarmHigh with 3 periods of 60 s and AlarmLow with 15 periods of 60 s. **Floci limitation:** the alarm's metric name shows the predefined type name instead of `CPUUtilization`, and AlarmLow uses the same threshold of 50.

**Step 9 - requests per target**

![Step 9](../../screenshots/lab6/step9.png)

**Observed:** ResourceLabel validated at six segments, starting with `app` and with `targetgroup` fourth, and the policy created with target 1000 and two more managed alarms (four in total).

**Step 10 - step scaling and my own alarm**

![Step 10](../../screenshots/lab6/step10.png)
![Step 10 read back](../../screenshots/lab6/step10-2.png)

**Observed:** StepScaling, ChangeInCapacity, Average, cooldown 60, two steps with the top one open-ended. The alarm watches `USMS/Enrolment EnrolmentQueueDepth`, fires at 100 or more and names the step policy ARN in its actions. **Floci limitation:** the policy's own Alarms list stays empty. On real AWS it would list the alarm.

**Step 11 - scheduled actions**

![Step 11](../../screenshots/lab6/step11.png)
![Step 11 your turn](../../screenshots/lab6/step11-2.png)

**Floci limitation:** `put-scheduled-action` and `describe-scheduled-actions` both return UnsupportedOperation, so neither weekday action nor the results night action could be created. The floor stayed at 2.

**Step 12 - firing the alarm (the most important step)**

![Before](../../screenshots/lab6/step12-1.png)
![Metric and alarm](../../screenshots/lab6/step12-2.png)
![Scaling activities](../../screenshots/lab6/step12-3.png)
![Proof chain](../../screenshots/lab6/step12-4.png)
![Back to baseline](../../screenshots/lab6/step12-5.png)
![Baseline holds](../../screenshots/lab6/step12-6.png)

**Observed:** I predicted 2 to 5. After pushing 260 the alarm went to ALARM on its own (no `set-alarm-state` needed) and the desired count went 2, 5, 8, 10. Each scaling activity has the cause "monitor alarm usms-enrolment-queue-high in state ALARM triggered policy usms-enrolment-queue-step-out", which is the proof that the alarm and the policy changed the number, not me. The last step would have made 11 and was capped at the maximum of 10. The proof file with the six linked blocks was also saved. I then pushed the metric down first and only after that set the count back to 2, and it stayed at 2 with the alarm OK.

**Floci limitation:** the policy was called again every 10 seconds while the alarm stayed in ALARM, so the 60 s cooldown was not respected. On real AWS I would expect 2 to 5 and then a pause. Running tasks also jumped to 10 immediately, because Floci does not model the 20 to 60 seconds a Fargate task needs to start.

**Step 13 - suspend and resume**

![Suspended](../../screenshots/lab6/step13-1.png)
![Policies untouched](../../screenshots/lab6/step13-2.png)
![Resumed](../../screenshots/lab6/step13-3.png)

**Observed:** only DynamicScalingInSuspended was true, bounds unchanged, all three policies and four alarms still there. After resuming, `grep -ci true` on the three switches printed 0.

**Step 14 - persistence**

![Before restart](../../screenshots/lab6/step14-1.png)
![Restart](../../screenshots/lab6/step14-2.png)
![After restart](../../screenshots/lab6/step14-3.png)

**Observed:** every name was found again from the API after the restart and the diff was empty, PERSISTENCE PROVEN. The scheduled actions part of that message does not really apply here, because that line was empty both before and after.

**Step 15 - closing the loop**

![Trace](../../screenshots/lab6/step15.png)
![Target check](../../screenshots/lab6/step15-2.png)

**Observed:** the task definition is still `usms-enrolment:2` with one load balancer and one deployment, so this lab changed nothing in Labs 04 and 05. **Floci limitation:** the target group had three targets (one unhealthy) while the service ran two tasks. A task stopped during the scale in from 10 was not deregistered. I left it, because the target group belongs to the ECS service.

**Step 16 - configs/lab-06.env**

![Step 16](../../screenshots/lab6/step16.png)

**Observed:** all values populated, 22 exports, bounds 2 to 10, three real policy ARNs and the resource ID matching the API.

**Step 17 and Section 8 - verification and commit**

![Verification](../../screenshots/lab6/section8-verify.png)
![Git check](../../screenshots/lab6/step17-1.png)

**Observed:** PASS=39 FAIL=3.

| Failed check | Reason |
|---|---|
| morning action exists | scheduled actions are not supported on Floci 2.2.0 |
| evening action exists | same |
| morning floor above the evening floor | same, both sides are empty |

All three checks that the handout calls "not benign" passed: no suspension switch left true, desired count back at 2 and minimum capacity 2.

### 6.2 AWS Management Console Verification

Floci does not have a web console, so there is no console screenshot for this lab. Every resource was checked with `describe` commands instead, and the screenshots in 6.1 are that verification.

## 7. Analysis and Discussion

The main goal was achieved. The scalable target, both target tracking policies, the step policy and my alarm all exist and are configured the way the handout asks. The most important result is Step 12, where the alarm and the policy changed the desired count without me typing a number, and the scaling activities say exactly which alarm and which policy did it. I expected Path B because Step 6 showed the minimum was not enforced, so it was a nice surprise that the loop actually ran.

Not everything matched what real AWS would do. The step policy fired three times in 30 seconds instead of once per cooldown, scheduled actions could not be created at all, and raising the minimum did not raise the count. I wrote these down as Floci limitations and did not try to fake them.

Problems I ran into and how I fixed them:

- **Step 16, empty resource ID.** The handout writes the awk command with a backslash before `$NF`. Inside `$(...)` with single quotes the backslash reaches awk, which fails with "backslash not last character on line". The empty value check caught it, and I fixed that one line by running the lookup again without the backslash.
- **Section 8, false failure.** The handout's "no secret is tracked by git" check fails for anyone who has `outputs/.gitkeep` tracked, which the handout itself requires. `git ls-files outputs/` showed only `.gitkeep`, so nothing had leaked. I changed the line to the same version my Lab 02, 04 and 05 verify scripts already use.
- **Step 17, hint strings.** The handout's replace-all repair would have broken my Lab 05 cleanup script, because its lines naming `lab-04-cleanup.sh` are correct (lab 05 runs before lab 04). I checked them and left them as they were.

Things I noticed along the way: the cooldowns are deliberately different (60 s out, 300 s in) because it is better to add capacity quickly and remove it slowly; and a suspended target looks completely normal everywhere except in its SuspendedState, which is why the verify script checks it.

Observed vs reasoned, as Section 11 asks:

| Observed on Floci | Only reasoned (not observable here) |
|---|---|
| service-linked role, scalable target, all three policies, managed alarms | scheduled actions and scheduled firing |
| ResourceLabel, step table, my custom alarm and its link to the policy | the minimum capacity raising the desired count |
| alarm evaluation and scaling activities with the cause string | cooldowns being respected |
| the maximum of 10 clamping the result | the target tracking capacity calculation on real CPU and request metrics |
| suspension stored and cleared, persistence after restart | Fargate start time and the grace period delaying useful capacity |

## 8. Reflection

**What I learned.** Before this lab I thought auto scaling starts containers. It does not, it only writes one number and ECS does the rest. I also learned the difference between the alarms AWS makes for target tracking and the alarm I write myself for step scaling, and why the first ones should never be edited or deleted by hand.

**Challenges.** The hardest part was knowing which results were my mistake and which were Floci. For example in Step 6 I thought the whole loop would not work, and then in Step 12 it worked better than I expected. I had to check each thing with a read back instead of trusting the success message. Finding the two bugs in the handout scripts also took some time.

**Real world use.** For USMS I would not trust reactive scaling alone for enrolment day. Exercise 4 shows that a reactive policy needs about 5 to 11 minutes to go from 2 to 10 tasks, and even 10 tasks are not enough for 40 times the normal traffic. In a real environment I would pre-scale with scheduled actions before the doors open and keep target tracking for the normal ups and downs.

**What I want to explore more.** Load testing to find how many requests one task can really serve, because every number in this lab is a guess without it. I would also like to see `--include-not-scaled-activities` on real AWS, and compare all this with the Kubernetes HorizontalPodAutoscaler in Lab 07.

## 9. Conclusion

The objectives were achieved. The enrolment service now has a scalable target with a floor of 2 and a ceiling of 10, two target tracking policies, a step scaling policy with its own alarm, and I proved with a real scaling activity that the alarm and the policy can change the desired count by themselves. The configuration survived a restart, everything is recorded in `configs/lab-06.env`, and the service is back at its baseline of 2 tasks with nothing suspended.

The key ideas I am taking from this lab are that auto scaling only changes one number, that reactive scaling is always a few minutes late so the minimum capacity and scheduled actions matter for known spikes, and that you should scale out quickly and scale in slowly. I also got more practice at telling apart what the emulator really did and what real AWS would do, which I think is the most useful skill in this whole course.

## 10. Appendix

- Notes and the seven review questions: `notes/lab-06-notes.md`
- Exercises 1 to 5: `labs/lab-06-ecs-autoscaling/exercises.md`
- Policy and state documents: `templates/lab-06-target-tracking-cpu.json`, `templates/lab-06-target-tracking-requests.json`, `templates/lab-06-step-scaling-out.json`, `templates/lab-06-suspended-state.json`, plus `lab-06-target-tracking-memory.json` and `lab-06-step-scaling-in.json` from the exercises
- Recorded names and ARNs: `configs/lab-06.env` (24 exports after Exercise 5)
- Scripts: `scripts/utilities/verify-lab-06.sh`, `scripts/utilities/usms-scaling-report.sh`, `scripts/utilities/usms-scaling-history.sh`, `scripts/cleanup/lab-06-cleanup.sh` (not run)
- Screenshots: `screenshots/lab6/`
- Output files kept locally and not committed (they are git-ignored): the scaling proof, the restart comparison, the scaling report and history JSON, the latency measurement and the Lab 10 readiness file

