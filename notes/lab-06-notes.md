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


## Review questions

### 1. From one click to one new task

The nine lines from Step 15:

1. A student clicks Register and the requests per target go past 1000, or the work queue goes past 100.
2. An alarm fires and calls a policy.
3. The policy writes a new desiredCount, kept between 2 and 10.
4. ECS starts a task from usms-enrolment:2.
5. The task gets a network interface in usms-private-subnet-a or -b, with no public address.
6. usms-enrolment-sg lets in tcp/80 only from usms-alb-sg.
7. The service registers the task's address in usms-enrolment-tg.
8. The load balancer health checks it, and after the 60 s grace period it gets traffic.
9. Nothing about the task definition, the service or the load balancer changed.

This lab owns lines 1 to 3: the alarms, the policies, and the scalable target with its bounds. The other six needed no change because ECS already knew how to start a task to match desiredCount, the subnets and security groups already accepted any task of that service, and the service already registered every task it started in the target group. Labs 04 and 05 built a system that follows one number, and this lab only adds something that changes that number.

My one sentence answer: auto scaling does not change my application at all, it only changes how many copies of it are running.

### 2. Why the full ARN is rejected

The resource ID is not an ARN. It is a short string that Application Auto Scaling builds itself to name the thing it scales, and for ECS it is `service/<cluster>/<service>`, which is the last part of the service ARN after the last colon. Application Auto Scaling works with many services, and each one names its resources differently, so it uses its own format for every namespace instead of ARNs. For DynamoDB it is `table/<table-name>` (or `table/<table>/index/<index>`), and for Lambda it is `function:<function-name>:<alias>`, so the colons and slashes are different in each one. Passing the full ARN fails validation because it does not match the pattern for the ecs namespace.

The other constructed identifiers in this lab are the ResourceLabel for ALBRequestCountPerTarget, built from the load balancer ARN (everything after `loadbalancer/`) joined with the target group ARN (everything after the last colon), and the managed alarm names, which start with `TargetTracking-` plus the resource ID. In Step 14 the resource ID itself was rebuilt from the service ARN with `${SVC_ARN##*:}`.

### 3. Registering a floor above the current count

The object that makes the change is the scalable target registration, carried out by Application Auto Scaling using the service-linked role. It is different from a policy because no alarm and no metric is involved, there is no cooldown, and it happens straight away. The scaling activity it leaves says the cause was the minimum capacity, not an alarm. On Floci this did not happen at all (Step 6, Exercises 3 and 5), so this part is reasoned.

A 3 a.m. example: the enrolment service is slow, the on-call engineer cannot find the cause yet, and the reactive policies keep scaling in and out. To stop the flapping and buy time, they run register-scalable-target with a minimum of 6. The count goes to 6 at once and cannot drop below it. The person who takes over at 8 can see the evidence in three places: describe-scalable-targets shows MinCapacity 6, which disagrees with configs/lab-04.env; describe-scaling-activities shows the jump to 6 with a cause that is not an alarm; and on real AWS, CloudTrail shows the RegisterScalableTarget call with the engineer's identity and time. The engineer should also write it down in the incident notes, because the floor stays at 6 until someone puts it back, and the service costs more the whole time.

### 4. Managed alarms against my own alarm

The two TargetTracking alarms belong to AWS. They are created when the policy is created, they are changed when the policy changes (for example a new target value), and they are deleted when the policy is deleted. If someone deletes one by hand, the policy silently loses that direction, so with AlarmLow gone it never scales in again, and nothing warns you. usms-enrolment-queue-high belongs to me. Nothing creates, updates or deletes it for me: if I delete the step policy, the alarm stays and points at an ARN that no longer exists, and the cleanup script has to delete it on purpose. What my alarm can do that the managed ones cannot: I choose the metric, the period, the number of evaluation periods, the threshold and the missing data treatment, and I can watch any metric, including a custom one. The managed ones can follow a target value automatically and keep a scale in alarm that is slower than the scale out alarm without me doing anything.

