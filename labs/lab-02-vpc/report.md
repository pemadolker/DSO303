# AWS Practical Laboratory 2 Report

**Student Name:** Pema Dolker   
**Module:** DSO303  
**Practical:** Lab 02 - Virtual Private Cloud (VPC) and Networking  
**Environment:** Floci (local AWS API emulator, Docker Compose, hybrid storage mode)


## 1. Aim / Objective


The purpose of this practical is to construct a functional Virtual Private
Cloud environment for the USMS project, all through the use of just the AWS command line interface. By the time I finish this practical, I ought to be able to clearly describe how the terms "public" and "private" subnets are defined; how the two different firewall systems in VPC (security groups and network access control list) differ from one another, and how each can be
used; how a NAT gateway provides outbound internet connectivity for a
private subnet; and how a VPC gateway endpoint enables the skipping of
unnecessary public internet transfers within the AWS infrastructure.

## 2. Introduction

VPC is basically your own little isolated piece of cloud region where
you get to specify an address range to use, split it into subnets and
control who talks to who. There is no route to anywhere from anything
inside a VPC by default except for something else within the same VPC;
all routes have to be created manually.

The basic building blocks in this lab:

- **VPC** - the address space itself (we've chosen `10.0.0.0/16`)
- **Subnets** - smaller CIDR ranges cut out of the VPC, bound to
  particular Availability Zones
- **Internet Gateway (IGW)** - the VPC's connection to the public internet
- **Route tables** - determine where traffic bound to a certain
  destination will be routed; that's the thing that makes a subnet public
  or private
- **NAT Gateway** - allows a private subnet to reach out to the internet
  (for OS patches, for example) but not vice versa
- **Security Groups** - stateful, per-instance, only allow firewalls
- **Network ACLs** - stateless, per-subnet firewalls that either allow or
  deny connections
- **VPC Gateway Endpoint** - a route-based way to make connections to S3
  (or DynamoDB) without traffic leaving the AWS network

None of this costs anything to figure out theoretically, but in real-world
AWS several of the above mentioned items (NAT gateway particularly)
are actually among the most expensive ones on the bill. More on that in
the Analysis section.


## 3. Use Case

USMS needs a network that keeps the parts of the system that matter apart
from each other:

| Tier | Purpose | Reachable from |
|---|---|---|
| Web tier | Students/staff hit the app over HTTP/HTTPS | The public internet |
| Data tier | Holds transcripts and enrolment records | Only the web tier, never the internet |

In practical terms: The web servers are located in the public subnet where there is an internet gateway route, the database is located in the private subnet where there is no such internet gateway route at all, and both can communicate only via the exact port required (PostgreSQL, 5432) as the security group of the database is limited to connections originating from the web tier’s security group, and not a CIDR range, but the *security group itself*.

## 4. System Architecture / Design

```
usms-vpc  10.0.0.0/16
 │
 ├── usms-igw (internet gateway, attached)
 │
 ├── usms-public-rt      0.0.0.0/0 -> usms-igw
 │    ├── usms-public-subnet-a   10.0.1.0/24  us-east-1a
 │    ├── usms-public-subnet-b   10.0.2.0/24  us-east-1b
 │    └── usms-public-subnet-c   10.0.5.0/24  us-east-1c  (exercise)
 │
 ├── usms-private-rt     0.0.0.0/0 -> usms-nat
 │    ├── usms-private-subnet-a  10.0.3.0/24  us-east-1a
 │    └── usms-private-subnet-b  10.0.4.0/24  us-east-1b  (exercise 5)
 │
 ├── usms-nat  (NAT gateway, sits in public-subnet-a, has an Elastic IP)
 ├── usms-s3-endpoint  (gateway endpoint, attached to the private route table)
 │
 ├── usms-app-sg    in: 80, 443, 22(bastion)     out: all
 ├── usms-db-sg     in: 5432 from usms-app-sg     out: all
 ├── usms-bastion-sg in: 22 from one fixed IP     out: all   (exercise 2)
 ├── usms-exam-sg   in: 443 from campus CIDR      out: all   (exercise 4)
 │
 └── usms-private-nacl (attached to both private subnets)
      in  100  allow tcp 5432        from 10.0.0.0/16
      in  110  allow tcp 1024-65535  from 0.0.0.0/0   (ephemeral return)
      out 100  allow tcp 1024-65535  to   10.0.0.0/16
      out 110  allow tcp 443         to   0.0.0.0/0    (patches out)
```

This is the actual, final state of the network as verified by
`verify-lab-02.sh` - not a planned diagram, an as-built one.

## 5. Implementation Procedure

This was done using the AWS CLI against Floci (`localhost:4566`, account
`000000000000`), based on the lab document's numbering. Rough order of
operations:

1. Rebooted the Floci environment, source `configs/course.env` and
   `configs/lab-01.env` from last time, confirmed identity.
2. Assumed `usms-developer-role` (which is the least-privileged role made in
   Lab 1), and built the VPC as that role, rather than under root, to be
   precise about who is doing what when building.
3. Enabled DNS and hostname support for the VPC, attached the internet
   gateway.
4. Built the public and private subnets in `us-east-1a`, built a public and
   private route table, added a `0.0.0.0/0 → igw` route to the public route
   table but not the other one — this is pretty much literally the whole
   difference between public and private subnets at this stage.
5. Showed that the two subnets were genuinely behaving differently via API
   readback of each route table rather than taking their tag labels as truth.
6. Built `usms-app-sg` (HTTP/HTTPS from anywhere, SSH narrowed) and
   `usms-db-sg` (PostgreSQL connections restricted from the security group of
   the application tier, not a CIDR block).
7. Built the custom NACL for the private subnet and added an explicit
   ephemeral-port return rule, attached the NACL to the subnet instead of the
   default one.
8. Assigned an Elastic IP, built a NAT gateway in the public subnet, pointed
   the private route table's default route at it.
9. Built an S3 gateway endpoint with attachment to the private route table.
10. Tag audit, restart Floci to test for persistent state, generated
    `configs/lab-02.env` with all resources' IDs resolved freshly via tag
    lookups, executed the verification script, and committed.
11. Completed all 5 independent exercises (see `exercises.md` for more
    details): a third public subnet, a more complete bastion security group
   (with proper SSH refactor), a bash script classifying any subnet as
   public/private/isolated based only on routing state, a design writeup and
   partial implementation for a new exam results service, and a second private
   subnet in a second AZ (which will be needed for the RDS subnet group next
   lab).



## 6. Results and Evidence

### 6.1 CLI Output

**VPC creation and identity verification**

![VPC creation](../../screenshots/lab2/step3.png)

**DNS attributes and internet gateway attachment**

![DNS and IGW](../../screenshots/lab2/step5.png)

![Internet gateway attached](../../screenshots/lab2/step6.png)

**Public and private subnet creation**

![Public subnet](../../screenshots/lab2/step7.png)
![Auto-assign public IP](../../screenshots/lab2/step8.png)
![Private subnet](../../screenshots/lab2/step9.png)

**Route tables and the public-vs-private proof (Checkpoint 5)**

![Public route table](../../screenshots/lab2/step10.png)

![Route table associations](../../screenshots/lab2/step11.png)

![Private route table](../../screenshots/lab2/step12.png)

![Public vs private subnet proof](../../screenshots/lab2/step13.png)

**Security groups - usms-app-sg and usms-db-sg**

![Application security group](../../screenshots/lab2/step14.png)
![All security groups in the VPC](../../screenshots/lab2/step16.png)

**Network ACL - default read, creation, tag fix, and the four custom rules**

![Default NACL entries and NACL creation](../../screenshots/lab2/step17.png)
![NACL tag empty on creation, fixed with create-tags](../../screenshots/lab2/step17-2.png)
![All 4 custom rules plus the 2 implicit denies](../../screenshots/lab2/step17-3.png)
![NACL swapped from default onto the private subnet](../../screenshots/lab2/step18.png)

**NAT gateway and routing (Checkpoint 8)**

![Elastic IP allocation and NAT gateway creation](../../screenshots/lab2/step19.png)
![Private route table pointed at the NAT gateway](../../screenshots/lab2/step20.png)
![S3 gateway endpoint created and attached](../../screenshots/lab2/step21.png)

**Tag audit and subnet inventory**

![Full tag audit and subnet inventory export](../../screenshots/lab2/step22.png)

**Persistence proof (Checkpoint 9)**

![Pre/post-restart comparison, PERSISTENCE PROVEN](../../screenshots/lab2/step23.png)

**Generating configs/lab-02.env - including two bugs caught and fixed live**

![USMS_APP_SG and USMS_PRIVATE_NACL resolving incorrectly, then corrected with sed](../../screenshots/lab2/step24-1.png)
![Final cross-check — every USMS_* value matching its known-correct shell variable](../../screenshots/lab2/step24-2.png)
![Identity restored to root after the developer role session](../../screenshots/lab2/sjbdj.png)

**Independent exercises**

![Exercise 1 — third public subnet](../../screenshots/lab2/exercise1.png)
![Exercise 2 — bastion SG and SSH refactor](../../screenshots/lab2/exercise2.png)
![Exercise 2 — verification](../../screenshots/lab2/exercise2-1.png)
![Exercise 2 — the stuck old SSH rule, confirmed across a repeat revoke attempt](../../screenshots/lab2/e2.png)
![Exercise 3 — network report script](../../screenshots/lab2/exercise3.png)
![Exercise 4 — exam-results security group](../../screenshots/lab2/exercise4.png)
![Exercise 5 — assumed role identity](../../screenshots/lab2/exercise5.png)
![Exercise 5 — private subnet B and NACL](../../screenshots/lab2/exercise5-1.png)

### 6.2 Verification Script Output

```
== Environment ==
  ok   Floci container running
  ok   Storage mode is NOT memory
  ok   AWS CLI reaches Floci
  ok   Account is 000000000000
== Lab 01 dependencies still present ==
  ok   role usms-developer-role
  ok   instance profile usms-ec2-app-profile
== Lab 02 resources ==
  ok   usms-vpc exists
  ok   vpc CIDR is 10.0.0.0/16
  ok   vpc DNS hostnames enabled
  ok   usms-igw exists
  ok   usms-igw ATTACHED to usms-vpc
  ok   public subnet a exists
  ok   public subnet a auto-assigns public IP
  ok   private subnet a exists
  ok   private subnet a does NOT auto-assign public IP
  ok   public rt has a default route to an igw
  ok   public subnet a is associated with usms-public-rt
  ok   private subnet a is associated with usms-private-rt
  ok   private rt has NO route to an internet gateway
  ok   usms-app-sg exists
  ok   usms-app-sg allows tcp 80
  ok   usms-db-sg exists
  FAIL usms-db-sg is sourced from usms-app-sg (not a CIDR)
  ok   usms-private-nacl exists
  ok   usms-private-nacl is attached to the private subnet
  ok   usms-private-nacl is not the default ACL
  ok   usms-s3-endpoint exists
== Tagging ==
  ok   every Lab 02 resource carries Project=USMS
== Files and Git hygiene ==
  ok   configs/lab-02.env exists
  ok   configs/lab-02.env has no empty values
  ok   policies/usms-db-sg-ingress.json is valid JSON
  FAIL no secret is tracked by git
  ok   .gitignore uses outputs/* not outputs/

PASS=31  FAIL=2
```

Both fails are explained fully in Section 7 - they're not oversights, I
diagnosed each one down to the specific API call and confirmed by hand that the underlying design/configuration is correct.



## 7. Analysis and Discussion


The concepts of this lab all came to fruition properly,
but Floci had a lot more issues compared to Lab 1, and I feel that they are worth documenting rather
than just ignoring because identifying the specific causes (mine vs. the emulator's) consumed the vast
majority of the effort in this practical.

**The things that were actually correct and as expected:**
- Step 13, the "how to make subnets public" proof actually did work as explained – checking the
effective route table was the only method that works for me, and both subnets produced the expected,
yet opposite results.
- Persistence of configurations across a Floci reboot was flawless in my case each and every time –
the `hybrid` configuration is indeed persisted properly.
- All routes, NACL rules, and tags that I created by specifying `--tag-specifications` upon creating an entity did get applied properly (save for the exception below).


**Floci limitations I encountered and had to workaround:**

1. **Network ACLs and NAT gateways are not firewalls in Floci.** As stated in the lab document
   already, Floci stores the security groups' objects and returns them on the `describe-*` calls
   successfully; however, nothing gets enforced when you are dealing with the real traffic, since
   there is no forwarding layer present in this implementation at all. It means that a security
   group that allows the whole internet to access you will behave exactly the same way as one
   that has the very narrow scope — my only option to check my rules was to see how they are
   persisted in the DB in accordance with the specification and then compare them with the
   expected output, since my rules are not being tested for anything, anyway.

2. **Security groups source (`UserIdGroupPairs`) is not persisted.** I have created the `usms-db-sg`
   group rule properly: the protocol and port have been set, and there was a `GroupId` referring
   to `usms-app-sg`. However, the API call has returned the proper rule ID, while `describe`
   call shows that there is an empty `UserIdGroupPairs` and `IpRanges` fields in the stored
   rule. I checked the raw JSON output, not the processed one, so I can be sure it is not a
   problem of my query logic, but a general behavior in this implementation, which I also
   observed later on the bastion-referenced SSH rule in Exercise 2.

3. **`revoke-security-group-ingress` fails to reliably delete rules.**
   Despite every revoke operation returning `{"Return": true}`, the desired
   rule remained visible in `describe-security-group-rules` each and every
   time, in two distinct security groups, and three different attempts in
   one of them. The rule ID was always the same as what `describe`
   operation gave right before, so it can't be a result of ID mismatch.

4. **The filter by tags doesn't work with network ACLs.**
   The `describe-network-acls --filters "Name=tag:Name,Values=usms-private-nacl"`
   command keeps giving me the *default* ACL, despite `describe-network-acls`
   command without filters clearly showing there is just one ACL with that tag.
   Other AWS resource types used in this lab (VPC, subnet, route table,
   security group, NAT gateway, VPC endpoint) all filtered by tag fine.
   I found a workaround by looking up the correct NACL ID manually from
   the variable in shell.

5. **`create-tags` / `--tag-specifications` silently failed once for a
   network ACL.** On both attempts, the NACL was restored by `create-network-acl`
   with no tags listed in spite of being specified through `--tag-specifications` as
   part of the same call that worked perfectly well on all other resource types.
   A subsequent `create-tags` did the trick right away; looks like an ordering/timing
   problem rather than a busted feature.

6. **Tag filter-based lookup can return a wrong value inside a
   multi-command chain silently while working just fine as a standalone one.** While
   generating the `configs/lab-02.env` file, the heredoc's `describe-security-groups
   --filters "Name=tag:Name,Values=usms-app-sg"` line failed to locate a group,
   and the NACL line in question (bug #4) resolved to the default ACL. Running the
   commands straight after each other as standalone did the trick right away; I never
   fully root-caused this one — might be a timing/ordering problem when several
   tag-based `describe-*` calls are fired back to back inside one heredoc — but
   the fix was quite easy either way: just run a cross-validation of each
   `USMS_*` value against its known correct shell variable first, then fix whatever
   mismatches by hand using `sed`. Evidence of both the bug and the fix are
   provided in section 6.1.

7. **Deleted resources leave orphaned tag and NACL association records
   hanging around.** When I tried to delete a duplicate subnet (accidentally
   created because a long copy-paste was broken in my terminal) and an orphaned
   internet gateway left over from a teardown attempt, `describe-tags` continued
   reporting their tags indefinitely, and in the former case, the stale NACL
   association persisted as well. `describe-subnets` and `describe-vpcs` correctly
   showed both resources as deleted; only the tag index failed to clean itself up.
   `delete-tags --resources <id>` (without `--tags` argument explicitly passed)
   didn't do the job — I had to pass each key explicitly to make it work.

However, none of these effect what the *design* might be like - every solution was either simply "note it and let it go" or "look the ID in another way" - however, they did mean that I rebuilt the whole central network both times from the very beginning, one of the occasions due to some of these problems coming all together at once and making the overall state hard to rely on.

## 8. Reflection

Before starting this lab, I was expecting it to be a lot about learning CLI
syntax by heart, which it certainly is in terms of things like the syntax of the JMESPath queries (`Tags[?Key==\`Name\`]|[0].`Value` is something that I would not have got right without having seen a few examples), but what I
remember most about this lab isn't any CLI syntax at all, but the simple
realization that, when talking about a "public subnet", nothing in its name, its tags, or even the fact that the instances in it have public IPs
matters; it's all about whether its route table has a `0.0.0.0/0` route to
an internet gateway.

The second thing I didn't anticipate was that so much of the work would involve "was it the tool or was it me" instead of "how do I do this". While I don't think it's a bad thing, it is good practice. After all, when I move to AWS, I won't have an instructor to clarify whether a peculiar behavior is due to the emulator's oddities, hence knowing how to verify a strange result independently (raw JSON instead of formatted query, direct ID check instead of filter, performing the same action multiple times, etc.) will make the skill transferable and applicable to other tasks.

## 9. Conclusion

I successfully created a functional two-tier VPC configuration for USMS with a public-facing web subnet that's connected to the internet, several private data-tier subnets that don't have any connectivity to the internet, properly configured security groups (including a CIDR-based security group and another one that's referenced using other security groups), a subnet-level NACL firewall appliance equipped with an ephemeral rule that may be easily forgotten, a NAT gateway for one-way outbound traffic access, and an S3 gateway endpoint that helps eliminate AWS-to-AWS traffic over the internet. All 5 do-it-yourself tasks are done, including the second AZ subnet for future RDS subnet groups in the course.

## 10. Appendix

### Additional Files
- `configs/lab-02.env` - every resource ID from this lab, safe to commit (no secrets)
- `policies/usms-db-sg-ingress.json` - the group-reference rule document for `usms-db-sg`
- `scripts/utilities/verify-lab-02.sh` - the 33-check verification script
- `scripts/utilities/lab-02-network-report.sh` - Exercise 3's classification script
- `scripts/cleanup/lab-02-cleanup.sh` - full teardown script (never run except when redoing the build)
- `labs/lab-02-vpc/exercises.md` - full detail on all 5 independent exercises
- `notes/lab-02-notes.md` - the 7 review questions, answered 

### Submission Checklist
- [x] Student information completed
- [x] Objectives stated
- [x] Introduction provided
- [x] Use case described
- [x] System design included (as-built, verified diagram)
- [x] Implementation documented
- [x] CLI outputs included
- [x] Verification script output included
- [x] Analysis completed (including honest documentation of tooling limitations)
- [x] Reflection completed
- [x] Conclusion written
- [x] All 5 independent exercises completed
- [x] Review questions answered (`notes/lab-02-notes.md`)