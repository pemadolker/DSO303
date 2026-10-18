# Lab 06 Notes - ECS Service Auto Scaling

**Support path: A** (Floci 2.2.0). Observed: the custom alarm evaluated by itself, invoked the step
policy, and desiredCount moved 2 -> 5 -> 8 -> 10 with scaling activities naming the alarm and the policy
(Step 12); the MaxCapacity ceiling clamped the last step. Not observable on this build: scheduled actions
(UnsupportedOperation), the MinCapacity floor raising desiredCount (Step 6), the 60 s cooldown, and
Fargate start-up time. Those parts are reasoned, not observed.

## Step 3 - Support probe

Step 3 probe: every Application Auto Scaling, CloudWatch, IAM and ECS call answered except
describe-scheduled-actions, which is "not available" on this build. Step 11 (scheduled actions)
is expected to fail and will be recorded as a limitation.

Read back under Floci's name: Path /aws-service-role/ecs.application-autoscaling.amazonaws.com/,
trust principal ecs.application-autoscaling.amazonaws.com. No managed policy is attached on this build;
on real AWS it carries AWSApplicationAutoscalingECSServicePolicy (ecs:UpdateService, ecs:DescribeServices,
CloudWatch alarm permissions).

Scheduled actions: describe-scheduled-actions returns
"UnsupportedOperation: Operation DescribeScheduledActions is not supported" on Floci 2.2.0.

## Step 5 - scalable target
Observed: resource id derived from the service ARN, service/usms-ecs-cluster/usms-enrolment-svc
(3 segments, first "service"). register-scalable-target returned a ScalableTargetARN. Read back:
namespace ecs, dimension ecs:service:DesiredCount, Min 2, Max 10, all three SuspendedState
switches false. RoleARN was filled in without --role-arn, as on real AWS, but it names
AWSServiceRoleForApplicationAutoScaling_ECSService, which does not exist on this build (Step 4
created AWSServiceRoleForEcsApplicationAutoscaling). On real AWS a target pointing at a missing
role could not scale. Floci accepts it because it does not evaluate IAM.
desiredCount stayed 2: registration only acts when the service is outside the bounds.

## Step 6 - bounds and re-registration
Observed: re-registering with only --max-capacity 12 gave Min 2 / Max 12 (omitted values are kept),
then back to 2 / 10. Exactly one scalable target exists.

"Your turn" - MinCapacity 5 while the service ran 2 tasks.
Prediction: desiredCount rises to 5 within seconds, with no policy and no alarm involved.
Observed on Floci 2.2.0: MinCapacity was stored as 5, but desiredCount stayed 2 for 30 seconds
and describe-scaling-activities returned an empty list. Floci stores the scalable target but does
not enforce its bounds. On real AWS the count would have moved to 5 at registration.

(a) The scalable target made (or, on real AWS, would make) that change: raising the minimum is
enforced by the registration itself, not by a scaling policy and not by ECS.
(b) Three extra tasks run all night for nothing, about 3 x $0.014565 = $0.044 an hour, or roughly
$32 a month if nobody notices, and scale-in can never go below 5. The single call that shows it is
`aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids <rid>`,
whose MinCapacity a monitor would compare with the expected 2.

## Step 7 - CPU target tracking policy
Observed: templates/lab-06-target-tracking-cpu.json valid, no unexpanded variable. put-scaling-policy
returned an arn:aws:autoscaling:...:scalingPolicy ARN (namespace "autoscaling", embedding the resource
id). Read back: TargetTrackingScaling, ECSServiceAverageCPUUtilization, target 50.0, ScaleOutCooldown 60,
ScaleInCooldown 300, DisableScaleIn false, and two alarm names I never created.

## Step 8 - the managed alarms
Observed: two alarms named TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc-AlarmHigh-<uuid>
and -AlarmLow-<uuid>, both AWS/ECS, Average, period 60, state INSUFFICIENT_DATA, one action each, and
that action is the CPU policy ARN.
- AlarmHigh: > 50 for 3 periods (3 minutes to decide to scale out).
- AlarmLow:  < 50 for 15 periods (15 minutes to decide to scale in).
Floci differences: the alarms' MetricName is the predefined type ECSServiceAverageCPUUtilization rather
than the real CloudWatch metric CPUUtilization, and AlarmLow's threshold equals the target (50). Real AWS
sets it slightly lower (about 45), leaving a dead band so a metric sitting at the target does not flap.
These alarms belong to the policy: edit TargetValue or the cooldowns, never the alarms.

