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
Lab 05 Exercise 5, and the health-check grace period from Lab 05 Step 10.
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





1. Trace the nine steps from clicking Register to serving the request
When a student clicks Register, the number of requests per target or the work queue depth increases. CloudWatch monitors the metric and an alarm can trigger a scaling policy. Application Auto Scaling then changes the ECS service's desiredCount, within the minimum of 2 and maximum of 10 tasks. ECS starts a task using the existing usms-enrolment:2 task definition. The task receives a network interface in one of the private subnets without a public IP address. The enrolment security group allows HTTP traffic from the appropriate load balancer security group. The ECS service registers the task's IP address with the target group, and the load balancer health-checks it before sending traffic to it. The existing application blueprint, task definition and load balancer configuration do not need to change just because the number of tasks changes.
The three steps Lab 6 owns are the scaling signal, the policy that responds to that signal, and the change to desiredCount. The other six rely on infrastructure and behaviour established by earlier labs, so they should not need redesign.
My conclusion: Auto scaling changes the application's running capacity, not its source code or task definition.
Floci result: The custom metric and alarm exist, but the Application Auto Scaling portion of this chain could not be implemented on this build.
2. Why is the ECS resource ID not the full service ARN?
Application Auto Scaling uses a constructed resource ID to identify the specific resource and scaling dimension it manages. For ECS, the format is:
service/cluster-name/service-name
For this lab, it is:
service/usms-ecs-cluster/usms-enrolment-svc
The full ECS service ARN includes additional information such as the partition, region, account and service type. Passing the entire ARN where the API expects the constructed resource ID causes a validation error.
The formats differ between services:
- ECS: service/cluster-name/service-name
- DynamoDB: table/table-name
- Lambda: function:function-name:alias:alias-name when scaling provisioned concurrency for a function alias.
This architecture also uses constructed identifiers elsewhere. The ALBRequestCountPerTarget metric requires a ResourceLabel made from the load balancer ARN and target group ARN. The managed target-tracking alarm names are derived from the scalable resource ID. The custom queue alarm uses the scaling policy ARN as its alarm action in the intended step-scaling design.
3. Why can registering a scalable target immediately raise the task count?
The scalable target defines the allowed capacity range. If a service is running one task and its minimum capacity is registered as two, Application Auto Scaling can immediately raise the service's desired count to two to satisfy that minimum.
This differs from a scaling policy. A policy responds to a metric, such as CPU utilisation or request count, and calculates a scaling change. Registering the target establishes the capacity limits; it does not require a metric breach before enforcing the minimum.
For example, at 3 a.m., an engineer might discover that a service has only one task even though the minimum required capacity is two. Re-registering the target with a minimum of two can restore the required baseline without waiting for a high-load alarm.
The engineer should leave evidence for the next person: the change made and its reason, the scalable target's minimum and maximum values, the ECS service's desired and running counts, and the relevant service events or audit records. The person taking over at 8 a.m. can then verify that the baseline has been restored and understand why it was changed.
Floci limitation: This behaviour is part of the intended AWS design, not something demonstrated by your current Floci environment.
4. Compare the two managed alarms with the custom queue alarm
Target tracking creates and manages two CloudWatch alarms for each target-tracking policy: a high alarm for scaling out and a low alarm for scaling in. Application Auto Scaling owns these alarms. If the policy changes, the service may update or recreate its managed alarms; deleting one manually can interfere with the policy's ability to scale in one direction.
The custom queue alarm, usms-enrolment-queue-high, is different. It monitors the custom metric EnrolmentQueueDepth in the USMS/Enrolment namespace. In the intended design, it invokes the step-scaling policy when the queue reaches the configured threshold. Because it is our own alarm, we can choose its threshold, evaluation periods, missing-data treatment and additional alarm actions.
The custom alarm can express a specific queue-depth rule, such as adding one task for a smaller backlog and three tasks for a larger backlog. Target tracking instead tries to maintain a chosen metric near a target value.
For missing data, treating it as breaching can be appropriate if missing measurements mean the queue is unhealthy or the monitoring system has failed and the service should respond conservatively. However, it is risky: a monitoring outage could be mistaken for a genuine queue backlog, causing unnecessary scaling and extra cost. The correct choice depends on what missing data means operationally.
Floci result: The custom alarm exists with a threshold of 100, and the metric exists. The managed target-tracking alarms and the scaling-policy link could not be verified because Application Auto Scaling operations are unsupported.
5. Why can't reactive scaling absorb the first minutes of a sudden spike?
Reactive scaling has several delays. Using the lab's CPU target-tracking example, the high alarm evaluates three 60-second periods:
- Alarm evaluation: \(60 \times 3 = 180\) seconds.
- Policy invocation: approximately zero additional time once the alarm triggers.
- Task startup: the time measured during Lab 05 Exercise 5.
- Health-check grace period: 60 seconds in the intended Lab 5 configuration.
Therefore, the intended estimate is:
\[
180 + 0 + T_{\text{startup}} + 60 \text{ seconds}
\]

