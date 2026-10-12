# Lab 06 notes

## Support path: C (no Application Auto Scaling)
Floci image floci/floci:latest. Every application-autoscaling read and write returns
UnknownOperationException (AnyScaleFrontendService.*). CloudWatch, IAM and ECS answer.
The probe's "SUPPORTED" lines for register-scalable-target and put-scaling-policy only
meant the CLI knows the operation; the emulator does not implement it.

## Step 4 - service-linked role
iam create-service-linked-role -> UnsupportedOperation. get-role -> NoSuchEntity.
Real AWS: the role AWSServiceRoleForApplicationAutoScaling_ECSService holds
ecs:UpdateService for Application Auto Scaling, and its trust policy is AWS-written.
Here: not creatable, so nothing can "assume" it, and Step 5's RoleARN field would be empty.

## Step 5 - scalable target
Derived resource id: service/usms-ecs-cluster/usms-enrolment-svc (3 segments, first = service). Dimension: ecs:service:DesiredCount.
register-scalable-target -> UnknownOperationException; evidence in outputs/lab-06-register-attempt.txt.
Real AWS would store min 2 / max 10, fill RoleARN with the service-linked role,
and register would raise desiredCount to 2 if the service were below the floor.

## Step 6 - re-registration (not runnable on this build)
There is no update-scalable-target. Re-registering at the same address (namespace,
resource id, dimension) replaces the content; omitted parameters keep their value,
and attached policies are untouched. "Your turn": re-registering with --min-capacity 5
on a 2-task service would raise desiredCount to 5 with no policy and no alarm.
(a) The scalable target's floor did it, and ECS then acted on the new desiredCount.
(b) A forgotten raised floor means paying for 5 tasks all night, and it blocks scale-in.
    describe-scalable-targets (MinCapacity) is the single call a monitor would compare.
**Step 6 — Re-registration and minimum capacity**

- **(a)** Re-registering the scalable target with `MinCapacity` set to 5 raises the minimum capacity constraint; the lab expects this change to cause ECS `desiredCount` to increase to 5 without a scaling policy or alarm.
- **(b)** Raising `MinCapacity` without lowering it later can keep more tasks running than necessary, increasing resource usage and cost. The `DescribeScalableTargets` API call would reveal the changed minimum capacity.

**Environment limitation:** Floci returned `UnknownOperationException` for both `RegisterScalableTarget` and `DescribeScalableTargets`, so the behavior above was not experimentally verified in this environment.
## Step 8 - target-tracking alarms

CloudWatch describe-alarms returned an empty list for the
TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc prefix.
The CPU target-tracking policy could not be created because Floci returned
UnknownOperationException for PutScalingPolicy. Therefore, no managed alarms
or associated policy ARNs could be verified.

For the lab's example high alarm, alarm evaluation is 60 seconds x 3
evaluations = 180 seconds. The estimated total time until the third task
serves traffic also includes policy invocation, task startup time from
Lab 04 Exercise 5, and the health-check grace period from Lab 05 Step 10.
The complete total is not experimentally verifiable on this Floci build.

The two expected alarms are a high alarm for scale-out and a low alarm
for scale-in. Their exact settings and actions were not observed here.


## Step 8 - Managed target-tracking alarms

**Result:** Blocked by the Floci emulator limitation. The CloudWatch query using the `TargetTracking-${RID}` prefix returned no alarms, and Application Auto Scaling operations such as `describe-scaling-policies` return `UnknownOperationException`.

**Conclusion:** The two managed target-tracking alarms could not be verified in this environment. Do not claim they were created. Their expected configuration and timing calculations describe real AWS behaviour, not a result observed in this Floci run.


## Steps 7-9 - target tracking (templates only)
put-scaling-policy -> UnknownOperationException (outputs/lab-06-put-policy-attempt.txt).
Wrote and validated templates/lab-06-target-tracking-cpu.json and -requests.json.
ResourceLabel validated: six segments, app first, targetgroup fourth (from Lab 05 Exercise 5).
Real AWS would create two policies and four managed alarms (AlarmHigh/AlarmLow per policy,
names TargetTracking-<resource id>-...). On this build none of these exist.

## Step 11 - scheduled actions (not runnable on this build)
put-scheduled-action -> UnknownOperationException, with and without --timezone, so the
failure is the missing operation, not the time zone.
Intended design: morning cron(45 7 ? * MON-FRI *) Asia/Thimphu, MinCapacity=4 MaxCapacity=10;
evening cron(0 20 ? * MON-FRI *) Asia/Thimphu, MinCapacity=2 MaxCapacity=10.
UTC fallback (Thimphu is UTC+6, no DST): 01:45 and 14:00.
A scheduled action moves the BOUNDS, never desiredCount; raising the floor to 4 pulls the count up.
"Your turn" at() action: leaves the action behind after it fires. If it is never deleted,
a stale floor of 6 can reapply on a later date, so the runbook page should pair the create
command with delete-scheduled-action.

