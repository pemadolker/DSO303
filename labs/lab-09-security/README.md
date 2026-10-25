# AWS Practical Laboratory 9 Report

**Student Name:** Pema Dolker       
**Module:** DSO303    
**Practical:** Lab 09 - Securing the USMS Application with IAM Roles and Security Groups    
**Environment:** Floci 2.2.0 (local AWS API emulator, Docker Compose, hybrid storage), account 000000000000, us-east-1

**Support path:** A (full). Roles, policies and security group rules can be created, read and changed, and `simulate-principal-policy` also works, so I could check my own reading of the policies against the IAM simulator. Only `get-credential-report` is missing.

Step by step notes and the seven review questions are in `notes/lab-09-notes.md`, and the five exercises are in `labs/lab-09-security/exercises.md`.

> Labels used below:
> **Observed** = I ran it and saw it.
> **Floci limitation** = behaved differently from real AWS.
> **Conceptual** = only possible on real AWS, so I explained it instead.

## 1. Aim / Objective

The aim of this practical is to review the security of everything Labs 1 to 6 built, on both sides of access control: who can call what (IAM), and what can reach what (security groups and routing). I inventoried and audited every role and security group with read-only scripts, then fixed what they found: a read-only transcripts policy, confused deputy conditions on trust policies, a scoped `iam:PassRole`, a permissions boundary, a session policy, an access key rotation and IMDSv2. On the network side I wrote egress rules for three groups, limited SSH to a bastion group, and showed that the database cannot be reached from the internet. Finally I proved that all of it survives a restart and that nothing from the earlier labs broke.

## 2. Introduction

Up to now the labs built USMS. This one reviews it. Nothing new is added to the application, the work is finding and fixing weaknesses in what is already there.

AWS decides every request on two separate axes. An API call is decided by IAM, and when it is refused you get an error that names an action. A network packet is decided by routing, security groups and NACLs, and when it is refused you get a timeout. Neither side knows about the other, and most confusing access problems come from assuming one side has already covered the other.

The main ideas I used in this lab:

- **Trust policy** - decides who may become a role. A service principal with no condition can be used by that service on anyone's behalf (the confused deputy).
- **Least privilege** - giving a role only the actions it actually needs, for example a read-only policy for a service that only reads.
- **iam:PassRole** - the permission to hand a role to a service. Unscoped, it is a common way to escalate to admin.
- **Permissions boundary** - a ceiling on a role that grants nothing by itself.
- **Session policy** - a ceiling the caller puts on one assumed role session.
- **Access key rotation** - replacing a long-lived key with no outage.
- **IMDSv2** - a token-based metadata service that stops SSRF bugs from stealing instance credentials.
- **Egress rules** - limiting what a resource can connect out to, not only what can connect in.

Security matters in cloud computing because a cloud account is reachable from anywhere, and most real incidents come from configuration (a role that can do too much, a rule that is too open) rather than from clever exploits.

## 3. Use Case

- Reviewing an existing system before an audit and producing a list of findings with decisions for each one.
- Giving a reporting service read-only access to student transcripts without touching the services that need to write.
- Letting a deployment pipeline pass only specific roles to ECS, with a ceiling it cannot raise.
- Rotating a developer's access key without breaking anything that uses it.
- Making sure a compromised task or instance cannot freely send data out of the network.

## 4. System Architecture / Design

```text
 NETWORK (usms-vpc 10.0.0.0/16)
   internet -> usms-alb-sg  in 80,443 from 0.0.0.0/0    out ONLY tcp/80 -> usms-enrolment-sg
   internet -> usms-app-sg  in 80,443 from 0.0.0.0/0    in 22 ONLY from usms-bastion-sg
                            out 443 (S3 list + anywhere), 80 -> alb-sg, 5432 -> db-sg, 53 -> 10.0.0.2
   usms-enrolment-sg        in 80 from usms-alb-sg       out ONLY tcp/443 (S3 prefix list + anywhere)
   usms-db-sg               in 5432 from app-sg (and exam-sg)   out ONLY tcp/443
   usms-db-01: private subnet, no internet gateway route, custom NACL, metadata service off
   usms-web-01: IMDSv2 required, hop limit 1

 IAM
   usms-ecs-task-role, usms-ecs-exec-role   ecs-tasks trust + SourceAccount and SourceArn conditions
   usms-transcripts-reader-role             same scoped trust, USMSStudentDataReadOnly
   usms-deploy-role                         trusts usms-admin-01, USMSDeployBase (PassRole to 3 roles,
                                            ecs-tasks only, never EC2), capped by USMSPermissionsBoundary
   usms-breakglass-role                     admin + MFA + ExternalId, one hour, scaling suspend only
   usms-dev-01                              one access key, rotated in this lab
```

