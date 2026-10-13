# Lab 06 Exercises: ECS Service Auto Scaling

**Pema Dolker — DSO303**

## Exercises 1-3, 5 - blocked by Path C

Exercises 1, 2 and 3 all require a registered scalable target to attach
policies to, read back managed alarms from, or discover via
`describe-scalable-targets` - none of which exist on this build, since
`register-scalable-target` returns `UnknownOperationException`. There is no
partial version of these exercises that produces real evidence rather than
fabricated output, so they are not attempted here. Exercise 5 is partially
achievable (see its own section below) since parts of it depend only on
IAM/ECS, not Application Auto Scaling.

## Exercise 4 - Challenge: the enrolment-week capacity plan

### Is it solved?

Reactive scaling will absorb the sustained roughly-double traffic across
the three-week window well, since that level of increase is well within
what the CPU and request-count target tracking policies can reach given
enough time. It will not help with the first twenty minutes of each cohort
day, because every reactive mechanism - alarm evaluation, cooldown, task
start, health-check grace period - takes minutes to respond, and a fortyfold
spike that arrives in under twenty minutes will have already overwhelmed
the service before the first new task is useful. The first twenty minutes
specifically needs capacity to already exist before the spike starts, which
only scheduled scaling can provide.

### Why forty times traffic is not a scaling problem (it's a ceiling problem)

