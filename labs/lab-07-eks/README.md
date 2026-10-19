# AWS Practical Laboratory 7 Report

**Student Name:** Pema Dolker   
**Module:** DSO303    
**Practical:** Lab 07 - Deploying a Microservices Application on Amazon EKS   
**Environment:** Floci 2.2.0 (local AWS API emulator, Docker Compose, hybrid storage), account 000000000000, us-east-1    

**Support path:** A. The eks API works and Floci starts a real Kubernetes cluster (k3s v1.30) for it, so both the AWS half and the Kubernetes half of the lab really ran.

**Note on this run:** I first did this lab on an older Floci build. After upgrading to 2.2.0 the cluster came back empty after a restart, so I deleted every Lab 07 object and did the whole lab again from Step 1 on 2.2.0. All evidence in this report is from that second run.

Step by step notes are in `notes/lab-07-notes.md` and the five exercises are in `labs/lab-07-eks/exercises.md`.

> Labels used below:
> **Observed** = I ran it and saw it.
> **Floci limitation** = behaved differently from real AWS.

## 1. Aim / Objective

The aim of this practical is to run the USMS application on Amazon EKS. I created an EKS cluster and a managed node group in Lab 02's VPC, each with its own IAM role, pointed kubectl at the cluster and deployed three microservices (gateway, enrolment and results) from manifests. Then I proved the services find each other by DNS name, did a rolling update and a rollback, broke pods on purpose and diagnosed them, used a ConfigMap and a Secret, tried IRSA, and checked that the cluster survives a restart of Floci.

## 2. Introduction

Amazon EKS is AWS's managed Kubernetes service. AWS runs the control plane (the API server, etcd, the scheduler and the controllers) and I run the data plane, which is the worker nodes where the pods actually run. Everything inside the cluster is normal Kubernetes, so the same manifests would work on any Kubernetes cluster.

The main parts I used in this lab:

- **Cluster and node group** - the control plane, and a managed group of EC2 nodes in the private subnets.
- **Two IAM roles** - the cluster role trusted by eks.amazonaws.com and the node role trusted by ec2.amazonaws.com.
- **Namespace** - a name scope for everything USMS (usms).
- **Deployment and ReplicaSet** - the Deployment describes the pods I want, and the ReplicaSet keeps the right number of them running.
- **Service** - a stable name and ClusterIP in front of a changing set of pods, found through CoreDNS.
- **ConfigMap and Secret** - configuration and sensitive values given to pods as environment variables or files.
- **Probes** - readiness decides if a pod gets traffic, liveness decides if it gets restarted.
- **IRSA** - a way to give one service account its own IAM role instead of sharing the node role.

Kubernetes is important in cloud computing because it is the same everywhere, it keeps the desired state by itself (a deleted pod comes back), and it has a lot of tooling around it. The cost is that there is much more to set up and understand than with ECS.

## 3. Use Case

- Running many small services that call each other by name, like the USMS gateway calling enrolment and results.
- Teams that want the same deployment files to work on AWS, on another cloud and on a laptop.
- Workloads that need fine control over scheduling, for example keeping copies on different nodes or limiting how many can be down during maintenance.
- Organisations that already use Kubernetes tools and want AWS to manage the control plane for them.

## 4. System Architecture / Design

```text
 aws CLI  -> Floci (port 4566) --creates--> EKS control plane (k3s container, https://localhost:6500)
 kubectl  ---------------------------------------^

 namespace usms
   usms-gateway   (1 pod)  --/enrolment/--> Service usms-enrolment --> 2 pods
                           --/results/----> Service usms-results   --> 2 pods
                           --/timetable/--> Service usms-timetable --> 1 pod (Exercise 1)
   ConfigMaps: usms-app-config, one nginx config per service      Secret: usms-enrolment-secret

 AWS side, in Lab 02's VPC
   usms-eks-cluster  4 subnets, usms-eks-cluster-sg (tcp/443 from the VPC only)
   usms-eks-nodes    private subnets, desired 2
   usms-eks-cluster-role -> USMSEKSClusterPolicy
   usms-eks-node-role    -> USMSEKSNodePolicy, USMSStudentDataReadWrite (Lab 01)
```

The gateway's configuration holds service names and no IP addresses. CoreDNS turns a name into the Service's ClusterIP, and kube-proxy spreads the requests over the ready pods behind it.

## 5. Implementation Procedure