A request needs a yes from both boxes. A correct security group does not help if the role can do too much, and a tight role does not help if the database is open to the world.

![Lab 09 architecture](../../screenshots/lab9/lab-09-architecture.png)


## 5. Implementation Procedure

1. **Steps 1 and 2** - started Floci, loaded seven env files and recorded what the Lab 2 to 6 verify scripts said, as the baseline.
2. **Step 3** - probed which IAM and EC2 calls this build supports (Path A).
3. **Steps 4 and 5** - inventoried every role and built a read-only IAM audit script.
4. **Steps 6 and 7** - read the transcripts policy, created a read-only policy and a reader role, and added confused deputy conditions to the ECS task role's trust policy.
5. **Step 8** - created a permissions boundary, a deploy policy with a scoped `iam:PassRole`, and a deploy role that uses both.
6. **Step 9** - assumed the developer role with a session policy and worked out the intersection by hand and with the simulator.
7. **Step 10** - rotated usms-dev-01's access key in four steps.
8. **Step 11** - required IMDSv2 on the web instance and turned the metadata service off on the database instance.
9. **Step 12** - built a security group audit script.
10. **Steps 13 to 16** - wrote egress rules for the enrolment, load balancer and database groups, and moved SSH to the bastion group.
11. **Step 17** - built a reachability matrix and showed the database is not reachable from the internet with five separate controls.
12. **Steps 18 and 19** - restarted Floci and compared, re-ran the earlier verify scripts, and wrote `configs/lab-09.env`.
13. **Section 8** - built and ran `verify-lab-09.sh`, and wrote (but did not run) the cleanup script.

## 6. Results and Evidence

### 6.1 CLI Output

**Steps 1 and 2 - environment and baseline**

![Step 1](../../screenshots/lab9/step1.png)
![Step 2](../../screenshots/lab9/step2.png)

**Observed:** all seventeen values were filled in. The first baseline showed that several things from earlier labs had quietly changed while Floci was restarted during Labs 7 and 8: both EC2 instances were stopped, the web data volume was detached, and the security groups had lost their "source group" references, leaving empty rules behind. I started the instances, reattached the volume and added the two group-sourced rules back before starting. The clean baseline was lab-02 32/1, lab-03 34/2, lab-04 38/1, lab-05 49/0, lab-06 39/3, and every remaining failure has a known reason (written in my notes). **Floci limitation:** the empty rules could not be deleted.

**Step 3 - what this build supports**

![Step 3](../../screenshots/lab9/step3.png)
![Step 3 recheck](../../screenshots/lab9/step3-2.png)

**Observed:** the probe first said `get-role`, `list-attached-role-policies` and `simulate-principal-policy` were not available. That was wrong: in my `lab-01.env` the role variables hold full ARNs, not names. With plain names all three worked, so this build is Path A. Only `get-credential-report` is missing.

**Steps 4 and 5 - inventory and IAM audit**

![Step 4](../../screenshots/lab9/step4.png)
![Step 4 inventory](../../screenshots/lab9/step4-2.png)
![Step 4 your turn](../../screenshots/lab9/step4-3.png)
![Step 5](../../screenshots/lab9/step5.png)

**Observed:** 10 roles, 4 users and 11 customer managed policies. `USMSStudentDataReadWrite` is attached to three roles, and `USMSReportingReadOnly` to nothing. No role had a permissions boundary. The audit gave HIGH=8 MED=21 and exit code 1. All eight HIGH findings had the same shape: a service principal in a trust policy with no condition.

**Steps 6 and 7 - the read-only split and the confused deputy fix**

