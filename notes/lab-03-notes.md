# Lab 03 Notes: EC2



`verify-lab-03.sh` finished at **PASS=32 FAIL=4** (the lab expects FAIL=0).
All four failures trace back to this Floci build, not to my configuration,
and two other checks pass for the wrong reason. Both are explained below,
followed by the seven review questions.

![verify-lab-03.sh full output](../screenshots/lab3/verification.png)

## Floci limitations I hit

- **Data volume never attaches.** `attach-volume` returns
  `UnsupportedOperation`. The volume itself (`usms-web-data-vol`, 8 GiB
  gp3) is created correctly, in the right AZ, but `Attachments` stays
  empty. That's why "data volume is attached" and "DeleteOnTermination is
  False" both fail - there's no attachment for either check to read.

  ![create-volume succeeding, attach-volume failing](../screenshots/lab3/image-copy-4.png)

- **No AMI gets created.** `create-image` also returns
  `UnsupportedOperation`, so `usms-web-golden` doesn't exist and
  `USMS_WEB_AMI=None` in `configs/lab-03.env` — which is why "no empty
  values" fails. I left the `None` in rather than editing around it.
  The verify script's "golden AMI exists" check still shows a PASS, but
  that's a false pass: Floci accepts `describe-images --image-ids None`
  without error, so the check doesn't actually prove an image exists.

  ![create-image returning UnsupportedOperation](../screenshots/lab3/step20.png)

- **User data is stored but not returned.** `describe-instance-attribute
  --attribute userData` gives back only the instance ID, no `UserData`
  field at all. I can show the CLI correctly base64-encoded my script on
  the way in (the first bytes decode to `#!/bin/bash`), but I can't show
  the round trip the lab asks for — there's nothing on the read side to
  diff against. The verify script's "has user data stored" check still
  passes, but that's also a false pass: it's just testing that the
  returned string isn't empty, and an empty JSON object still isn't
  empty as a string.

  ![describe-instance-attribute returning only InstanceId, no UserData field](../screenshots/lab3/limitationevidence.png)

- **The private instance still shows a public address.** `usms-db-01`'s
  subnet has `MapPublicIpOnLaunch=False` — I checked the subnet attribute
  directly - but the instance still reports `PublicIpAddress=127.0.0.1`.
  That's a loopback placeholder Floci seems to put on every instance
  regardless of subnet, not a real public address. The subnet
  configuration is correct; only the reporting is wrong.

  ![usms-db-01 describe-instances: Public 127.0.0.1, Profile None](../screenshots/lab3/checkpoint5.png)

- **Private addresses aren't inside the VPC's CIDR at all.** Both
  instances report private IPs like `172.21.0.3`–`172.21.0.6`, which is
  Floci's own Docker network range, not `10.0.1.0/24` or `10.0.3.0/24`
  as the lab's "expected result" shows. Worth flagging on its own —
  it's a bigger gap than just the public-IP placeholder, since it means
  the private-IP field can't be used to confirm subnet placement at all;
  `SubnetId` is the only field that actually proves it.
- **Security-group group-references don't persist**, the same bug from
  Lab 02: `usms-db-sg`'s rule correctly names `usms-app-sg` as its
  source when I create it, but reading it back shows `FromGroup: None`.
  Finding the identical gap a third time, on a new rule in a new lab,
  rules out it being one bad rule — it's how Floci stores
  `UserIdGroupPairs` in general.

  ![Step 17 wiring check: FromGroup None, MISMATCH](../screenshots/lab3/checkpoint5-1.png)

- **Extra instances fail to launch at all.** Both Exercise 1's admin host
  and Exercise 2's `usms-db-02` went from `run-instances` straight to
  `terminated`. The Docker logs behind Floci show why: each instance gets
  its own container with a published host port, and the port was already
  taken —
  `Bind for 0.0.0.0:2201 failed: port is already allocated`.
  So this isn't a quota or config issue, it's Floci running out of free
  host ports for new containers.

  ![Docker logs: Bind for 0.0.0.0:2200/2201 failed, port already allocated](../screenshots/lab3/dk.png)

- **Instances come back stopped after a Floci restart.** After upgrading
  Floci to 2.2.0 and restarting it, `usms-web-01` was `stopped`, which made
  "usms-web-01 is running" fail in `verify-lab-03.sh`. `start-instances` fixed
  it. Real EC2 instances keep running regardless of anything on my laptop; this
  is Floci restarting its instance containers in the stopped state.