1. **Steps 1 to 3** - started Floci, checked the earlier labs and the four subnets, ran the support probe (Path A), and answered the control plane / data plane question.
2. **Steps 4 and 5** - wrote the two trust policies and the two permissions policies and validated them as JSON.
3. **Steps 6 and 7** - created the cluster role with its security group, and the node role with Lab 01's policy as its third holder.
4. **Steps 8 to 10** - built the create-cluster request, assumed usms-developer-role to create the cluster, waited for ACTIVE, then created the node group.
5. **Step 11** - pointed kubectl at the cluster.
6. **Steps 12 to 15** - created the namespace, then the enrolment, results and gateway services.
7. **Step 16** - proved service discovery and load spreading, and watched a deleted pod come back.
8. **Step 17** - created a Secret, decoded it, and gave it to the enrolment pods.
9. **Step 18** - rolled out a config change, rolled it back, and changed an image on results.
10. **Step 19** - caused ImagePullBackOff, FailedScheduling and CrashLoopBackOff on purpose.
11. **Steps 20 and 21** - compared ECS and Kubernetes, and took IRSA as far as this build allows.
12. **Steps 22 to 24** - restarted Floci and compared before and after, wrote configs/lab-07.env and committed.
13. **Section 8** - built and ran verify-lab-07.sh and the smoke test, and wrote (but did not run) the cleanup script.

## 6. Results and Evidence

### 6.1 CLI Output

**Steps 1 and 2 - environment and support path**

![Step 1](../../screenshots/lab7/step1.png)
![Step 1 checks](../../screenshots/lab7/step1-2.png)
![Step 2](../../screenshots/lab7/step2.png)

**Observed:** verify-lab-02 gave FAIL=1 and verify-lab-04 gave FAIL=1, the known Floci limitations from those labs. All four subnets are present. The probe gave PATH A.

**Steps 4 to 7 - policies and roles**

![Step 4](../../screenshots/lab7/step4.png)
![Step 5](../../screenshots/lab7/step5.png)
![Step 6](../../screenshots/lab7/step6.png)
![Step 6 check](../../screenshots/lab7/step6-2.png)
![Step 7](../../screenshots/lab7/step7.png)
![Step 7 check](../../screenshots/lab7/step7-2.png)

**Observed:** the cluster role trusts eks.amazonaws.com and the node role trusts ec2.amazonaws.com. The cluster security group is in usms-vpc with one rule, tcp/443 from the VPC CIDR. USMSStudentDataReadWrite is now on three roles: usms-ec2-app-role, usms-ecs-task-role and usms-eks-node-role. **Floci limitation:** the policies are stored but never enforced, so I checked them by reading them.

**Steps 8 and 9 - the cluster**

![Step 8](../../screenshots/lab7/step8.png)
![Step 8 create](../../screenshots/lab7/step8-2.png)
![Step 9](../../screenshots/lab7/step9.png)
![Step 9 your turn](../../screenshots/lab7/step9-yourturn.png)

**Observed:** the request file holds real IDs and no leftover `$`. While holding the developer role the caller was `assumed-role/usms-developer-role/lab07-eks-build`, so Floci 2.2.0 kept my session name (the older build did not). My first create-cluster ran and the second one returned "Cluster already exists", and describe-cluster confirmed it was the new cluster with my security group. It was ACTIVE in under three minutes, with four subnets, the right VPC and the _lb_ports_ tag. The Your turn printed version 1.30 and an OIDC issuer URL.

**Step 10 - node group**

![Step 10](../../screenshots/lab7/step10.png)
![Step 10 check](../../screenshots/lab7/step10-2.png)

**Observed:** ACTIVE straight away, min 2 / max 4 / desired 2, private subnets only. **Floci limitation:** no EC2 instances are made, so there is no t3.small.

**Step 11 - kubectl**

![Step 11](../../screenshots/lab7/step11.png)
![Step 11 fallback](../../screenshots/lab7/step11-2.png)
![Step 11 check](../../screenshots/lab7/step11-3.png)

**Floci limitation:** `aws eks update-kubeconfig` added the context, but kubectl failed with "You must be logged in to the server", because the k3s server does not accept the `aws eks get-token` login. The handout's fallback uses k3d, which Path A does not have, so I took the cluster's own admin kubeconfig out of Floci's k3s container, changed the port to 6500 and saved it in outputs/ with chmod 600 (it holds a certificate, so it is a credential). After that: one node Ready and `auth can-i` said yes. The cluster has only one node even though the node group says two.

**Steps 12 to 15 - the three services**

![Step 12](../../screenshots/lab7/step12.png)
![Step 13](../../screenshots/lab7/step13.png)
![Step 13 check](../../screenshots/lab7/step13-2.png)
![Step 13 request](../../screenshots/lab7/step13-3.png)
![Step 14](../../screenshots/lab7/step14.png)
![Step 15](../../screenshots/lab7/step15.png)