## Step 10 - step scaling
Published USMS/Enrolment EnrolmentQueueDepth (3, 5, 4). Wrote and validated
templates/lab-06-step-scaling-out.json. put-scaling-policy StepScaling is not available
on this build, so the alarm was created WITHOUT --alarm-actions.
Real AWS: policy first, then alarm with --alarm-actions <policy ARN>. A breach of 0-100
selects +1; 100 and above selects +3 (bounds are relative to the threshold).

## Steps 9-10 - policies and alarm
Wrote and validated the requests target-tracking template (ResourceLabel: six segments,
app first, targetgroup fourth) and the step-scaling template.
put-scaling-policy and describe-scaling-policies -> UnknownOperationException.
Published USMS/Enrolment EnrolmentQueueDepth (3, 5, 4); list-metrics shows it with
dimension Service=enrolment.
The original put-metric-alarm failed with "Invalid length for parameter AlarmActions[0]"
because the policy ARN was empty; recreated the alarm WITHOUT --alarm-actions.
Real AWS: policy first, then alarm with --alarm-actions <policy ARN>.

## Step 12 - firing the alarm (Path B-minus: wiring only, loop not closed)
Prediction: breach 260-100 = 160 falls in the open-ended step, +3, so 2 -> 5 on real AWS.
Observed: put-metric-data stored the 260 datapoints (get-metric-statistics confirms).
The alarm stayed INSUFFICIENT_DATA / "Unchecked" for 8 polls (~2 min) with the metric
above threshold, so this build does not evaluate alarms on a schedule.
set-alarm-state -> ALARM was accepted and stored, but AlarmActions is null and no scaling
policy exists, so desiredCount stayed 2 (pending 0). No scaling activity could be recorded.
Links not connected on this build: alarm evaluation; alarm -> policy (no policy);
policy -> desiredCount (no Application Auto Scaling).
Evidence: outputs/lab-06-scaling-proof.txt. Baseline restored (metric down first, count 2).
Real AWS: the activity's Cause would name the alarm and the policy, with
"Successfully set desired count to 5".

## Step 13 - suspension (conceptual)
No scalable target exists, so register-scalable-target --suspended-state cannot run.
Wrote templates/lab-06-suspended-state.json (scale-in suspended only) as the runbook artefact.
Dangerous one to leave on: DynamicScalingOutSuspended, because the service can shrink
but never grow, and nothing looks wrong in policies, alarms or graphs.

## Step 14 - persistence (reduced)
Scalable target, policies and scheduled actions cannot be tested (no Application Auto Scaling).
Compared the CloudWatch alarm's six fields and the USMS/Enrolment metric count before and
after floci-down/floci-up: identical. PERSISTENCE PROVEN (alarm + metric only).

## Step 15 - the nine-line chain (student clicks Register -> task serves traffic)
1. A student clicks Register on the portal.                                  (the trigger)
2. Requests per target pass 1000, or the work queue passes 100.             LAB 06 (metric)
3. A CloudWatch alarm fires and invokes a scaling policy.                   LAB 06 (alarm, policy)
4. The policy writes desiredCount, clamped to 2..10.                         LAB 06 (scalable target)
5. ECS starts a task from usms-enrolment:2.                                  Lab 04
6. The task gets an ENI in a private subnet with no public address.          Lab 02 / 04
7. usms-enrolment-sg admits tcp/80 from usms-alb-sg only.                    Lab 05
8. The service (not Lab 06) registers the task's address in usms-enrolment-tg. Lab 05
9. The load balancer health-checks it; after the 60s grace period it takes traffic. Lab 05

Lab 06 owns lines 2-4. Lines 5-9 needed no change because they react to the one integer,
desiredCount, and do not care who wrote it.
Observed on this build (blocks 4-7): desired 2/running 2, usms-enrolment:2, one load balancer,
no public IP, grace period None, and 3 targets "unhealthy" with AZ None and Docker IPs
(172.21.0.x): containers on Floci's Docker network, not ENIs in the VPC subnets.
Lines 2-4 could not be exercised: no Application Auto Scaling, and alarms are not evaluated.

What auto scaling changes about my application: <write your one sentence here>