![Step 6](../../screenshots/lab9/step6.png)
![Step 7 policy](../../screenshots/lab9/step7.png)
![Step 7 trust](../../screenshots/lab9/step7-2.png)
![Step 7 role](../../screenshots/lab9/step7-3.png)
![Step 7 update](../../screenshots/lab9/step7-4.png)
![Step 7 check](../../screenshots/lab9/step7-5.png)

**Observed:** my Lab 1 policy grants `PutObject` and `DeleteObject` as well as reads, to three roles. The bucket does not exist yet (404), which is expected. I created `USMSStudentDataReadOnly` (read, with an explicit Deny on every write) and `usms-transcripts-reader-role`, and rewrote the ECS task role's trust policy. The check said "SAME PRINCIPAL, NEW CONDITION", and the task role still has its read-write policy for Lab 10.

**Step 8 - scoped PassRole and the boundary**

![Step 8 boundary](../../screenshots/lab9/step8.png)
![Step 8 deploy policy](../../screenshots/lab9/step8-2.png)
![Step 8 role](../../screenshots/lab9/step8-3.png)
![Step 8 check](../../screenshots/lab9/step8-4.png)

**Observed:** `usms-deploy-role` trusts only `usms-admin-01`, has `USMSPermissionsBoundary` as its boundary, and can pass only three named roles, only to ECS tasks, with an explicit Deny on passing anything to EC2. The boundary itself is attached to nothing, which is correct for a ceiling.

**Step 9 - session policy and the intersection**

![Step 9](../../screenshots/lab9/step9.png)
![Step 9 assume](../../screenshots/lab9/step9-2.png)
![Step 9 first calculation](../../screenshots/lab9/step9-3.png)
![Step 9 back to root](../../screenshots/lab9/step9-4.png)
![Step 9 the missing policy](../../screenshots/lab9/step9-5.png)
![Step 9 rebuilt inventory](../../screenshots/lab9/step9-6.png)
![Step 9 agreement](../../screenshots/lab9/step9-8.png)
![Step 9 cap shown](../../screenshots/lab9/step9-9.png)
![Step 9 boundary fixed](../../screenshots/lab9/step9-10.png)

**Observed:** my first calculation said everything was denied, while the IAM simulator said `DescribeVpcs` was allowed. Checking directly showed `USMSDeveloperBase` is attached to the developer role, so my Step 4 inventory had silently missed it when an AWS CLI call crashed. After rebuilding it with retries the two methods agreed: `ec2:DescribeVpcs` allowed, `ec2:RunInstances` not in the identity policy so denied (simulator `implicitDeny`), and `iam:CreateUser` explicitly denied. I also found that the handout's inventory read the permissions boundary from `list-roles`, which never returns it, so I filled it in from `get-role`. The audit after these steps was HIGH=7 MED=35.

**Step 10 - key rotation**

![Step 10](../../screenshots/lab9/step10.png)
![Step 10 new key](../../screenshots/lab9/step10-2.png)
![Step 10 profile](../../screenshots/lab9/step10-3.png)
![Step 10 deactivate](../../screenshots/lab9/step10-4.png)
![Step 10 delete](../../screenshots/lab9/step10-5.png)

**Observed:** create, move the profile, deactivate, then delete. The new secret went straight into a git-ignored file and never appeared on screen. At the end there is exactly one key, created today, and the profile still answers. **Floci limitation:** Floci accepts any credentials, so the profile answering proves less here than on real AWS.

**Step 11 - IMDSv2**

![Step 11](../../screenshots/lab9/step11.png)
![Step 11 your turn](../../screenshots/lab9/step11-yourturn.png)
![Step 11 recheck](../../screenshots/lab9/step11-check.png)

**Observed:** `usms-web-01` went from `HttpTokens optional` to `required`, hop limit 1, endpoint still enabled because it has a role. `usms-db-01` has no instance profile, so I turned its metadata service off completely. My first attempt at this step failed on every call with an `ld.so` error, which turned out to be my laptop running low on memory. After restarting it I re-checked everything from Steps 4 to 11 in one go (the third screenshot) and it all matched.

**Steps 12 to 16 - the network**