- **Not observable at all, reasoning only:** nginx actually running, the
  user-data script executing, the instance fetching credentials from the
  metadata service, and a security group actually blocking a connection.

A couple of smaller things I noticed but didn't independently verify with
a screenshot, so I'm noting them as observed-once rather than confirmed:
`delete-key-pair` returning success without the key actually being
removable (`create-key-pair` afterwards said `InvalidKeyPair.Duplicate`),
and one instance appearing to hold two associated Elastic IPs at once,
which real AWS wouldn't allow.

## Checkpoints

**Checkpoint 3** - permission chain traced, user data sent (not provably
round-tripped, see above):

![Instance -> profile -> role -> policy document](../screenshots/lab3/checkpoint3.png)

**Checkpoint 5** - two-tier wiring:

![usms-db-01 in the private subnet, no profile, no real public address](../screenshots/lab3/checkpoint5.png)
![Security-group and route-table wiring check](../screenshots/lab3/checkpoint5-1.png)

**Checkpoint 6** - persistence across a Floci restart:

![Pre/post-restart comparison, PERSISTENCE PROVEN](../screenshots/lab3/09-persistence.png)

## Review questions

**1. Step 8: what if each of the five inputs had been wrong or missing?**
Each of the five can fail in two ways, missing (doesn't exist) or wrong (exists, but is the wrong one), and they behave very differently.

- **Subnet (Lab 02).** Missing: immediate, `InvalidSubnetID.NotFound`. Wrong: silent. If I had passed `usms-private-subnet-a` by mistake, the web server would launch fine but get no public address and have no route to the internet gateway, so nobody could reach it, and nothing would say why.
- **Security group (Lab 02).** Missing: immediate, `InvalidGroup.NotFound`. Wrong: silent. With `usms-db-sg` instead of `usms-app-sg`, the instance runs but port 80 is closed, so requests just time out.
- **Instance profile (Lab 01).** Missing: immediate, the launch is rejected because the profile name doesn't exist. Wrong: silent and dangerous. Another existing profile would attach a different role, so the server would quietly get someone else's permissions, too many or too few, and I would only find out when an S3 call failed, or never if it had too many.
- **Key pair (Lab 03).** Missing: immediate, `InvalidKeyPair.NotFound`. Wrong: silent until much later. The instance runs perfectly, and the problem only appears the first time someone tries to SSH in with the private key they actually have.
- **User-data script (Lab 03).** This one is always silent. EC2 does not run or check the script at launch, it just stores it, so a typo still gives a successful `run-instances`. The failure only appears after boot, when nginx isn't there, and the only evidence is in `/var/log/cloud-init-output.log` on a machine I may not be able to log into.

The pattern: if something doesn't exist, the API refuses immediately. If it exists but is the wrong one, the API is happy and the failure shows up later as a symptom, which is much harder to trace.

**2. Why is the policy valid when the bucket doesn't exist, and what
changes when it's created?**
An IAM policy is a statement about an ARN pattern, not a reference to a
live object — it says "allow these actions on
`arn:aws:s3:::usms-student-data`" and IAM never checks whether anything
actually exists at that ARN before deciding whether to allow a request.
Today `usms-web-01` already has the permission; there's just nothing to
use it on, which is why my `head-bucket` call returned a 404. The moment
Lab 4 creates the bucket, the permission starts working immediately — the
policy, the role, the instance profile, and the instance don't change at
all. And because this runs through the instance profile, there's never an
access key sitting on the server to begin with.

**3. User data only runs once — why doesn't "restart to redeploy" work,
and what does?**
`cloud-init` runs user data exactly once, at the instance's first boot. A
stop/start cycle, or any later reboot, doesn't trigger it again, because
cloud-init tracks that it already ran for that instance ID. Two things
that do work: bake the deployed app into an AMI and launch new instances
from it (what Step 20 is for), or have a separate mechanism — a systemd
unit or cron job — that pulls the latest version on its own schedule,
independent of whether the instance ever reboots.

**4. Auto-assigned public IP vs. Elastic IP.**
- **Who owns it.** The auto-assigned address belongs to AWS's pool and is only lent to the instance. The Elastic IP is allocated to *my account*, and I decide which instance it points at.
- **When it changes.** The auto-assigned address is released when the instance stops and a different one is given when it starts again. The Elastic IP stays the same through stop/start, and even after the instance is terminated, until I release it.
- **What it costs.** Since 1 February 2024, AWS charges **$0.005 per hour for every public IPv4 address**, whether it is auto-assigned or an Elastic IP, attached or idle. That is about $3.65 a month each (the handout's "$3.60 for an unassociated Elastic IP" is the same rate over 720 hours). So neither is free any more. The difference is that an Elastic IP keeps costing money while it sits unattached, whereas an auto-assigned address simply disappears with the instance.
- **On stop.** The auto-assigned address is gone and anything pointing at it (DNS, a firewall rule on campus, a bookmark) breaks. The Elastic IP stays allocated and comes back attached when the instance starts.

**A failover only possible because of this:** if `usms-web-01` breaks, I launch a replacement from the golden AMI and run `aws ec2 associate-address --allocation-id <usms-web-eip> --instance-id <new-instance>`. In seconds, the same public address points at the new server. DNS, users and the campus firewall never notice. With an auto-assigned address, the replacement would get a brand-new IP and every reference to the old one would have to change.

(On Floci the public address field showed `127.0.0.1` the whole time, so I could not watch the auto-assigned address disappear on stop. This part is reasoned from the lab text, not observed.)

Source: [Amazon VPC pricing, public IPv4 addresses](https://aws.amazon.com/vpc/pricing/).

**5. EBS volumes vs. snapshots across Availability Zones.**
A volume lives in one AZ's own storage fabric, so it can only attach to
an instance in that same AZ. A snapshot is stored at the regional level,
so it can be restored into a new volume in any AZ in the region. For a
system that needs to survive losing an AZ, that means a single volume is
never enough on its own — you need either regular snapshots so a volume
can be rebuilt elsewhere after an outage, or a design that replicates the
data across AZs at the application layer instead of depending on one
volume. (`attach-volume` doesn't work on this build, so I couldn't test
this directly — this answer is reasoned from the lab text.)

**6. Is the six-property check an adequate substitute for actually
testing with curl?**
Mostly, but not completely, and it's worth being precise about which part
it covers. The six checks are the real, ordered dependency chain a
request has to clear — instance running, route to an internet gateway,
gateway attached, security group open, a public address present, NACL
permissive — so if any one of them is wrong, that's a genuine,
fixable problem the checklist catches. What it structurally cannot see is
the seventh link: whether a process is actually alive and listening on
the port. A crashed app, a broken nginx config, or a user-data script that
failed partway through would all pass every one of the six checks and
still be completely unreachable. My own `curl` timed out for exactly that
reason — Floci boots no operating system at all — which is the same class
of fault the checklist can't catch, just for a different underlying cause.

**7. Every difference between `usms-web-01` and `usms-db-01`.**
Both are `t3.micro` from the same AMI, so every difference comes from how and where they were launched.

**Properties of the instance** (chosen at launch, or attached to it afterwards):
- **Security group:** `usms-app-sg` (80, 443, SSH) vs `usms-db-sg` (5432 from the app tier only).
- **Instance profile:** the web server has `usms-ec2-app-profile` (S3 access through the role); the database has none, on purpose.
- **Elastic IP:** `usms-web-eip` is associated with the web server; the database has no stable public address at all.
- **Data volume:** `usms-web-data-vol` was created for the web server (8 GiB gp3 with `DeleteOnTermination=False`); the database has only its root volume. (On Floci the attach failed, but in the design it belongs to the web server.)
- **User data:** the web server got the nginx bootstrap script; `usms-db-01` was launched without one.
- **Tags and name:** `Tier=web` vs `Tier=data`, and their Name tags.
- **Private IP address:** each gets its own, picked from its subnet's range.

**Properties of the subnet** (the instance inherits them just by being placed there):
- **Auto-assigned public IP:** `usms-public-subnet-a` has `MapPublicIpOnLaunch=true`, `usms-private-subnet-a` has it off, which is why the database gets no public address.
- **Route table:** public → `0.0.0.0/0` to `usms-igw`; private → `0.0.0.0/0` to `usms-nat` (plus the S3 endpoint). This is what really makes one public and the other private.
- **Network ACL:** the default NACL vs `usms-private-nacl`.
- **Address range:** 10.0.1.0/24 vs 10.0.3.0/24. Both are in `us-east-1a`, so the AZ is not a difference.

**Properties of the VPC** (shared, so not differences at all): the `10.0.0.0/16` address space, DNS settings, the internet gateway and the NAT gateway themselves. Both instances live inside the same `usms-vpc`.