Time from 2 tasks to the ceiling of 10, using this lab's own numbers:
- Alarm evaluation: 3 periods x 60s = 180s (Review Question 5's figure)
- Policy invocation: ~0s additional
- Task start: Lab 05's own measurement was not meaningful on this Floci
  build (it measured API-ack latency, not real provisioning), so this uses
  the documented AWS figure instead - Fargate tasks typically become
  RUNNING well under 60 seconds for a small, already-cached image.
- Health-check grace period: 60s (the Lab 05 Step 10 design value; not
  actually persisted on this build, but this is the intended real-AWS
  number)

Fastest case (target tracking computes the full required capacity in one
evaluation and all 8 new tasks start in parallel): 180 + 60 + 60 = 300
seconds, five minutes, before the full ceiling of 10 tasks is actually
serving traffic - and that is the OPTIMISTIC case. If the policy needs more
than one cooldown cycle to reach the ceiling (ScaleOutCooldown 60s between
successive scale-out actions), the real figure is higher.

Five minutes is already longer than the stated twenty-minute window allows
for "falling over," so the ceiling itself is the real constraint, not the
speed of scaling. The ceiling of 10 tasks, against a request-count target of
1000 requests per target, caps the service at 10 x 1000 = 10,000 requests
per minute, or about 167 requests per second, once it is fully scaled out -
and that is the hard limit regardless of how much reactive scaling tries.
Whether 167 req/s is enough for "forty times normal traffic" cannot be
answered without knowing what normal traffic actually is - which is exactly
the missing measurement in the "what I need from the lead" section below.

### The ceiling, checked against Lab 02

Both private subnets are /24: `10.0.3.0/24` (subnet a) and `10.0.4.0/24`
(subnet b), 256 addresses each. AWS reserves 5 addresses in every VPC
subnet regardless of size - the network address, the VPC router address,
the address reserved for the Amazon-provided DNS server, one reserved for
future use, and the broadcast address (which AWS does not support but still
reserves) - documented in the Amazon VPC User Guide's "VPC and subnet
sizing" page. That leaves 256 - 5 = 251 usable addresses per subnet, 502
across both. Every `awsvpc`-mode Fargate task consumes exactly one address
for the duration it runs.

Even accounting for `usms-db-01`'s ENI and the existing enrolment tasks
already in these subnets, the current usage is a handful of addresses out
of 502 available - nowhere close to exhausting them at 10 tasks, or even at
several hundred. The subnets could support a ceiling far higher than 10;
10 is a deliberate cost/safety guard against a runaway policy, not a
network constraint. The real limit on how high the ceiling could safely go
is cost and the downstream capacity of whatever the enrolment tasks
themselves depend on (the database, external APIs), not address space.

### Capacity plan

Scheduled actions for the three cohort days (dates unknown from the
project lead's message - placeholder dates used, to be confirmed):
- `cron(0 7 14,21,28 10 ? 2026)` - 07:00 Asia/Thimphu, one hour before each
  cohort's eligibility opens, `MinCapacity=10, MaxCapacity=10` (pin the
  ceiling as the floor for the spike window)
- `cron(0 9 14,21,28 10 ? 2026)` - 09:00 Asia/Thimphu, two hours after each
  spike, reverting to `MinCapacity=4, MaxCapacity=10`

Scheduled actions for the three-week window generally (double traffic):
- `cron(45 6 ? * MON-FRI *)` Asia/Thimphu - raise the floor to
  `MinCapacity=4, MaxCapacity=10` each weekday morning (earlier than this
  lab's existing 07:45 baseline, to be safely ahead of any demand)
- `cron(0 20 ? * MON-FRI *)` Asia/Thimphu - revert to `MinCapacity=2,
  MaxCapacity=10` each evening, matching the existing baseline

Target value changes: lower the request-count target tracking policy's
target from 1000 to roughly 600-700 requests per target during the
enrolment window, so the policy scales out earlier and with more margin,
rather than waiting until each task is nearly saturated.

Ceiling: raise `MaxCapacity` to a higher number (needs the missing baseline
measurement below to size correctly) for the three-week window only, then
revert it afterward.

Reversibility: the scheduled actions are reversible in one command each
(`delete-scheduled-action`); the target-value change is reversible in one
command (re-running `put-scaling-policy` with the original target); raising
and then lowering `MaxCapacity` is two separate one-command operations, not
one - it is not atomic, and forgetting the second command leaves an
inflated ceiling indefinitely, which is itself a cost risk worth flagging
to the lead.

### Monthly cost estimate

<!-- PASTE YOUR configs/lab-04.env cpu/memory VALUES HERE BEFORE FINALIZING -->
Using Fargate on-demand pricing ($0.0405/vCPU-hour, $0.00445/GB-hour, US
East N. Virginia): baseline is 2 tasks continuously; this plan adds, for
three weeks, roughly 2 extra tasks during the daytime scaling window (12
hours/weekday) plus a short burst to 10 tasks for ~2 hours on three cohort
days. [Exact dollar figure depends on the task's cpu/memory - compute once
those values are confirmed.]

CloudWatch costs most people forget: the custom metric `EnrolmentQueueDepth`
already exists (no new cost from this plan), but each additional scheduled
action and any new/adjusted alarms incur CloudWatch's per-alarm monthly
charge (a small number of alarms, negligible compared to the compute cost,
but worth stating as a non-zero line item rather than omitting it).

Assumption stated explicitly: this estimate does not include data transfer,
load balancer LCU costs under the heavier traffic, or any downstream
database capacity the extra tasks might need to pull from - those are
separate budget lines the lead should also ask about.

### What I need from the project lead

1. **The baseline "normal traffic" number** (requests per second or per
   minute) that "forty times" and "double" are multiples of - without this,
   neither the ceiling's sufficiency nor the cost estimate can be stated as
   more than a guess. This is the measurement nobody has taken yet.
2. **The exact dates and times** the three cohorts become eligible, so the
   scheduled actions' cron expressions can be set precisely rather than
   placeholder dates.
3. **Whether the downstream dependencies** (the database behind the
   enrolment API, any external services it calls) can actually sustain 5x
   the normal load - scaling the ECS service to 10 tasks is meaningless if
   the database connection pool or the database itself becomes the next
   bottleneck at that concurrency.

### Tidy-up

No practice policies exist to delete on this build - Exercise 1's
`usms-enrolment-memory-target-tracking` and anything from Exercise 2 were
never created, since both exercises were blocked by the same Path C
limitation. Confirmed via:

```bash
aws application-autoscaling describe-scaling-policies --service-namespace ecs 2>&1 | head -3
```