**Observed:** namespace usms with three labels, set as the default. Enrolment 2/2 with two endpoints, and a request returned JSON with the real pod name, env laboratory and version 1.0.0. Results 2/2 with the default 25% strategy. The gateway came up with no errors and five pods were running.

**Step 16 - service discovery**

![Step 16](../../screenshots/lab7/step16.png)
![Step 16 gateway](../../screenshots/lab7/step16-2.png)
![Step 16 your turn](../../screenshots/lab7/step16-yourturn.png)
![Step 16 your turn later](../../screenshots/lab7/step16-yourturn-2.png)

**Observed:** the service names resolved to ClusterIPs (10.100.x.x), not pod addresses. Twelve requests through the gateway were split 6 and 6 between the two enrolment pods. When I deleted one pod, the ReplicaSet made a new one within a second, all 12 requests still worked, and they all went to the surviving pod until the new one passed its readiness probe.

**Step 17 - ConfigMap and Secret**

![Step 17](../../screenshots/lab7/step17.png)
![Step 17 in the pod](../../screenshots/lab7/step17-2.png)

**Observed:** the Secret's value decoded from base64 straight back to the plain token. I moved the generated Secret file to outputs/ so it is never committed. Inside the pod, printenv showed the four APP_ values and both ENROLMENT_ values in plain text.

**Step 18 - rollout and rollback**

![Step 18](../../screenshots/lab7/step18.png)
![Step 18 undo](../../screenshots/lab7/step18-2.png)
![Step 18 restore](../../screenshots/lab7/step18-3.png)
![Step 18 your turn](../../screenshots/lab7/step18-yourturn.png)

**Observed:** changing the ConfigMap did not change the running pod (still 1.0.0). `kubectl annotate` did nothing, `rollout restart` made a new ReplicaSet and the pod answered 1.1.0. `rollout undo` scaled the old ReplicaSet back up, but the answer was still 1.1.0 because undo does not touch the ConfigMap. In the Your turn the image went to nginx:1.27 and back, and the history showed two revisions.

**Step 19 - three failures**

![Step 19 bad image](../../screenshots/lab7/step19.png)
![Step 19 too big](../../screenshots/lab7/step19-2.png)
![Step 19 crash](../../screenshots/lab7/step19-3.png)
![Step 19 fixed](../../screenshots/lab7/step19-fix.png)

**Observed:** a wrong image tag gave ErrImagePull and then ImagePullBackOff while the two old pods kept serving. A pod asking for 64 CPU stayed Pending with "Insufficient cpu, Insufficient memory". A container that exits 1 gave CrashLoopBackOff, and `kubectl logs` showed "fatal: no database configured". All three were cleaned up and results went back to the right image.

**Steps 20 and 21 - comparison and IRSA**

![Step 20](../../screenshots/lab7/step20.png)
![Step 21](../../screenshots/lab7/step21.png)
![Step 21 service account](../../screenshots/lab7/step21-2.png)

**Observed:** both platforms running side by side; the comparison table is in my notes. For IRSA, the cluster has an OIDC issuer and IAM accepted it as an OIDC provider, and I created the service account. **Floci limitation:** there is no webhook to put the token into pods ("No resources found"), because Floci serves HTTP and the webhook needs HTTPS. So the last two steps of IRSA cannot happen here, and pods still only get the shared node role.

**Step 22 - persistence**

![Before restart](../../screenshots/lab7/step22.png)
![Restart](../../screenshots/lab7/step22-2.png)
![After restart](../../screenshots/lab7/step22-3.png)
![Handout check](../../screenshots/lab7/step22-handout-diff.png)

**Observed:** after a stop and start the cluster was ACTIVE again in about 10 seconds, my kubeconfig still worked, and the before and after lists were identical (PERSISTENCE PROVEN). The Services even kept the same ClusterIPs. The handout's own check said "differences" because its before and after blocks print different things, so I printed the same facts both times.

**Steps 23 and 24, Section 8 - env file, verification, commit**

![Step 23](../../screenshots/lab7/step23.png)
![Verification](../../screenshots/lab7/section8-verify.png)
![Smoke test](../../screenshots/lab7/section8-smoke.png)
![Cleanup script](../../screenshots/lab7/section8-cleanup.png)

**Observed:** configs/lab-07.env has 21 exports and no empty values. verify-lab-07.sh gave **PASS=30 FAIL=0** and the smoke test passed. Nothing under outputs/ was committed.

### 6.2 AWS Management Console Verification

Floci does not have a web console, so there is no console screenshot for this lab. The `describe` and `kubectl get` commands in 6.1 are the verification.

## 7. Analysis and Discussion

