# Lab 05 Notes - ECS + ALB

## Step 3 support path: Path A - full
All ELBv2 and ECS integration probes returned SUPPORTED (describe-load-balancers,
create-load-balancer skeleton, describe-target-groups, create-target-group skeleton,
describe-listeners, describe-account-limits, ecs update-service skeleton,
ecs describe-services). Proceeding with every step as written.

## Verify baseline entering Lab 05
Lab 02 FAIL=1, Lab 03 FAIL=4, Lab 04 FAIL=1 - all pre-documented in their own
reports as known benign Floci limitations (SG group-reference not persisting,
attach-volume/create-image unsupported, user-data readback, outputs/.env empty
value from USMS_WEB_AMI=None).

## Step 4 "Your turn" - HTTPS gap
Opening tcp/443 on usms-alb-sg only opens the firewall; nothing is listening on
that port yet, because this load balancer has no HTTPS listener and HTTPS
listeners require a TLS certificate as a mandatory parameter. The missing pieces
are (1) an HTTPS listener on the ALB and (2) a certificate to attach to it. AWS
gives the listener for free - it's just another create-listener call, no extra
cost. The certificate is the one you have to obtain yourself: AWS Certificate
Manager issues and renews public certificates at no charge, but it still
requires you to prove you control a real domain name (DNS or email validation)
before it will issue one - something no API call can manufacture on your behalf.

## Step 6 "Your turn" - health check matcher
(a) A service that enforces login by redirecting / to /login (a 301 or 302) would
fail the strict 200 matcher forever even though the application is working
correctly end to end - the health check path itself just happens to redirect.

(b) That would be a bug in the script, not in my work. A verification script's
job is to check that the configuration matches what was deliberately decided,
not to enforce one specific value as universally correct - 200-399 is a
legitimate, documented choice for a service whose health endpoint redirects,
so a script that fails on anything but the literal default 200 is testing its
own assumption about the matcher rather than testing whether the matcher is
*wrong*.

## Step 10 - update-service does not persist loadBalancers
On this Floci build, aws ecs update-service accepts --load-balancers and
--health-check-grace-period-seconds without error but silently drops both -
neither the update-service response nor a follow-up describe-services shows
them, not even as null. Confirmed with a disposable probe service: the same
flags passed to create-service persist correctly. Workaround: deleted and
recreated usms-enrolment-svc with the load balancer attached at creation time,
using the same task definition (usms-enrolment:2), desired count, subnets and
security group as the original. This is a stronger limitation than the lab's
Path B description (which only expected target *health* to fail) - here the
control-plane attachment itself required a different API call shape to stick.

## Step 10 addendum - grace period also not returned
Even on create-service, healthCheckGracePeriodSeconds is accepted (no error)
but not returned by describe-services - same "accepted but not returned"
pattern as Lab 04's logConfiguration, this time on a load-balancer-related
field rather than a logging one. loadBalancers itself persisted correctly,
so this is narrower than the original Step 10 problem, not a sign the
recreate didn't work.

## Step 11 - targets registered and healthy on first poll
Both tasks (172.21.0.3, 172.21.0.4) registered into usms-enrolment-tg and
reported State: healthy immediately, better than the lab's "Path B" prediction
of targets staying initial/unused. Treating this cautiously per Section 12.2 -
a healthy status without a confirmed real HTTP response could be Floci being
generous rather than actually serving traffic. Step 12's curl test is what
decides this honestly.

Recurring known-null fields hit again, no new issue: deployments (length()
crash, same as before), events (null, same as Lab 04), healthStatus and the
attachments privateIPv4Address path on describe-tasks (both None - IPs
confirmed instead via describe-target-health directly).

## Step 11 "Your turn" - scaling without manual target management
If the service did not register its own targets, I would have had to call
register-targets by hand with the new task's IP every time desiredCount
increased, and deregister-targets by hand every time it decreased - for every
single scaling event, forever.

## Step 12 - control-plane proof vs data-path proof
curl against the ALB's DNS name fails outright: the name does not resolve at
all (getent/python socket lookup both fail), and curl returns http_code=000.
This confirms the data path is NOT served on this Floci build, despite every
control-plane object (listener, target group, service attachment, firewall
chain) being correctly wired and, per Step 11, targets even reporting
"healthy". That "healthy" status is therefore a control-plane fact, not proof
of a served request - exactly the trap Section 12.2 warns about.