The case for `breaching` on the queue alarm: if the thing that publishes the queue depth stops, that probably means something is wrong, and the safe guess is that the queue is building up while nobody reports it. Treating missing data as breaching makes the service scale out, which is the safer mistake during enrolment. What goes wrong if I am right: when the publisher breaks for a boring reason, like a bad deploy of the reporting job, the alarm stays in ALARM and keeps calling the policy until the service is at the maximum of 10. On Floci I saw how fast that happens in Step 12. The service then costs five times more for no reason, and the real problem, the broken metric, is hidden behind what looks like busy traffic.

### 5. Why reactive scaling is always late

The delays, in order:

1. The metric is published once a minute (Container Insights for CPU, the load balancer for requests), so up to 60 s pass before the first high value even exists.
2. The AlarmHigh needs 3 breaching periods of 60 s, so 180 s. This is set by AWS for target tracking; for my own alarm it is the evaluation periods I chose.
3. The policy runs and writes desiredCount within seconds.
4. ECS places the task, and Fargate needs about 20 to 60 s to start it and pull the image.
5. The service waits for the health check grace period of 60 s (Lab 05, set on the service), and the target group needs its healthy checks (Lab 05, interval 30 s) before it sends traffic.

That adds up to roughly 4 to 6 minutes from the first busy request to new capacity serving users. During that time the tasks that were already running take the whole load.

The three consequences: the minimum capacity is a latency decision, because the floor is what absorbs the first minutes, which is why the floor is 2 (one task per AZ) and not 1. Scale out quickly and scale in slowly, which is why ScaleOutCooldown is 60 and ScaleInCooldown is 300. And for a spike you know is coming, only scheduled scaling can be early, which is why Step 11 adds the weekday morning action at 07:45, before the office opens.

### 6. When two policies disagree

If either policy wants to scale out, Application Auto Scaling scales out to the larger of the two answers. It only scales in when every policy that has scale in enabled agrees. So if CPU is at 30% but requests per target are at 1500, the service scales out, and if CPU is at 70% but requests are low, it still scales out. It only shrinks when both are under their targets. The rule is asymmetric because the two mistakes do not cost the same. Too few tasks means students get errors, and too many tasks only means some extra money for a while.

Two target tracking policies on the same metric are a fault because they can never both be satisfied. With CPU targets of 40 and 60, the service is pushed to 40 by one policy, and the other one, sitting below its 60, keeps asking to scale in but is overruled, so the second policy does nothing except add alarms and confusion. A step policy and a target tracking policy on one metric is the same mistake in a worse form, as I wrote in Exercise 2: the step policy adds a fixed number of tasks, CPU drops far below the target, target tracking removes tasks, CPU goes back up and the step policy fires again, so the service keeps going up and down.

### 7. Requests per target or CPU

Three reasons ALBRequestCountPerTarget is better for the enrolment API:

1. It measures demand directly. A student pressing Register is a request, and requests are what the users feel. CPU is only a side effect that also moves for other reasons, like garbage collection or a new task starting up.
2. It scales in a straight line. If the number of tasks doubles, the requests per task halve, so target tracking can work out the right count in one step. CPU stops at 100%, so it cannot show how far past capacity the service is, and in Exercise 4 that is why CPU can only double the count each step.
3. It comes from the load balancer and does not depend on Container Insights, which Floci did not even store in Lab 04.

CPU is better for work without a load balancer or where each unit of work costs very different amounts, for example a worker that generates reports or processes uploaded transcripts, where one job can be 100 times heavier than another.

For requests per target to scale this service badly, the requests would have to stop being equal. If a few students upload large transcripts or run heavy reports, CPU can be at 100% while the request count stays under 1000, so nothing scales out and the service gets slow. It is also bad when the real bottleneck is the database, because more tasks only send more queries to usms-db-01. The metric that would have warned me is the load balancer's TargetResponseTime (and HTTPCode_Target_5XX_Count) rising while RequestCountPerTarget is still below the target, or simply CPU being high while requests are low.