"Your turn" - how long at 100% CPU before a third task serves traffic?
  1. AlarmHigh must breach for Period x EvaluationPeriods = 60 s x 3     = 180 s
  2. the alarm invokes the policy, which writes desiredCount             ~   0 s
  3. ECS starts a new Fargate task (Lab 04 handout figure: 20-60 s)      =  60 s (worst case)
  4. the health-check grace period before it is judged (Lab 05 Step 10) =  60 s
  Total: about 300 s, five minutes, served only by the two tasks already running.
  (Terms 1 and 4 are this course's configuration; terms 2 and 3 belong to AWS.)
Which term I would change first: term 1, the biggest. In target tracking AWS owns those alarms, so
I would not edit them; I would add a step-scaling policy with my own 1-period alarm, like Step 10.
That cuts the decision from 180 s to 60 s, at the cost of reacting to short spikes and owning one
more alarm. (Term 2 is fixed, term 3 only improves with a smaller image, and lowering the grace
period risks killing tasks that are still starting.)

## Step 9 - request-count target tracking
Observed: used the ResourceLabel Lab 05 Exercise 5 recorded,
app/usms-enrolment-alb/cf9484b4fa5f4620/targetgroup/usms-enrolment-tg/546a39fb5cab433e,
validated as 6 segments with "app" first and "targetgroup" fourth. The template was written with
an unquoted heredoc so the label expanded (grep -c '\$' printed 0). put-scaling-policy returned an
ARN; describe-scaling-policies lists two TargetTrackingScaling policies (CPU target 50.0, requests
target 1000.0), two managed alarms each, four in total.
TargetValue 1000 means 1000 requests per target per minute, a provisional number until a load test.
When two policies disagree, scale-out follows the largest request and scale-in happens only when
every policy agrees, so a second policy on a different metric can only make the service bigger.

## Step 10 - step scaling and the alarm that drives it
Observed: published three datapoints (3, 5, 4) to USMS/Enrolment EnrolmentQueueDepth, Service=enrolment.
templates/lab-06-step-scaling-out.json: ChangeInCapacity, Average, Cooldown 60, two steps -
breach 0-100 -> +1, breach 100 and up (no upper bound) -> +3. Bounds are relative to the alarm
threshold, so a queue of 100-199 adds 1 task and 200 or more adds 3.
Policy created first (the alarm needs its ARN), then usms-enrolment-queue-high: Average, period 60,
1 evaluation, >= 100, missing data notBreaching, AlarmActions = the step policy ARN.
State INSUFFICIENT_DATA right after creation. This is the alarm *I* own, unlike Step 8's managed ones,
so it can also notify an SNS topic, and it is the one used to make scaling observable in Step 12.

Policy read-back: StepScaling, ChangeInCapacity, Average, Cooldown 60, two steps (0-100 -> +1,
100 and up -> +3, no upper bound). Floci difference: the policy's Alarms list is EMPTY. On real AWS,
pointing the alarm's AlarmActions at the policy also registers the alarm on the policy, so Alarms would
contain usms-enrolment-queue-high. On this build the link is stored only on the alarm side
(alarm -> policy), which is the side Step 12 relies on.

## Step 11 - Scheduled actions

Both put-scheduled-action calls (morning cron(45 7 ? * MON-FRI *) with Min 4, evening
cron(0 20 ? * MON-FRI *) with Min 2, both Asia/Thimphu) returned UnsupportedOperation, and so did
describe-scheduled-actions. The handout's UTC fallback (cron(45 1 ...) / cron(0 14 ...)) was not
tried because the error is about the operation itself, not about --timezone. Same result as the Step 4
probe: Floci 2.2.0 has no scheduled actions. Nothing was created, so there is nothing to clean up, and
the scalable target is still Min 2 / Max 10.

What I would have expected on real AWS: two rows in describe-scheduled-actions, TZ Asia/Thimphu.
Using the time zone instead of converting to UTC by hand matters because the action stays correct
if the schedule is ever copied to a region or zone that uses daylight saving.

### Your turn - exam results night (at() action)

Tried put-scheduled-action usms-enrolment-results-night with at(<now + 10 min>) in UTC and
MinCapacity=6. Result: UnsupportedOperation, so the action does not exist and the mechanism was not
observable on this build. MinCapacity stayed at 2.

An at() action is not removed after it fires: the scheduled action stays in the list, and the floor
it set (MinCapacity 6) also stays on the scalable target, so six months later the service is still
paying for at least 6 tasks every hour, with an old "results night" entry that nobody remembers
creating. That is why the runbook page that creates it must also contain the cleanup:
aws application-autoscaling delete-scheduled-action --scheduled-action-name usms-enrolment-results-night
(plus --service-namespace ecs --resource-id and --scalable-dimension), followed by
register-scalable-target --min-capacity 2 --max-capacity 10, since deleting the action does not
put the floor back.

## Step 12 - Fire the alarm

Prediction (written before running): the metric will be pushed to 260 against a threshold of 100,
a breach of 160. That is in the open-ended second step (100 and up), so +3 tasks: desiredCount
should go from 2 to 5, well under the max of 10. Because Step 6 showed this build does not enforce
bounds, I expect the loop may not run (Path B).

Part 1 (before): desired 2, running 2, pending 0; scaling activities recorded so far: 0.
Part 2: pushed 260 three times. get-metric-statistics showed one 60-second datapoint, Average 260,
Maximum 260. The alarm went OK -> ALARM by itself on poll 2 ("Threshold Crossed: 1 datapoint(s)
breaching the threshold"). So Floci 2.2.0 does evaluate CloudWatch alarms, and part 3
(set-alarm-state) was not needed: the alarm state is real, not forced.

Part 4 result: PATH A - the scaling loop ran. Within about 30 seconds desiredCount went 2 -> 5 -> 8 -> 10
(running 10, pending 0), with three Successful scaling activities, each with
Cause "monitor alarm usms-enrolment-queue-high in state ALARM triggered policy usms-enrolment-queue-step-out".
That Cause string names both the alarm and the policy: something other than me changed desiredCount.

Compared with my prediction (2 -> 5):
- The first activity matched exactly: breach 160, open-ended step, +3, 2 -> 5.
- Floci then re-invoked the policy every ~10 seconds while the alarm stayed in ALARM: 5 -> 8, then
  8 -> 11, which was clamped to the MaxCapacity of 10 ("Setting desired capacity to 10"). So the
  ceiling IS enforced on this build, even though raising the floor in Step 6 was not.
- The 60-second cooldown was not respected (activities 10 s apart). On real AWS the alarm is evaluated
  once per 60-second period and the cooldown would hold back the next scale-out, so I would expect
  2 -> 5, then a pause, then further steps only if the queue stayed high.
- running jumped to 10 with pending 0 immediately. Floci does not model Fargate start-up time
  (20-60 s per task), so the "late capacity" from Section 4 is still conceptual here.
- StatusMessage (Detail) is null on Floci; real AWS fills it with "Successfully set desired count to 5...".

Support path: Step 6 suggested Path B, but Step 12 proves the alarm -> policy -> desiredCount loop runs,
so this lab is PATH A for alarms and step scaling. Still not observable: scheduled actions (unsupported)
and the min-capacity floor raising desiredCount.

Part 6 (back to baseline): alarm set to OK, metric pushed down to 4, 3, 2 (all under 100) FIRST,
then update-service --desired-count 2. Pre/post: 2/2/0 at 15:15:25Z -> desired 2 at 15:24:42Z
(running was still 10 at that instant while Floci stopped the extra tasks, then dropped to 2).
Order matters: if the count were set first while the queue metric was still 260, the alarm would go
back to ALARM at the next evaluation and the step policy would scale straight out again. A service
under a scaling policy has no "manual" capacity; to hold a number, suspend scaling (Step 13) or set
min = max.

## Step 13 - Suspend and resume scaling

Suspended scale-in only, using templates/lab-06-suspended-state.json (In true, Out false, Scheduled false)
passed to register-scalable-target --suspended-state. Read-back: Min 2, Max 10, one true. There is no
separate "suspend" call: the suspension is part of the target's registration, so the bounds stayed.
While suspended, all three policies were still listed (two TargetTrackingScaling, one StepScaling)
and the managed alarm count was still 4: suspending changes no configuration, which is exactly why a
forgotten suspension is dangerous - everything looks normal and only SuspendedState shows it.
Resumed with all three false. SuspendedState.* as text prints "False False False" (capital F),
so grep -ci true returns 0; without -i a plain grep -c true would print 0 even while suspended.
The JSON file stays in Git as the runbook page for "stop scale-in during an incident or deployment".

## Step 14 - Persistence across a restart

Recorded the configuration (target bounds and suspension switches, the three policies, the CPU policy's
TargetValue 50 / cooldowns 60 and 300 / DisableScaleIn False / ECSServiceAverageCPUUtilization, the step
policy's ChangeInCapacity / Average / 60 / 2 steps, the scheduled actions, and the queue alarm's threshold,
operator, 1 evaluation period, notBreaching and 1 action) into outputs/lab-06-pre-restart.txt.
Restarted with floci-down.sh (docker compose stop, state kept in ~/floci-data) and floci-up.sh
(hybrid storage, /app/data verified). Afterwards every identifier was RE-DERIVED from the API
(resource id from the service ARN, the step policy by PolicyType=='StepScaling', the CPU policy by
name fragment, the alarm by prefix) rather than taken from shell variables, which would only prove
Bash remembers strings. diff: no differences -> PERSISTENCE PROVEN.
Caveat: the "both scheduled actions unchanged" part of the success message does not apply here.
describe-scheduled-actions is unsupported, so that line was empty before and after; the diff
only shows the scheduled actions were equally absent. Managed alarm names were left out on purpose
(some builds recreate them with new UUIDs).

## Step 15 - Close the loop: from one request to one new task

Trace (all read back, nothing changed):
1. Metrics/alarms that would start it: CPU AlarmHigh (> 50), request-count AlarmHigh (> 1000), and my
   queue alarm (EnrolmentQueueDepth >= 100). Floci shows the predefined type names as MetricName (Step 8 quirk).
2. Policies: two TargetTrackingScaling, one StepScaling.
3. The one integer they write: ecs:service:DesiredCount on service/usms-ecs-cluster/usms-enrolment-svc, clamped 2..10.
4. Service: usms-enrolment-svc, desired 2, running 2, task definition usms-enrolment:2, grace period 60 s.
5. Where a new task appears: the two private subnets, usms-enrolment-sg, assignPublicIp DISABLED.
6. Who registers it: the SERVICE, into usms-enrolment-tg (container enrolment-api, port 80).
7. What this lab changed about 4-6: nothing - still usms-enrolment:2, 1 load balancer, 1 deployment.

Floci observation in block 6: the target group lists 3 addresses (172.21.0.3 and .4 healthy,
172.21.0.5 unhealthy, Target.FailedHealthChecks) while the service has only 2 running tasks, still there
after 30 s. The 172.21.x.x addresses are the containers' real Docker network addresses, while ECS reports
the tasks at 10.0.3.10 and 10.0.3.11 (simulated VPC addresses), so targets and tasks cannot be matched by
IP on this build, only by count. The extra target is left over from scaling 10 -> 2 (or from the restart):
Floci stopped the task but did not deregister its address. I did NOT deregister it by hand - the target
group's contents belong to the ECS service (Lab 05), and on real AWS the service deregisters a stopped
task's IP itself, after the deregistration delay.

Of the nine lines in the "student clicks Register" chain, this lab created three: the alarm invoking a
policy, the policy writing desiredCount, and the 2..10 clamp. Everything else (the blueprint, subnets,
security groups, target registration, health checks, grace period) is Labs 03-05, unchanged.

## Step 16 - configs/lab-06.env

Generated with an unquoted heredoc so every $(...) ran once and the file stores values, not API calls.
Handout bug found: the line awk -F: '{print \$NF}' inside $(...) failed with "backslash not last
character on line", leaving USMS_SCALABLE_RESOURCE_ID empty. Inside a command substitution the
command is parsed as ordinary shell, and single quotes keep the backslash literally, so awk received
\$NF. The single quotes already protect $NF from the shell, so the backslash is not needed. The
empty-value check (grep 'export .*=$') caught it, which is exactly what it is for. Fixed that one line by
re-running the lookup with '{print $NF}' and writing the value in.

## Section 8.1 - verify-lab-06.sh

Result: PASS=39 FAIL=3 (handout expects 42/0).

The three failures are the scheduled-action checks (morning exists, evening exists, morning floor above
evening). This is the handout's listed benign cause: describe-scheduled-actions is not implemented on
Floci 2.2.0, so the actions could not be created in Step 11 and both sides of the comparison are empty.

Fixed a bug in the handout's script first: the "no secret is tracked by git" check was
! git ls-files | grep -q '^outputs/', which fails whenever outputs/.gitkeep is tracked - and the handout
itself (Step 17) says it must be. git ls-files outputs/ showed only outputs/.gitkeep, so nothing had
leaked. I replaced the line with the version verify-lab-02/04/05 already use, which allows exactly that
one file: ! git ls-files outputs/ | grep -qv '^outputs/\.gitkeep$'. Before the fix the result was PASS=38 FAIL=4.

All three "not benign" checks pass: no suspension switch left true, desiredCount back at the baseline
of 2, MinCapacity 2. The managed alarms, the alarm -> step policy link and the custom metric (all listed
as possibly benign) also pass on this build.