The 5-step proof chain in outputs/lab-05-path-proof.txt is the actual evidence
for this lab: listener forwards to the correct target group; target group is
correctly typed and configured; the two registered targets are real task
addresses (flagged as "not in a Lab 02 subnet" only because Floci uses its own
Docker network range, same limitation as Lab 03); the service correctly
attached itself; and the security group chain exists even though its display
is lost to the same UserIdGroupPairs bug seen in every previous lab.

Conclusion: this lab sits on Path A for the control plane and Path B for the
data path - a split the lab's own Step 3 framework doesn't quite have a single
letter for, but Section 12.2 anticipates exactly this combination.

## Step 13 - revoke-security-group-ingress does not work on this build at all
Three separate revoke attempts failed to remove any rule, despite each
returning Return: True:
  1. --security-group-rule-ids None (a bug of my own - the literal word "None"
     from a failed ReferencedGroupInfo filter, itself caused by the group-
     reference display bug seen in every prior lab)
  2. --ip-permissions matching the exact original rule content
  3. --security-group-rule-ids with the two confirmed, correct pre-existing
     rule IDs (sgr-e1d02f8b7ba560a15, sgr-dfbe75fbe4dd2c34e), read directly
     from describe-security-group-rules immediately beforehand
All three reported success. A recount after each attempt showed the rule
count on port 80 unchanged at 3 every time. This is a stronger failure mode
than anything seen before in this course: not a null field, not a lost
display value, but an API call that misreports its own success unconditionally.

Conclusion: the security-group half of the Step 13 cutover cannot be
demonstrated as a live state change on this Floci build. The command issued
was correct AWS CLI usage and represents the right architectural action -
removing direct usms-app-sg access now that usms-alb-sg is the only
intended path - but the backend does not honor deletion of security group
ingress rules at all. usms-enrolment-sg will continue to show 3 port-80
rules (app-sg, alb-sg, and one unexplained pre-existing duplicate) for the
remainder of this lab and any later verification against it.

## Step 14 - force-new-deployment is also a no-op on this build
list-tasks before and after --force-new-deployment returned the identical
five task ARNs (two RUNNING, three STOPPED from earlier events), and the two
registered target IPs (172.21.0.4, 172.21.0.5) were unchanged across a
3m39s gap. The command returned success with no error, but no task was
actually replaced.

This is the third update-service-adjacent operation in this lab found not to
work on this build: Step 10 (--load-balancers/--health-check-grace-period-seconds
not persisted), Step 13 (revoke-security-group-ingress a no-op), and now
--force-new-deployment. The one update-service field confirmed to work
correctly is --desired-count (Step 11). Could not observe the
initial -> healthy -> draining sequence described in the lab's concept block;
recording the architecture and mechanism from the lab text, consistent with
how Step 3 Path B is meant to be handled, since no live rolling deployment
could be produced here regardless of method.

## Step 15 - rule condition Values lost on read-back
describe-rules shows Values: [] for the path-pattern condition instead of
["/alb-health", "/alb-health/*"], even though the rule was created correctly
(conditions JSON validated before the call, and the rule's other fields -
Priority 10, fixed-response, status 200 - all read back correctly). Same
class of bug as UserIdGroupPairs/IpRanges losing nested array contents on
this build. curl against both paths returned 000, consistent with Step 12's
finding that this build has no data path.

## Step 16 - persistence proven, with one honest gap
diff of pre/post-restart captures came back empty: ALB, target group (full
health check config), listener, rule, service's loadBalancers attachment,
and usms-alb-sg all confirmed unchanged across a full Floci container
restart, with every ARN re-derived from the API rather than reused from
shell variables.

Caveat: the usms-enrolment-sg query crashed with the same length()-on-null
error in both captures (same bug as Step 12/13), so that specific object was
NOT actually covered by the diff - its rule-level state during restart
remains unverified, though describe-security-group-rules checks done
separately in Step 13 are unaffected by this and stand on their own.

