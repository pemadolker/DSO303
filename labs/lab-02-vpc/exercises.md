
## Exercise 4 — Design and Defend: Exam-Results Service

### Requirements recap
- Reachable by staff on campus only (campus CIDR `10.10.0.0/16`, arriving over VPN)
- Reads the transcripts database
- Must never be reachable from the public internet
- Needs outbound access to download security patches

### Subnet placement
The exam-results service goes in **`usms-private-subnet-a`** (or `-b` for HA), reusing the
existing private tier rather than creating a new subnet. It needs no public IP and no route
to an internet gateway — campus traffic arrives over VPN with private/campus source
addresses, not through the public internet path, so the private subnet's existing routing
(no IGW route, NAT gateway for outbound-only patch downloads) already satisfies every
requirement without modification.

### Security groups
**New: `usms-exam-sg`**
- Inbound: TCP 443 from `10.10.0.0/16` — HTTPS access from campus over VPN. Justification:
  campus staff need HTTPS access to the exam service; the CIDR is the campus range the
  requirements specify VPN traffic arrives from.
- Outbound: default allow-all is sufficient — the exam service needs to reach the DB tier
  and the NAT gateway for patches; no inbound-facing restriction is needed on egress since
  security groups are stateful and NACLs already backstop the subnet.

**Modify: `usms-db-sg`**
- Add inbound: TCP 5432 from `usms-exam-sg` (group reference, not CIDR — consistent with the
  existing `usms-app-sg` rule). Justification: the exam service reads transcripts, so the DB
  tier must accept connections from it the same way it already does from the web tier.

No new rule is added to `usms-exam-sg` for the database connection — the *outbound* leg is
covered by the default allow-all-outbound rule every security group gets automatically; only
the *inbound* side on `usms-db-sg` needs an explicit rule.

### NACL
**No change needed.** `usms-private-nacl` already permits TCP 5432 inbound from
`10.0.0.0/16`, ephemeral-port return traffic, and TCP 443 outbound for patches. Since the
exam service lives in the same private subnet as the existing database tier, it inherits
this NACL and every existing rule already covers its traffic pattern (DB access in, HTTPS
patches out, ephemeral-port replies both ways). Adding a redundant rule for `10.10.0.0/16`
specifically would be unnecessary — the NACL is subnet-wide and already permissive enough
within the VPC's own CIDR for east-west DB traffic; the campus VPN traffic terminates before
reaching this subnet's NACL (it arrives already translated to an internal address by the VPN
gateway, which is out of scope for this VPC).

### NAT gateway — one vs two, cost/availability trade-off
**Recommendation: keep the single NAT gateway in AZ a for now.** As of this course, a NAT
gateway typically costs approximately $0.045/hour plus $0.045/GB processed (illustrative
AWS on-demand pricing — actual rates should be confirmed against current AWS pricing, as
they vary by region and change over time) — roughly $32/month in hourly charges alone before
any data processing, which the lab document itself flags as often the single largest line
item on a small VPC's bill.

Adding a second NAT gateway in AZ b would double this fixed cost to roughly $64/month before
data charges, in exchange for eliminating a single point of failure: currently, if AZ a goes
down, `usms-private-subnet-b` loses outbound internet access even though its own instances
are healthy, because NAT gateways are zonal.

For a university exam-results system, this is a real trade-off with no universally correct
answer: exam periods are typically short, high-stakes windows where an outage has outsized
impact, which argues for the redundant NAT gateway during those windows specifically. Outside
exam periods, the extra $32/month for redundancy that's rarely exercised is harder to justify
against a modest, defined budget. A middle path — provisioning the second NAT gateway only
during exam windows, or accepting the AZ-a single point of failure but load-testing failover
procedures in advance — is worth considering rather than treating "one vs two, permanently"
as the only choice.

### What to delete
Per this lab's own convention, in dependency order:

1. **`usms-public-subnet-c`** (Exercise 1 practice subnet)
   - What's deleted: an unused public subnet, no instances, no other resource depends on it
   - Depends on it: nothing
   - Reversible: yes (recreate with the same `create-subnet` call)
   - Effect on later labs: none — it was never referenced anywhere in configs/lab-02.env

Deletion command:
```bash
aws ec2 disassociate-route-table --association-id <its rtbassoc-id>
aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_C_ID"
```

No other Exercise 1–4 resource needs deletion — `usms-bastion-sg`, `usms-exam-sg`, and the
network report script are all intended to remain as part of the design.