The objectives were achieved. The cluster, node group, roles and security group exist and are configured as the handout asks, and the three microservices (four with the exercise) run, find each other by name and pass the smoke test. The most useful results were the ones where Kubernetes fixed things by itself: a deleted pod came back, a broken image never replaced the working pods, and the PodDisruptionBudget in Exercise 4 stopped a drain from taking the last enrolment pod.

Not everything matched real AWS. The node group says two nodes but there is one, the get-token login does not work, IRSA stops at the webhook, and no IAM policy is ever enforced. I wrote these down as Floci limitations.

Problems I ran into and how I fixed them:

- **Step 22 failed at first.** On the old Floci build, a restart brought the cluster back empty with new certificates. I redid the whole lab on 2.2.0, and there the cluster and everything in it survived the restart.
- **kubectl could not log in (Step 11).** I used the cluster's own kubeconfig from the k3s container instead of the k3d command the handout gives for Path B.
- **The handout's persistence check can never pass.** Its before and after blocks print different facts. I compared the same facts both times.
- **The verify script had the same `.gitkeep` bug as Lab 06**, and it also needed KUBECONFIG to be set. I fixed both and marked them `# FIX`.
- **`kubectl set env --from=secret`** added two env entries pointing at the Secret, not an envFrom entry as the handout says. The result in the pod is the same.

Other things I noticed: with only two replicas the default rolling update behaves exactly like maxUnavailable 0, because 25% of 2 rounds down to 0. `rollout undo` warns that it does not update the last-applied configuration, so the manifest files and the cluster can disagree afterwards.

## 8. Reflection

**What I learned.** I already knew some Kubernetes from DSO202, but this lab showed me what EKS adds on top: the two IAM roles, the node group, the cluster in my own VPC, and the split between what AWS runs and what I run. I also learned to read problems in the right order, get pods, then describe, then logs, because for most failures the container never starts and the answer is in the events.

**Challenges.** The hardest part was Step 22. When the cluster came back empty I first thought I had done something wrong. It took some checking to see it was the Floci upgrade, and in the end I chose to redo the lab so all my evidence comes from one version. Getting kubectl to log in was the other challenge, because the handout's fallback did not apply to my path.

**Real world use.** For USMS I would still choose ECS on Fargate, because the team is small and there are no nodes to look after. EKS makes sense when there are many services, when the team already knows Kubernetes, or when the same setup must also run outside AWS.

**What I want to explore more.** EKS Pod Identity and IRSA on a real cluster, so I can see a pod get its own role, and Lab 08's HorizontalPodAutoscaler, since the CPU request and the metrics API are already in place.

## 9. Conclusion

The objectives were achieved. USMS now runs on an EKS cluster in Lab 02's VPC as three microservices (plus timetable from the exercises) that find each other by DNS, with a ConfigMap, a Secret, readiness and liveness probes and a PodDisruptionBudget. I exercised a rolling update, a rollback and three common failures, the setup survived a restart, and everything Lab 08 needs is recorded in `configs/lab-07.env`.

The key ideas I am taking from this lab are the split between the control plane and the data plane, that a Deployment keeps the state I ask for by itself, that a Service gives a stable name in front of pods that come and go, and that a Secret is not encrypted. I also learned to check what the emulator really did, especially after the upgrade, instead of trusting a success message.

## 10. Appendix

- Notes, the ECS comparison and the seven review questions: `notes/lab-07-notes.md`
- Exercises 1 to 5: `labs/lab-07-eks/exercises.md` (Exercise 3's manifest: `labs/lab-07-eks/ex3-usms-broken.yaml`)
- Manifests: `manifests/lab-07/` (namespace, shared ConfigMap, enrolment, enrolment PDB, results, gateway, service account, timetable)
- Policies: `policies/trust-eks-cluster.json`, `policies/trust-eks-node.json`, `policies/usms-eks-cluster-policy.json`, `policies/usms-eks-node-policy.json`
- Request bodies: `templates/lab-07-create-cluster.json`, `templates/lab-07-create-nodegroup.json`
- Recorded names and ARNs: `configs/lab-07.env` (21 exports)
- Scripts: `scripts/utilities/eks-support-probe.sh`, `scripts/utilities/verify-lab-07.sh`, `scripts/cleanup/lab-07-cleanup.sh` (not run)
- Screenshots: `screenshots/lab7/`
- Kept locally and not committed (git-ignored): the kubeconfig, the Secret manifest, the restart comparison, the CPU baseline and the Lab 08 readiness file

**Note on AI use:** I used Claude (an AI assistant) as a guide while doing this lab. I ran every command myself, and the screenshots are from my own terminal. The notes and this report were written with its help, and I read and checked them before committing.