## Review questions

### 1. From one click to one new task

The nine lines from Step 15:

1. A student clicks Register and the requests per target go past 1000, or the work queue goes past 100.
2. An alarm fires and calls a policy.
3. The policy writes a new desiredCount, kept between 2 and 10.
4. ECS starts a task from usms-enrolment:2.
5. The task gets a network interface in usms-private-subnet-a or -b, with no public address.
6. usms-enrolment-sg lets in tcp/80 only from usms-alb-sg.
7. The service registers the task's address in usms-enrolment-tg.
8. The load balancer health checks it, and after the 60 s grace period it gets traffic.
9. Nothing about the task definition, the service or the load balancer changed.

This lab owns lines 1 to 3: the alarms, the policies, and the scalable target with its bounds. The other six needed no change because ECS already knew how to start a task to match desiredCount, the subnets and security groups already accepted any task of that service, and the service already registered every task it started in the target group. Labs 04 and 05 built a system that follows one number, and this lab only adds something that changes that number.

My one sentence answer: auto scaling does not change my application at all, it only changes how many copies of it are running.

### 2. Why the full ARN is rejected

The resource ID is not an ARN. It is a short string that Application Auto Scaling builds itself to name the thing it scales, and for ECS it is `service/<cluster>/<service>`, which is the last part of the service ARN after the last colon. Application Auto Scaling works with many services, and each one names its resources differently, so it uses its own format for every namespace instead of ARNs. For DynamoDB it is `table/<table-name>` (or `table/<table>/index/<index>`), and for Lambda it is `function:<function-name>:<alias>`, so the colons and slashes are different in each one. Passing the full ARN fails validation because it does not match the pattern for the ecs namespace.

The other constructed identifiers in this lab are the ResourceLabel for ALBRequestCountPerTarget, built from the load balancer ARN (everything after `loadbalancer/`) joined with the target group ARN (everything after the last colon), and the managed alarm names, which start with `TargetTracking-` plus the resource ID. In Step 14 the resource ID itself was rebuilt from the service ARN with `${SVC_ARN##*:}`.

### 3. Registering a floor above the current count

The object that makes the change is the scalable target registration, carried out by Application Auto Scaling using the service-linked role. It is different from a policy because no alarm and no metric is involved, there is no cooldown, and it happens straight away. The scaling activity it leaves says the cause was the minimum capacity, not an alarm. On Floci this did not happen at all (Step 6, Exercises 3 and 5), so this part is reasoned.

A 3 a.m. example: the enrolment service is slow, the on-call engineer cannot find the cause yet, and the reactive policies keep scaling in and out. To stop the flapping and buy time, they run register-scalable-target with a minimum of 6. The count goes to 6 at once and cannot drop below it. The person who takes over at 8 can see the evidence in three places: describe-scalable-targets shows MinCapacity 6, which disagrees with configs/lab-04.env; describe-scaling-activities shows the jump to 6 with a cause that is not an alarm; and on real AWS, CloudTrail shows the RegisterScalableTarget call with the engineer's identity and time. The engineer should also write it down in the incident notes, because the floor stays at 6 until someone puts it back, and the service costs more the whole time.

### 4. Managed alarms against my own alarm

The two TargetTracking alarms belong to AWS. They are created when the policy is created, they are changed when the policy changes (for example a new target value), and they are deleted when the policy is deleted. If someone deletes one by hand, the policy silently loses that direction, so with AlarmLow gone it never scales in again, and nothing warns you. usms-enrolment-queue-high belongs to me. Nothing creates, updates or deletes it for me: if I delete the step policy, the alarm stays and points at an ARN that no longer exists, and the cleanup script has to delete it on purpose. What my alarm can do that the managed ones cannot: I choose the metric, the period, the number of evaluation periods, the threshold and the missing data treatment, and I can watch any metric, including a custom one. The managed ones can follow a target value automatically and keep a scale in alarm that is slower than the scale out alarm without me doing anything.