![Step 12](../../screenshots/lab9/step12.png)
![Step 12 more](../../screenshots/lab9/step12-2.png)
![Step 13](../../screenshots/lab9/step13.png)
![Step 13 document](../../screenshots/lab9/step13-2.png)
![Step 13 change](../../screenshots/lab9/step13-3.png)
![Step 13 by rule id](../../screenshots/lab9/step13-4.png)
![Step 13 after restart](../../screenshots/lab9/step13-5.png)
![Step 14](../../screenshots/lab9/step14.png)
![Step 15](../../screenshots/lab9/step15.png)
![Step 15 three zeros](../../screenshots/lab9/step15-2.png)
![Step 16](../../screenshots/lab9/step16.png)
![Step 16 check](../../screenshots/lab9/step16-2.png)

**Observed:** the security group audit gave HIGH=4 MED=11 LOW=9 across 9 groups, and found a second path to the database from `usms-exam-sg` that the handout does not expect. After Steps 13 to 15 each of the three groups has written egress and zero allow-all rules, and the load balancer may only connect to the enrolment group. SSH to the web instance now only comes from the bastion group. **Floci limitation:** for a while it looked as if revoking rules did not work. It did. Floci keeps two listings of rules and one of them (`describe-security-group-rules`) is not updated when a rule is removed, so it kept showing rules that were already gone. `describe-security-groups` shows the real state.

**Step 17 - reachability and the negative proof**

![Step 17 matrix](../../screenshots/lab9/step17.png)
![Step 17 proof](../../screenshots/lab9/step17-2.png)

**Observed:** two groups admit the internet (the load balancer and the web instance), and five groups are protected by exactly one ingress rule. For the database, four of the five controls hold: no auto-assigned public IP, a route through the NAT and no internet gateway, a security group with group sources only, and a custom NACL. **Floci limitation:** control 1 failed because Floci gives every running instance an address from its Docker network (172.21.0.8). On real AWS it would have no public address. The claim still holds, which is the point of having several controls.

**Steps 18 and 19 - persistence, regression and the env file**

![Step 18](../../screenshots/lab9/step18.png)
![Step 18 restart](../../screenshots/lab9/step18-2.png)
![Step 18 compare](../../screenshots/lab9/step18-3.png)
![Step 18 nothing broke](../../screenshots/lab9/step18-4.png)
![Step 19](../../screenshots/lab9/step19.png)
![Step 19 check](../../screenshots/lab9/step19-2.png)