## Step 18 - listener ARN escaping broke in this shell
The lab's prescribed \` escaping for the nested JMESPath inside the unquoted
heredoc did not survive correctly in zsh - the literal backslash reached the
query string instead of being stripped, producing a JMESPath parse error.
Fixed by computing LISTENER_ARN as a plain command outside the heredoc (the
same query that already worked correctly in Step 16) and referencing the
variable inside the heredoc instead of re-querying with embedded backticks.
USMS_SVC_GRACE_PERIOD remains None, consistent with the Step 10 finding that
healthCheckGracePeriodSeconds is never persisted on this build regardless of
API call used.

## Section 9 - verify-lab-05.sh results and one false pass
PASS=45 FAIL=4. All four FAILs trace to limitations already documented in
this lab: the UserIdGroupPairs display bug (Steps 9/13), grace period never
persisting (Steps 10/18), and deployments returning null entirely (Step 14).

The "cutover done: usms-enrolment-sg no longer admits usms-app-sg" check
PASSES, but this is a false positive, not real evidence - describe-security-
group-rules still shows 3 ingress rules on usms-enrolment-sg, confirming the
app-sg rule was never actually removed (consistent with Step 13's finding
that revoke-security-group-ingress is a no-op on this build). The verify
script's check and the earlier "admits usms-alb-sg" FAIL are both blind to
the same underlying data for the same reason - one happens to read as pass,
the other as fail, neither is trustworthy evidence either way. The rule-ID
count from describe-security-group-rules is the only reliable evidence for
this group's actual state on this build.

## Step 17 - cutover confirmed broken, carrier filter also broken
describe-security-group-rules independently confirms (second time, different
session) that usms-enrolment-sg still carries 3 port-80 ingress rules -
the usms-app-sg rule was never removed, settling the Step 13 question for
good. The "CUTOVER CONFIRMED"-style checks (both this lab's own Step 17
logic and verify-lab-05.sh's "cutover done" check) cannot be trusted on this
build; only describe-security-group-rules's raw rule count is reliable here.

Block 3's instance.group-id filter returned no match for usms-web-01 despite
the instance definitely carrying usms-app-sg (confirmed in Lab 03/04).
Worked around with a direct describe-instances --instance-ids call instead -
another Floci filter limitation, not an architecture problem.

elbv2 describe-tags, by contrast, worked correctly: both usms-enrolment-alb
and usms-enrolment-tg show Lab: 05 as expected - one of the few "accepted
and genuinely stored" results in this lab, worth noting for balance against
the several "accepted but not returned" findings elsewhere (Steps 10, 14).



## Correction to Step 17 block 3 - not a filter bug, instance was stopped
The earlier "carrier: None" result was NOT a Floci filter limitation as I
first assumed. aws ec2 describe-instances --instance-ids confirmed
usms-web-01's actual State was "stopped" - the instance-state-name=running
filter was working correctly and correctly found nothing. Security group
membership was unaffected (still carries usms-app-sg). Most likely cause:
Step 16's floci-down/floci-up cycle preserved all AWS object state (as
proven) but did not resume the instance's running status automatically.
Restarted it with ec2 start-instances to restore the state the lab's
Step 17 narrative assumes.

## Exercise 2 - the new check hits the same UserIdGroupPairs bug
The patched check "usms-enrolment-sg is sourced from usms-alb-sg (not a CIDR)"
reads IpPermissions[0].UserIdGroupPairs[0].GroupId - the exact field already
documented in Section 9 as unreliable on this build. verify-lab-04.sh reports
PASS=38 FAIL=1 on this check, not because the rule is missing (authorize-
security-group-ingress confirmed success twice, independently) but because
this build cannot reliably read nested UserIdGroupPairs content back, the
same limitation as Steps 9/13/17. The check's logic is correct for real AWS;
it cannot pass cleanly on this build regardless of further retries. The
submission checklist's alternate path applies here: "PASS=48 FAIL=1 with the
failure explained" (now PASS=38 FAIL=1, counts shifted by the Exercise 2
patch), not FAIL=0.

## Review Questions

