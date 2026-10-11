# Lab 05 Exercises: ECS + ALB

**Pema Dolker — DSO303**

## Exercise 1 - Basic: a second path through the same load balancer

Created `usms-results-tg` (target-type ip, HTTP/80, health check path `/`,
matcher `200-399`, deregistration delay 15s) and a listener rule at priority
20 matching `/results` and `/results/*`, forwarding to it. Tagged
`Project=USMS, Tier=app, Lab=05, Service=results` on both objects. No second
ECS service was created and nothing was registered to the target group by
hand - it is correctly empty, since no service exists to populate it yet.

`describe-rules`, sorted by priority, shows three entries in the correct
evaluation order: priority 10 (`/alb-health` -> fixed-response 200), priority
20 (`/results`, `/results/*` -> usms-results-tg), then the default action
(-> usms-enrolment-tg). `describe-target-health` on `usms-results-tg` returns
an empty list, and `describe-target-groups` confirms it is attached to one
load balancer (`LBs: 1`).

One implementation note: `describe-rules`' top-level `Conditions[].Values`
field came back empty for a path-pattern condition in this Floci build - the
values are populated under `Conditions[].PathPatternConfig.Values` instead.

Neither object was recorded in `configs/lab-05.env`, as instructed - Exercise
4 removes them. Removed in Exercise 4: both the priority-20 rule and
`usms-results-tg` were deleted and confirmed gone (see Exercise 4 below).

**Hint question - what would a request to /results receive right now?**
A request to `/results` would receive a `503 Service Temporarily Unavailable`
from the load balancer itself - the rule correctly matches and forwards to
`usms-results-tg`, but with zero registered targets there is nothing to route
the request to. Different from a `404` (no rule matched) or a `502` (a target
answered badly) - `503` means a destination existed in principle but no live
target could serve it.

## Exercise 2 - Intermediate: repair the verification script you broke