The case for `breaching` on the queue alarm: if the thing that publishes the queue depth stops, that probably means something is wrong, and the safe guess is that the queue is building up while nobody reports it. Treating missing data as breaching makes the service scale out, which is the safer mistake during enrolment. What goes wrong if I am right: when the publisher breaks for a boring reason, like a bad deploy of the reporting job, the alarm stays in ALARM and keeps calling the policy until the service is at the maximum of 10. On Floci I saw how fast that happens in Step 12. The service then costs five times more for no reason, and the real problem, the broken metric, is hidden behind what looks like busy traffic.

### 5. Why reactive scaling is always late

The delays, in order:

1. The metric is published once a minute (Container Insights for CPU, the load balancer for requests), so up to 60 s pass before the first high value even exists.
2. The AlarmHigh needs 3 breaching periods of 60 s, so 180 s. This is set by AWS for target tracking; for my own alarm it is the evaluation periods I chose.
3. The policy runs and writes desiredCount within seconds.
4. ECS places the task, and Fargate needs about 20 to 60 s to start it and pull the image.
5. The service waits for the health check grace period of 60 s (Lab 05, set on the service), and the target group needs its healthy checks (Lab 05, interval 30 s) before it sends traffic.

That adds up to roughly 4 to 6 minutes from the first busy request to new capacity serving users. During that time the tasks that were already running take the whole load.

The three consequences: the minimum capacity is a latency decision, because the floor is what absorbs the first minutes, which is why the floor is 2 (one task per AZ) and not 1. Scale out quickly and scale in slowly, which is why ScaleOutCooldown is 60 and ScaleInCooldown is 300. And for a spike you know is coming, only scheduled scaling can be early, which is why Step 11 adds the weekday morning action at 07:45, before the office opens.

### 6. When two policies disagree

If either policy wants to scale out, Application Auto Scaling scales out to the larger of the two answers. It only scales in when every policy that has scale in enabled agrees. So if CPU is at 30% but requests per target are at 1500, the service scales out, and if CPU is at 70% but requests are low, it still scales out. It only shrinks when both are under their targets. The rule is asymmetric because the two mistakes do not cost the same. Too few tasks means students get errors, and too many tasks only means some extra money for a while.

Two target tracking policies on the same metric are a fault because they can never both be satisfied. With CPU targets of 40 and 60, the service is pushed to 40 by one policy, and the other one, sitting below its 60, keeps asking to scale in but is overruled, so the second policy does nothing except add alarms and confusion. A step policy and a target tracking policy on one metric is the same mistake in a worse form, as I wrote in Exercise 2: the step policy adds a fixed number of tasks, CPU drops far below the target, target tracking removes tasks, CPU goes back up and the step policy fires again, so the service keeps going up and down.

### 7. Requests per target or CPU

Three reasons ALBRequestCountPerTarget is better for the enrolment API:

1. It measures demand directly. A student pressing Register is a request, and requests are what the users feel. CPU is only a side effect that also moves for other reasons, like garbage collection or a new task starting up.
2. It scales in a straight line. If the number of tasks doubles, the requests per task halve, so target tracking can work out the right count in one step. CPU stops at 100%, so it cannot show how far past capacity the service is, and in Exercise 4 that is why CPU can only double the count each step.
3. It comes from the load balancer and does not depend on Container Insights, which Floci did not even store in Lab 04.

CPU is better for work without a load balancer or where each unit of work costs very different amounts, for example a worker that generates reports or processes uploaded transcripts, where one job can be 100 times heavier than another.

For requests per target to scale this service badly, the requests would have to stop being equal. If a few students upload large transcripts or run heavy reports, CPU can be at 100% while the request count stays under 1000, so nothing scales out and the service gets slow. It is also bad when the real bottleneck is the database, because more tasks only send more queries to usms-db-01. The metric that would have warned me is the load balancer's TargetResponseTime (and HTTPCode_Target_5XX_Count) rising while RequestCountPerTarget is still below the target, or simply CPU being high while requests are low.