**Observed:** I recorded eleven facts (the handout's nine plus the two group references, since those are what went missing before), restarted Floci, found every ID again from the API and read them back: PERSISTENCE PROVEN. After starting the instances again, the five earlier verify scripts gave exactly the same results as the baseline: NOTHING BROKE. `configs/lab-09.env` has 16 exports (17 after Exercise 5) with no empty values and no access key ID.

**Section 8 - verification and cleanup**

![Verification](../../screenshots/lab9/section8-verify.png)
![Cleanup script](../../screenshots/lab9/section8-cleanup.png)

**Observed:** `verify-lab-09.sh` gave **PASS=49 FAIL=1**. The one failure is "usms-db-01 has NO public address", the same Floci address as in Step 17. I fixed several bugs in the handout's version, each marked `# FIX`. The cleanup script is written and syntax checked but not run.

### 6.2 AWS Management Console Verification

Floci does not have a web console, so there is no console screenshot for this lab. The `describe`, `get` and `list` commands in 6.1 are the verification.

## 7. Analysis and Discussion

The objectives were achieved. Every identity fix and every network fix from the handout is in place and passes its check, they survive a restart, and none of the earlier labs' checks changed. Because Floci enforces neither IAM nor security groups, every proof in this lab is a proof by reading the configuration, which is also how a claim about what cannot happen would be checked on a real account.

The most useful thing I learned was how easy it is to trust the wrong evidence. Three times in this lab a result looked solid and was wrong: the probe that said basic calls were unsupported (the variable held an ARN), the inventory that said the developer role had no policy (a call had crashed), and the rule listing that said revokes did not work (it was a stale listing). Each time, checking with a second method found the problem.

Problems I ran into and how I fixed them:

- **Earlier labs had drifted.** Stopped instances, a detached volume and lost group references, all from Floci restarts. I repaired them before starting and recorded it.
- **Role variables were ARNs.** I added plain-name variables and used them wherever a name was needed.
- **The inventory missed a policy and every boundary.** I added retries, took the boundary from `get-role`, and saved the builder as `scripts/utilities/usms-iam-inventory.sh`.
- **Handout queries that could never work.** Several checks were missing `SecurityGroups[0].` or compared the protocol to the number -1 instead of the text "-1", and one check nested escaped quotes so deeply that it broke the query. I fixed each one and marked it.
- **My laptop.** It crashed AWS CLI calls several times when it was short of memory. A restart fixed it, and I re-checked all the work afterwards.
- **zsh.** `${PIPESTATUS[0]}` does not exist in zsh and unquoted variables do not split into words, which mattered for some commands.

## 8. Reflection

**What I learned.** My specialisation is software security, so I knew most of these terms, but this lab made them concrete. I had not thought about the trust policy as the more dangerous half of a role, or about egress as something you design rather than leave open. Working out the session policy intersection by hand and then matching it against the simulator was the clearest lesson in how IAM evaluation actually works.

**Challenges.** The hardest part was not knowing what to trust. Between Floci's stale listings, the crashed calls and my laptop running out of memory, there were moments where I was ready to start the lab again. What helped was checking each result a second way instead of redoing everything.

**Real world use.** On a real account I would add the detective side that this lab does not have: CloudTrail, GuardDuty and AWS Config, so a change to any of these controls would be noticed. I would also replace the remaining access key with short-lived credentials through IAM Identity Center.

**What I want to explore more.** IAM Access Analyzer on a real account, to see the "who can access this bucket" question answered from the bucket's side, and applying the Exercise 5 bucket policy once Lab 10 has created the bucket.

## 9. Conclusion

The objectives were achieved. USMS now has a read-only path to the transcripts, trust policies with confused deputy conditions, a deploy role with a scoped `iam:PassRole` and a permissions boundary, one freshly rotated access key, IMDSv2 on the web instance, written egress on four groups and SSH only from a bastion group. Every control survived a restart, the earlier labs' checks did not change, and `verify-lab-09.sh` passes everything except the one known Floci address difference.

The key ideas I am taking from this lab are that an API call and a packet are decided by two separate systems, that a trust policy decides who can become a role, that boundaries and session policies only take away, and that a claim about what cannot happen is proven by several independent controls, not one.

## 10. Appendix

- Notes, audit results, the access table and the seven review questions: `notes/lab-09-notes.md`
- Exercises 1 to 5: `labs/lab-09-security/exercises.md`
- Policy documents: `policies/usms-student-data-ro-policy.json`, `policies/usms-deploy-policy.json`, `policies/usms-permissions-boundary.json`, `policies/trust-ecs-tasks-scoped.json`, `policies/trust-deploy.json`, `policies/usms-alb-sg-egress.json`, `policies/usms-enrolment-sg-egress.json`, `policies/usms-db-sg-egress.json`, `policies/usms-egress-allow-all.json` (the undo), `policies/usms-app-sg-ssh-bastion.json`, and from the exercises `policies/usms-app-sg-egress.json`, `policies/trust-breakglass.json`, `policies/usms-breakglass-policy.json`, `policies/trust-lambda-scoped.json`
- Accepted audit findings, with reasons: `configs/usms-iam-accepted-findings.txt`
- Recorded names and ARNs: `configs/lab-09.env` (17 exports, no access key ID)
- Scripts: `scripts/utilities/usms-iam-inventory.sh`, `usms-iam-audit.sh`, `usms-sg-audit.sh`, `usms-reachability-matrix.sh`, `usms-exposure-report.sh`, `usms-bucket-policy-draft.sh`, `verify-lab-09.sh`, and `scripts/cleanup/lab-09-cleanup.sh` (not run)
- Screenshots: `screenshots/lab9/`
- Kept locally and not committed (git-ignored): the new access key file, the inventory and findings, the before and after files, the exposure report, the bucket policy draft and the Lab 10 readiness file