The exact total depends on the measured task-startup time. The 180-second evaluation period alone means the service can spend several minutes under pressure before a new task is ready to serve traffic.
This has three important consequences:
1. Prepare capacity before predictable peaks. The morning scheduled action raises the minimum capacity to four tasks before the weekday enrolment rush.
2. Use a suitable scaling signal and cooldown. Request count can respond to incoming load, while the 60-second scale-out cooldown limits repeated scaling actions. The 300-second scale-in cooldown is more conservative to avoid removing capacity too quickly.
3. Allow time for tasks to become useful. Task startup and health checks must be considered when selecting cooldowns and minimum capacity. Reducing alarm evaluation time may improve responsiveness, but can also make scaling react to short-lived spikes.
The main lesson is that reactive scaling responds after load has already increased. Scheduled scaling and a sensible minimum capacity help prepare for known peaks.
Floci note: The intended 60-second health-check grace period was not persisted by this Floci build, so the actual total cannot be demonstrated from the current run.
6. What happens when CPU and request-count policies disagree?
The lab uses two different target-tracking signals:
- CPU target: 50% average service CPU utilisation.
- Request-count target: 1,000 requests per target over the configured measurement period.
When policies disagree, the rules are deliberately asymmetric. For scale-out, the largest capacity requested by any policy wins. For scale-in, every target-tracking policy must agree that reducing capacity is safe.
For example, if CPU utilisation is low but request count is too high, the request-count policy can still request more tasks. Conversely, low CPU alone does not justify scaling in if request count remains high.
Two target-tracking policies on the same metric but with different target values can conflict and cause unstable scaling. A step-scaling policy and target-tracking policy controlling the same metric can also compete because they use different decision rules. They may request incompatible capacity changes.
Using different signals can be sensible when they represent different aspects of demand. A queue-depth step policy can complement CPU or request-count tracking because it represents backlog, provided the resulting policies and their interactions are deliberately designed.
Floci limitation: These policy interactions describe intended AWS behaviour. Your current environment cannot verify them because it does not implement Application Auto Scaling.
7. Why is ALBRequestCountPerTarget a better signal than CPU for the enrolment API?
Request count is often a better signal for a web API for three reasons:
1. It measures incoming demand directly rather than using CPU as an indirect symptom of demand.
2. It is not dependent on the CPU reservation of each task.
3. It can rise as soon as traffic increases, whereas CPU utilisation depends on how much processing each request requires.
CPU is a better signal for CPU-bound workloads where the processing cost varies significantly per request. For example, a request involving heavy computation may consume far more CPU than a simple registration lookup, even if both count as one request.
Request count can give misleading scaling decisions when requests do not represent actual work. For example, many cheap cached requests might increase the request count without creating much processing demand. Conversely, a small number of expensive requests or a growing background queue might overload the application while request count remains relatively low.
Queue depth, CPU utilisation and response latency can help identify these situations. If the queue grows or latency rises while request count remains moderate, that suggests request count alone is not a sufficient scaling signal.
Floci limitation: The request-count target-tracking policy could not be verified in this build, so these are design conclusions rather than measured scaling results.