**1.** Lab 04's security-group rule sourced from `usms-app-sg` rather than an
address, and this lab's load balancer, are both solving the same underlying
problem: how do you refer reliably to something whose identity keeps
changing underneath you. A Fargate task's IP address is temporary - the task
can stop and restart with a new one at any time - so anything that names it
directly (a firewall rule, a client configuration, a DNS record) is wrong
the moment that happens. The security-group rule solves this at the firewall
layer, by naming the *group* a task belongs to instead of the task itself;
the load balancer solves it one layer up, at the routing layer, by giving
clients a single stable name to call while the set of real addresses behind
it changes freely. Both are instances of the same general pattern:
indirection with an owner, where something else (ECS, in both cases) is
responsible for keeping the indirection layer's idea of reality up to date.
A third example of the same pattern elsewhere in computing is DNS itself - a
hostname stays constant while the IP address it resolves to can change at
any time, and the DNS system (not the client) is what's responsible for
keeping that mapping correct.

**2.** The inference is unsound because the target group health check and
the container health check are answering two different questions, and
"unhealthy" from the load balancer only answers one of them. The target
group health check asks whether the application is *reachable over the
network* - it cannot distinguish between "the application has actually
crashed or is serving errors" and "the application is running completely
fine, but something in the network path (a missing security-group rule, a
wrong port, a bad route) is blocking the load balancer's own request from
getting there." The field that resolves this ambiguity is the task's own
ECS health status (from the container health check, if one is configured,
or just the task's RUNNING/STOPPED state otherwise): if ECS reports the task
healthy and running while the target group reports it unhealthy, the
application is fine and the problem is the network path; if ECS also
reports it unhealthy or the task is crash-looping, the application itself is
the problem. The diagnostic sequence I would follow is: check the task's ECS
health/status first; if it disagrees with the target group's verdict,
suspect the network path (security groups, the health check's configured
port and path) before touching the application code at all; only if ECS
agrees the task is unhealthy would I go look at the application or its
logs.

**3.** The absence of `update-target-group-target-type` tells you that AWS
treats a target group's target type as part of its *identity*, not its
configuration - changing it would change what kind of thing a "target" even
means for that group (an IP address vs. an instance ID vs. a Lambda ARN),
which isn't a parameter tweak, it's a different object. This is the same
distinction Lab 04 drew for task definition revisions: a given revision
number is a permanent, immutable description of one deployable unit, and
"updating" it really means registering a new revision and moving traffic to
it, not mutating the old one in place. Two other fields in this lab that
behave the same way - fixed at creation, no update call exists - are a
target group's VPC (stated explicitly in Section 8.2: "a target group
belongs to exactly one VPC, forever") and its protocol/port combination,
both of which define what the target group fundamentally *is* rather than
how it currently behaves. One field that looks like it should be similarly
fixed but is not: `deregistration_delay.timeout_seconds`. It feels like a
core, defining property of the target group's behavior, but it's actually
just a mutable attribute - Exercise 1 changed it from the default after
creation with a plain `modify-target-group-attributes` call, no recreation
needed.

**4.** When ECS decides to stop a task, the target group first stops routing
*new* requests to it, but a request that already arrived and is in flight
keeps being served - the load balancer does not hang up on it. Two timers
govern what happens next, configured in two different places. The target
group's own `deregistration_delay.timeout_seconds` (default 300, this lab's
value 30) is how long the load balancer continues to allow in-flight
connections to that target to finish before it's fully removed from
rotation. Separately, the container's own `stopTimeout` (set in the task
definition, not the target group) is how long ECS waits after sending a
graceful shutdown signal to the container before force-killing it. For the
in-flight request to succeed, the container has to finish responding before
whichever of those two timers runs out first - if `stopTimeout` is shorter
than how long the application takes to finish the response, the container
can be killed mid-response even though the load balancer was still willing
to wait. With `deregistration_delay` left at its default of 300 seconds
instead of this lab's 30, an in-flight request would have a much larger
window to complete safely, but it also means ECS has to wait that much
longer before a task being replaced is considered fully drained - a rolling
deployment or a scale-down would take noticeably longer to finish, since
each outgoing task lingers in the "draining, still allowed to finish
in-flight work" state for up to five minutes instead of thirty seconds.