The original check asserted one specific expression of a general property:
that the enrolment tasks accept traffic only from a named security group,
never a raw CIDR, sourced from whichever tier is their legitimate client.
Step 13 changed WHO that client is (the load balancer, not the web tier)
without changing the property itself, so the check needed updating, not
deleting. Patched `verify-lab-04.sh` to: (1) source `configs/lab-05.env`
(tolerant of it not existing, matching the file's existing style), (2) add
`: "${USMS_ALB_SG:=none}"` alongside the script's other defaults, (3) rewrite
the check to assert `usms-enrolment-sg` is sourced from `usms-alb-sg`, and
(4) add a second check immediately after asserting `usms-app-sg` is no
longer a source - a check that only confirms the new state would still pass
if both rules existed side by side.

Result: `PASS=38 FAIL=1`, failing on the new `usms-alb-sg` source check. This
is not a real failure of the architecture - `authorize-security-group-ingress`
for that rule was confirmed to succeed independently, twice. It is the same
structural limitation already documented in `notes/lab-05-notes.md` (Steps 9,
13, 17, Section 9): this Floci build cannot reliably read nested
`UserIdGroupPairs` content back out of `describe-security-groups`, and
separately, `revoke-security-group-ingress` is a confirmed no-op on this
build, so the Step 13 cutover itself never actually removed the `usms-app-sg`
rule at the data level, however many times the command reports success. The
check's logic is correct for real AWS; it cannot pass cleanly on this build
regardless of further retries. Per the submission checklist's own alternate
path, this is reported as `PASS=38 FAIL=1` with the failure explained, not
forced to `FAIL=0`.

Committed with a message explaining the architectural reason for the change,
not the line diff.

## Exercise 3 - Problem solving: a load balancer report tool

Built `scripts/utilities/usms-lb-report.sh`. Discovers every ALB named
`usms-*` with no hard-coded ARNs; walks listeners, then rules, then target
health, three levels of `describe-*` calls deep. Rules are sorted into
numeric-priority and the literal `default` rule separately in `python3`
(priority is a string and the default rule's priority is the word `default`,
so a plain lexical sort misplaces it), with the default always printed last.
`set -e` is deliberately omitted - an empty rule set, a listener with no
non-default rules, and a target group with zero targets are all valid states
to describe, not errors to abort on.

Output matched the lab's example format exactly: priority 10 -> fixed-
response 200, priority 20 -> `usms-results-tg (0 targets, 0 healthy)`,
default -> `usms-enrolment-tg`. One real discrepancy the report tool
surfaced rather than hid: `usms-enrolment-tg` showed 3 targets against a
`desiredCount` of 2 - a leftover task from an earlier `force-new-deployment`
call that this build never fully deregistered, consistent with Step 14's
finding that `force-new-deployment` is a no-op here. Verified identical
output running from `~` and from `labs/lab-05-ecs-alb/`.

## Exercise 4 - Challenge: the exposure review

**What changed.** The network path to the enrolment API went from
`usms-web-01 -> usms-enrolment-sg` directly, to `usms-web-01 -> usms-enrolment-alb
(internet-facing, public subnets) -> usms-enrolment-tg -> tasks`. The security
group chain went from `usms-enrolment-sg` admitting `usms-app-sg` directly, to
`usms-enrolment-sg` admitting `usms-alb-sg` (though per Exercise 2's finding,
the old `usms-app-sg` rule was never actually removed at the data level on
this build, despite the command reporting success - architecturally the
intent and the correct commands are both in place).

**Internal vs. internet-facing.** `--scheme internal` would change Step 5's
command only in that one flag (nodes would still need two AZs, but could sit
in the private subnets instead of public ones); the DNS name would still
resolve, but only to private addresses reachable from inside the VPC - nothing
about the listener, target group, or health check configuration changes.
Given the portal (`usms-web-01`) is the only known client and it is inside the
same VPC, `internal` is the right recommendation: it removes the only
`0.0.0.0/0` rule in the whole architecture while costing nothing in
capability. The other side in two sentences: if USMS plans to let students
check enrolment status directly from their own devices, not just through the
portal, without a client VPN, internet-facing becomes unavoidable, and
reversing the choice later means re-provisioning the load balancer rather than
editing one flag.

**Exposure delta**

|  | Before this lab | After this lab |
|---|---|---|
| What can reach the load balancer | n/a - no load balancer existed | Anything on the internet, tcp/80 |
| What can reach the tasks | `usms-app-sg` (i.e. `usms-web-01`) only | `usms-alb-sg` only |
| What can reach the tasks directly | `usms-web-01`, by address, directly | Nothing - the direct rule was removed in Step 13 |

**Monthly cost estimate** (US East, N. Virginia pricing). An ALB is billed at
$0.0225/hour flat, plus $0.008 per LCU-hour, billed on whichever of four
dimensions (new connections/sec, active connections/min, processed GB/hour,
rule evaluations/sec) is highest that hour - for a low-traffic internal API
like this one, rule evaluations is the dimension that dominates, not
bandwidth, because request volume is tiny but every request is still
evaluated against every rule. Idle: 730 hours x $0.0225 = $16.43/month, plus a
fraction of an LCU (well under 1 LCU-hour/month at near-zero traffic) ~=
$16.50-17/month total. Under moderate load the estimate stays close to the
idle figure, since LCU charges only become material at real production
volume. For comparison, the Fargate tasks cost $0.0405/vCPU-hour +
$0.00445/GB-hour; running 24/7 at this lab's task sizing, two small tasks cost
roughly the same order of magnitude as the load balancer itself. (Sources:
AWS Elastic Load Balancing pricing, AWS Fargate pricing.)

**HTTPS plan.** In order: (1) request a public TLS certificate for the ALB's
domain from AWS Certificate Manager (ACM) - issuance and renewal of public
certificates are free; (2) create a DNS validation CNAME record for the
domain, which has to be created outside AWS by whoever owns DNS (ACM supplies
the record, it does not create it); (3) add an HTTPS:443 listener on the ALB
referencing that certificate; (4) add a listener rule on the new 443 listener
mirroring the existing routing; (5) on the existing HTTP:80 listener, change
the default action's type from `forward` to `redirect` (to HTTPS, same
host/path, 301), so a plaintext request never reaches a target. The Step 4
"Your turn" opened port 443 on `usms-alb-sg`, which only lets traffic *reach*
the load balancer on that port - the certificate and the 443 listener are
what make anything *answer* on it.

**The tidy-up.** `usms-results-tg` and its priority-20 rule, from Exercise 1,
were deleted (rule first, then the target group, in dependency order) and
confirmed gone via `describe-rules`.

## Exercise 5 - Integration: the ResourceLabel hand-off to Lab 06

Built `scripts/utilities/usms-resource-label.sh`, deriving the ResourceLabel
string purely from the API (never a hard-coded identifier): the load
balancer's ARN suffix is isolated with `${LB_ARN##*:loadbalancer/}` (strip up
to the fixed `:loadbalancer/` marker), while the target group's suffix is
rebuilt as `targetgroup/${TG_ARN#*targetgroup/}` - the two need different
treatment because the target group's marker word (`targetgroup`) has to be
kept in the result, while the load balancer's marker is discarded entirely.
Validated the result has exactly six slash-separated segments and starts
with the literal `app` (an NLB's equivalent would start with `net` instead -
the segment names which load-balancer type produced the ARN).

Appended `USMS_ALB_RESOURCE_LABEL` to `configs/lab-05.env`, derived rather
than typed. Wrote `outputs/lab-05-lab04c-readiness.txt` with the label, both
ARNs, the scalable resource ID, the scaling dimension, current desired
count, and a timed `force-new-deployment` measurement. That measurement
(~1.6 seconds) is not meaningful on this build: per Step 14's finding,
`force-new-deployment` is a confirmed no-op here, so the timer measured API
acknowledgment latency, not a real task replacement. Recorded AWS's
documented Fargate startup figure instead for Lab 06's cooldown sizing to
reference.