**5.** The case for updating the verification script immediately is that an
assertion which no longer matches reality is actively misleading - every
time it fails, whoever is reading the output has to re-derive, from memory
or from digging, whether this is an expected failure or a real regression,
and that cost is paid every single run, forever, until someone fixes it. The
case for leaving it failing and documented is that the failure is itself
evidence: it's a visible, timestamped record that something about the
architecture changed on purpose, and fixing it too quickly - especially
right after making the change - risks writing a new assertion that quietly
encodes a mistake, before anyone's had a chance to notice if the change
itself was wrong. On a system with four other engineers, I would update the
check immediately (which is what Exercise 2 actually does): with that many
people touching the same scripts, you cannot rely on everyone reading the
same notes file or remembering a conversation from last week, and a stale
documented failure that one person understands is only reliable to that one
person - everyone else either wastes time re-diagnosing it or, worse, learns
to ignore red output from this script in general. On a system with just one
engineer, there's more room to let it sit failing-and-documented for a
while, since the person reading the failure and the person who wrote the
explanation are the same person with full context - but even then, the
longer it sits, the more it risks becoming something even I no longer
remember clearly.

**6.** Both can be true at once because "internet-facing" and "no public
address" describe two different objects in two different subnets, connected
by a routing boundary that only runs one way. `usms-enrolment-alb`'s nodes
sit in the public subnets (`usms-public-subnet-a`/`-b`), which have a route
to `usms-igw` via `usms-public-rt`, so those nodes get public addresses and
are directly reachable from the internet. The tasks sit in the private
subnets, which have no route to `usms-igw` at all - their only route out is
through `usms-nat` (sitting in a public subnet, with its own Elastic IP),
which allows outbound-only connections (for pulling container images, for
example) and gives the tasks no inbound reachability whatsoever. An attacker
who compromised the load balancer's configuration (its listener and rules)
could redirect, intercept, or reroute any traffic that passes through that
listener - effectively full control over what the enrolment application
receives and returns, for anything exposed on the port(s) that listener
serves. What they could not reach is anything outside that blast radius:
other private-subnet resources like `usms-db-01` are not reachable just by
controlling the ALB's config, because the ALB's security group and the
tasks' security group only grant the specific port-80 path this lab set up
- reaching anything else would require separately compromising those other
security groups or resources directly. If the tasks had been given public
addresses instead, this whole containment would collapse: the tasks would
be reachable directly from the internet with or without the load balancer
working correctly, which means any security-group mistake on the tasks
themselves becomes internet-exposed immediately, rather than being
contained behind the one deliberately-configured front door.

**7.** Request count per target is a better scaling signal for a web API
because it directly measures the thing that actually matters for a web
service under load - how many requests each task is currently handling -
whereas CPU utilization can stay misleadingly low even while the service is
failing to keep up, specifically when tasks spend most of their time waiting
rather than computing: blocked on a slow database query, a downstream API
call, or other I/O. A service can be completely saturated with requests it
cannot answer in time while its CPU graph looks nearly idle, which means
scaling on CPU alone would fail to add capacity at exactly the moment it's
needed. CPU is the better signal in the opposite situation: a genuinely
compute-bound workload, where the cost of a request is dominated by actual
processor work rather than waiting - something like image processing,
encryption, or video transcoding, where a single request can occupy a core
for seconds and request *count* says very little about real load, since
requests vary wildly in cost. For `ALBRequestCountPerTarget` to scale the
enrolment application badly, the application would have to have highly
non-uniform request costs - for example, if most traffic were cheap,
near-instant lookups but a small fraction of requests triggered expensive
operations like complex database joins or report generation. In that case,
request count would no longer track real resource consumption, and the
scaling policy could either over-provision (many cheap requests triggering
a scale-out that isn't needed) or under-provision (a surge of expensive
requests that looks numerically small but saturates the service) - the same
failure mode CPU has, just inverted.

## Update: Floci 1.5.34 -> 2.2.0 (15 Oct 2026)
- Upgraded because Lab 06 needs Application Auto Scaling (not in 1.5.34).
- Fixed on 2.2.0: healthCheckGracePeriodSeconds now reads back (60); deployments no longer null; USMS_SVC_GRACE_PERIOD=60.
- Still broken: UserIdGroupPairs empty on security-group rules (use describe-security-group-rules for counts).
- verify-lab-05: PASS=45 FAIL=4 -> PASS=48 FAIL=1 (SG source check only).
- Not yet re-tested on 2.2.0: revoke-security-group-ingress, force-new-deployment, rule Values read-back, update-service --load-balancers.