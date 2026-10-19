# Lab 07 Notes - EKS (redone on Floci 2.2.0)

I first did this lab on an older Floci build. After upgrading to 2.2.0, Step 22 showed that a restart
rebuilds the Kubernetes cluster empty, so I deleted every Lab 07 object and redid the lab from Step 1 on
2.2.0, so all evidence comes from one version.

## Step 1 - Environment

Floci up (hybrid storage), course.env and lab-01 to lab-04 env files sourced, account 000000000000.
verify-lab-02.sh: PASS=32 FAIL=1 and verify-lab-04.sh: PASS=38 FAIL=1. These are the known Floci
limitations already documented in the Lab 02 and Lab 04 notes, not new problems. The handout asks for
FAIL=0 on Lab 02; I did not change earlier labs to force it.
Subnets: public-a subnet-db54be2f, public-b subnet-2335f16e, private-a subnet-5b834146,
private-b subnet-536f6eab (all four present, two AZs).

## Step 2 - Support path
Probed on 2026-10-19T08:44:51Z
PATH A  - use aws eks throughout

## Step 3 - "EKS is just ECS with different names"

What makes it false: on EKS I run the data plane myself. The nodes are EC2 instances in my account with a
kubelet and a container runtime that I have to patch and upgrade, and the node group has its own IAM role
next to the cluster role. With ECS on Fargate that whole right-hand column of the table was AWS's job, so
there was no node role, no node patching and no second upgrade step.

What makes it nearly true: both have a control plane that AWS runs and I never log into, both take a
desired number of copies of a container and keep that many running, and both hand each task or pod its
own address in my VPC. A Deployment with 2 replicas does the same job as an ECS service with desired count 2.

## Step 4 - Trust policies

policies/trust-eks-cluster.json trusts eks.amazonaws.com (the AWS-run control plane) and
policies/trust-eks-node.json trusts ec2.amazonaws.com (a node is an EC2 instance). Both use
sts:AssumeRole and both are valid JSON. Quoted heredoc, because policy documents must not be expanded
by the shell.

## Step 5 - Permissions policies

USMSEKSClusterPolicy (stand-in for AmazonEKSClusterPolicy): network interfaces for the endpoint (8 actions),
load balancers for LoadBalancer Services (7), and a Deny outside us-east-1.
USMSEKSNodePolicy (stand-in for AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy and ECR read-only):
describe the cluster (3), VPC CNI network interfaces (11), ECR pulls (4), logs scoped to /usms/eks/* (4),
and the same region Deny.
"Resource": "*" on the network actions is needed because the interfaces do not exist until the CNI
creates them. The log group can be named in advance, so it is named. Floci stores these documents but does
not enforce them, so I checked them by reading them, not by whether a command succeeded.

## Step 6 - Cluster role and security group

usms-eks-cluster-role created (trusts eks.amazonaws.com) with USMSEKSClusterPolicy attached
(arn:aws:iam::000000000000:policy/USMSEKSClusterPolicy).
usms-eks-cluster-sg = sg-2f94727a4121dcded in vpc-6c3e1468 (usms-vpc), one inbound rule tcp/443 from the
VPC CIDR only. Unlike Lab 05's public usms-alb-sg, this group fronts an admin API, so it is not open to the
internet. --vpc-id matters: without it the group would land in the default VPC and Step 8 would fail.

## Step 7 - Node role

usms-eks-node-role created (trusts ec2.amazonaws.com) with USMSEKSNodePolicy and USMSStudentDataReadWrite.
list-entities-for-policy on USMSStudentDataReadWrite now shows three roles: usms-ec2-app-role (Lab 03),
usms-ecs-task-role (Lab 04) and usms-eks-node-role. The policy itself was never edited.
A policy on the node role reaches every pod on every node, which is coarse; IRSA (Step 21) is the
fine-grained way.

## Step 8 - Create the cluster

templates/lab-07-create-cluster.json written with an unquoted heredoc, so it holds the real role ARN, all four
subnets (private a/b, public a/b), sg-2f94727a4121dcded and the _lb_ports_ tag 8081,8082. No "$" left in it.
Assumed usms-developer-role to create the cluster. Floci 2.2.0 kept my session name
(assumed-role/usms-developer-role/lab07-eks-build); the older build in Lab 04 replaced it with floci-session.
My first create-cluster ran (its output scrolled away), so the second attempt returned ResourceInUseException:
"Cluster already exists". describe-cluster confirmed it is the new one: created 2026-10-19 16:24 local, my new
security group, four subnets, _lb_ports_ present. Unset the assumed-role credentials afterwards.

## Step 9 - Cluster ACTIVE

describe-cluster: ACTIVE, version 1.30, endpoint https://localhost:6500 (the k3s API server Floci started),
role usms-eks-cluster-role, four subnets, sg-2f94727a4121dcded, vpc-6c3e1468 (usms-vpc), tags including
_lb_ports_ 8081,8082. Saved to outputs/lab-07-cluster.json. Creation took under three minutes locally
(10 to 15 minutes on real AWS).

Your turn: cluster.[version, identity.oidc.issuer] -> 1.30 and
https://oidc.eks.us-east-1.amazonaws.com/id/52C216DC4C7944458AC4F9289BE7E7E0.
The OIDC issuer is the URL where the cluster publishes the keys that sign its service account tokens, so IAM
can trust tokens from this cluster (that is what IRSA uses in Step 21). Floci 2.2.0 returns one in real AWS
format, unlike the handout's expected None, but nothing on the internet serves it, so real STS could not use it.

## Step 10 - Managed node group

usms-eks-nodes: ACTIVE immediately (create-nodegroup already returned ACTIVE, so the wait loop had nothing to
do), scaling min 2 / max 4 / desired 2, private subnets only (subnet-5b834146, subnet-536f6eab), node role
usms-eks-node-role, AMI type AL2023_x86_64_STANDARD, Kubernetes labels workload=usms and tier=app.
Floci limitation: t3.small is recorded but no EC2 instances are provisioned; Step 11 shows what nodes the
cluster really has. Saved to outputs/lab-07-nodegroup.json.

## Step 11 - kubectl

aws eks update-kubeconfig added context usms-eks (arn:aws:eks:...:cluster/usms-eks-cluster) and made it
current, but kubectl cluster-info failed: "You must be logged in to the server (the server has asked for the
client to provide credentials)". The kubeconfig logs in with aws eks get-token; on real EKS that token is
checked against IAM, but Floci's k3s API server does not accept it. This is the handout's exec-plugin failure.
The handout's fallback uses k3d kubeconfig get; on Path A there is no k3d, so I took the cluster's own admin
kubeconfig from Floci's k3s container (/etc/rancher/k3s/k3s.yaml), changed the address from the internal
6443 to the published 6500, saved it as outputs/lab-07-kubeconfig.yaml with chmod 600 (it holds a client
certificate, so it is a credential) and confirmed it is git-ignored (.gitignore:7 outputs/*).
Result: control plane at https://127.0.0.1:6500 with CoreDNS and metrics-server, 1 node Ready
(i-acfd2de022a9365b8.ec2.internal, control-plane, k3s v1.30.10), auth can-i create deployments: yes.
Floci limitation: the node group says desired 2, but the cluster has a single k3s node that is also the
control plane. The node's AGE was 4h55m although the cluster was created 10 minutes earlier, so Floci
reused this morning's k3s data on disk when the cluster was deleted and created again.

## Step 12 - Namespace

manifests/lab-07/00-namespace.yaml applied: namespace/usms created (fresh, nothing left over), Active, labels
project=usms, tier=app, lab=07 (quoted so YAML keeps it a string). Made it the default namespace of the
context, so a forgotten -n usms cannot put objects elsewhere. kubectl get all -n usms: No resources found.
A namespace is a name scope, not a security boundary: pods in different namespaces can still reach each other
unless a NetworkPolicy says otherwise.

## Step 13 - usms-enrolment

usms-app-config (4 keys: APP_ENVIRONMENT, APP_CAMPUS, APP_VERSION, APP_REGION) and 20-enrolment.yaml
(ConfigMap usms-enrolment-conf, Deployment, Service) applied. Rollout succeeded: deployment 2/2, ReplicaSet
usms-enrolment-5cf94ff846 with 2 pods Running (10.42.0.4 and 10.42.0.5, both on the single node
i-acfd2de022a9365b8.ec2.internal), Service ClusterIP 10.100.229.229 with no external IP, endpoints
10.42.0.4:80 and 10.42.0.5:80.
From a throwaway busybox pod, wget http://usms-enrolment.usms.svc.cluster.local/ returned
{"service":"usms-enrolment","pod":"usms-enrolment-5cf94ff846-bvrm7","node":"i-acfd2de022a9365b8.ec2.internal",
"env":"laboratory","version":"1.0.0"}: the downward API filled in the pod and node names, envFrom brought in the
ConfigMap values, and nginx's template step replaced the ${...} placeholders at start-up.
The pods have requests (cpu 50m, memory 32Mi), which Lab 08's HorizontalPodAutoscaler needs, and separate
readiness (traffic) and liveness (restart) probes. Pod addresses are 10.42.x.x from k3s, not VPC addresses as
the VPC CNI would give on real EKS.

## Step 14 - usms-results

30-results.yaml applied: ConfigMap usms-results-conf, Deployment, Service. Rollout went 0 -> 1 -> 2 available.
custom-columns: usms-enrolment 2/2 RollingUpdate maxUnavailable 0; usms-results 2/2 RollingUpdate
maxUnavailable 25% (no strategy written, so the default applies; with 2 replicas that lets one pod be down
during an update). Endpoints: usms-enrolment 10.42.0.4/.5, usms-results 10.42.0.7/.8.
Differences from enrolment on purpose: no liveness probe, default strategy, and campus in the response.

## Step 15 - Gateway

40-gateway.yaml applied (ConfigMap usms-gateway-conf, Deployment 1 replica, Service). Five pods Running on the
one node: 2 enrolment, 2 results, 1 gateway (10.42.0.9). Gateway log: workers started, no emerg lines, and
the kubelet's readiness probe (kube-probe/1.30) getting 200 on /healthz every 5 s.
The gateway config holds two DNS names (usms-enrolment.usms.svc.cluster.local and
usms-results.usms.svc.cluster.local) and no addresses. The trailing slash on proxy_pass strips the matched
prefix, so /enrolment/x reaches the backend as /x. The gateway went in last on purpose: nginx resolves the
upstream names once at start-up, so the backend Services had to exist first.

## Step 16 - Service discovery

From a busybox pod, nslookup returned ClusterIPs, not pod addresses: usms-enrolment.usms.svc.cluster.local ->
10.100.229.229 and usms-results.usms.svc.cluster.local -> 10.100.145.37, answered by CoreDNS at 10.100.0.10
(Floci's k3s uses 10.100.x.x for services, not the 10.43.x.x in the handout).
Through the gateway: / answered by usms-gateway-55f6dfc959-lwjhb, /enrolment/ by an enrolment pod,
/results/ by a results pod (campus rtc). Twelve requests to /enrolment/ were split 6 and 6 between the two
enrolment pods. nginx only knows one name and one ClusterIP; kube-proxy spreads the connections across the
endpoints underneath, which is why Lab 08 can scale enrolment without touching the gateway.

### Your turn - delete a pod

Deleted usms-enrolment-5cf94ff846-bvrm7. Within a second the ReplicaSet usms-enrolment-5cf94ff846 created
usms-enrolment-5cf94ff846-25twq (event: SuccessfulCreate "Created pod: ...-25twq"); the image was already on
the node, so it started in about 2 s. Twelve requests through the gateway right after the delete: ok=12
fail=0, all answered by the surviving pod -m9jzh, because the new pod was still ContainerCreating and its
readiness probe kept it out of the Service's endpoints until it could answer. A second tally a little later
was split between -m9jzh and the new -25twq. The gateway was never restarted or changed.
The replacement was created by the ReplicaSet, not by the Deployment and not by me: the Deployment manages
ReplicaSets, and the ReplicaSet is what keeps the number of pods at 2.

## Step 17 - ConfigMaps and Secrets

Created usms-enrolment-secret from literals (dummy values) with --dry-run=client -o yaml, applied it, then moved
the generated manifest out of manifests/ to outputs/lab-07-secret.yaml (chmod 600, git-ignored by
.gitignore:7 outputs/*). A base64 value in a committed file is readable by anyone with the repo, forever.
base64 is an encoding, not encryption: the stored value ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ=
decoded with base64 -d to floci-dummy-token-not-a-real-secret, with no key and only "get secret" permission.
kubectl set env --from=secret/usms-enrolment-secret triggered a rolling update (a pod template change) and
added two env entries, ENROLMENT_API_TOKEN and ENROLMENT_DB_PASSWORD, each pointing at a key in the Secret
(secretKeyRef). The handout says it adds envFrom.secretRef; on this kubectl, envFrom still lists only
usms-app-config. The effect inside the pod is the same: printenv shows the four APP_* values and both
ENROLMENT_* values in plain text. A Secret protects the value on its way to the pod, not inside it. On real
EKS I would turn on KMS envelope encryption for Secrets and use IRSA instead of storing AWS credentials.

## Step 18 - Rollout and rollback

Changed APP_VERSION to 1.1.0 in the ConfigMap and applied it: the running pod still answered 1.0.0, because a
ConfigMap change does not restart pods. kubectl annotate on the Deployment returned "successfully rolled out"
at once and created nothing, because it changes the Deployment's own metadata, not the pod template.
kubectl rollout restart writes a timestamp into the pod template, so it rolled: the new pod
usms-enrolment-bcd6b8dff-... answered 1.1.0, with a new ReplicaSet hash in its name.
History before the undo: 3 revisions (1 = original 5cf94ff846, 2 = Step 17's Secret env ff96cc87d,
3 = the restart bcd6b8dff), old ReplicaSets kept at 0 replicas.
rollout undo scaled ff96cc87d back up to 2 (it becomes revision 4) and bcd6b8dff down to 0; nothing was rebuilt.
The response still said 1.1.0: undo reverts the pod template, not the ConfigMap, so configuration has to be
versioned together with the workload. kubectl also warned that undo does not update the
last-applied-configuration annotation, so a later kubectl apply of the old manifest could behave unexpectedly;
with apply-managed objects it is cleaner to roll back by applying the previous file.
Restored the ConfigMap to 1.0.0 and restarted, so the lab ends at 1.0.0 with 2/2 ready.

### Your turn - image update on usms-results

kubectl set image deployment/usms-results results=nginx:1.27 (from nginx:1.27-alpine), then
kubectl rollout undo --to-revision=1. The image went 1.27-alpine -> 1.27 -> 1.27-alpine, and rollout history
afterwards lists 2 revisions (2 and 3): undoing to revision 1 re-uses that template as the new revision 3.
Shape of the roll: the peak was 3 pods (2 old Running plus 1 new ContainerCreating while nginx:1.27 was being
pulled), and the old pods kept serving until the new one was ready. I expected the default strategy to differ
from usms-enrolment's maxUnavailable 0 / maxSurge 1, but with 2 replicas it does not: 25% of 2 is 0.5,
maxUnavailable rounds down to 0 and maxSurge rounds up to 1, so it behaved exactly like enrolment. The
difference only shows with 4 or more replicas. kubectl gave the same last-applied-configuration warning on undo.

## Step 19 - Three failures on purpose

Order of questions: kubectl get pods (what state?), kubectl describe pod (why? read the Events), kubectl logs
(what did the app say?). For the first two failures the container never started, so the answer was in the
Events, not the logs.

1. Image that does not exist: set image usms-results to nginx:this-tag-does-not-exist. The new pod went
   ErrImagePull then ImagePullBackOff; the events said "failed to resolve reference
   docker.io/library/nginx:this-tag-does-not-exist: not found" and then "Back-off pulling image". The two old
   pods stayed 1/1 Running the whole time, because the rollout never removes an old pod before a new one is
   ready, so the broken image never took over. The handout's describe | tail -15 cut off the Events, so I read
   them with kubectl get events instead. Fixed with rollout undo, back to nginx:1.27-alpine.
2. Pod that cannot be scheduled: usms-toobig requests 64 CPU and 256Gi. Pending, FailedScheduling:
   "0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory", and preemption found no victims.
   Pending + FailedScheduling means no node can take the pod (resources, taints, nodeSelector or volumes).
   Deleted.
3. Container that exits: usms-crasher prints two lines and exits 1. After 25 s: STATUS Error, 2 restarts, then
   a BackOff event ("Back-off restarting failed container"), i.e. CrashLoopBackOff. Here the container did start,
   so kubectl logs is the right tool: "usms-crasher starting" and "fatal: no database configured". describe
   showed Last State Terminated, Reason Error, Exit Code 1. Deleted.
Events are per namespace, sorted with --sort-by=.lastTimestamp, and expire after about an hour, so they are for
live debugging, not an audit log.

## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | The task definition (usms-enrolment:2), a numbered AWS object | The pod template inside the Deployment (20-enrolment.yaml), a file I apply |
| What keeps N copies alive? | The ECS service (desiredCount 2) | The ReplicaSet, which the Deployment creates and manages (Step 16 showed it replacing a deleted pod) |
| What gives it a stable name? | The load balancer DNS name and target group (Lab 05) | The Service, with a ClusterIP and a DNS name usms-enrolment.usms.svc.cluster.local |
| How does another service find it? | Through the load balancer (or Cloud Map, which we did not use) | CoreDNS: the gateway uses the Service name and kube-proxy spreads the calls over the pods |
| What does a rolling update create? | A new deployment of a new task definition revision | A new ReplicaSet; the old one is scaled to 0 and kept |
| Where does rollback state live? | In the old task definition revisions; I point the service back at one | In the old ReplicaSets (up to revisionHistoryLimit 5); rollout undo scales one back up |
| Which IAM role does the app code use? | The task role usms-ecs-task-role, per task | Here the node role usms-eks-node-role, shared by every pod on the node; IRSA (Step 21) would give one role per service account |
| What would I have to change to move to another cloud? | Almost everything: task definitions, the service, the ALB setup and IAM are all ECS/AWS specific | The manifests would mostly move as they are; the IAM roles, VPC, node group, load balancer setup and IRSA are AWS specific and would have to be redone |

For USMS I would choose ECS on Fargate, because the team is small, there are no nodes to patch, and the task
role already gives each service its own permissions without extra setup. Kubernetes would be worth it later if
USMS grows into many services or needs to run outside AWS, since the manifests are portable but the operating
work is clearly bigger.

## Step 21 - IRSA

Which of the six IRSA steps this build could complete:
1. OIDC issuer published: yes, https://oidc.eks.us-east-1.amazonaws.com/id/52C216DC4C7944458AC4F9289BE7E7E0
   (the handout expected None on most builds).
2. Registered in IAM: yes, create-open-id-connect-provider returned
   arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52C216DC4C7944458AC4F9289BE7E7E0,
   and list-open-id-connect-providers shows it.
3. Role trusting that provider for system:serviceaccount:usms:usms-enrolment-sa: not created, because step 5
   cannot happen, so the role could never be used.
4. ServiceAccount: yes, usms-enrolment-sa in namespace usms (manifests/lab-07/60-serviceaccount.yaml), not
   annotated with a role.
5. Webhook that injects the token and env vars into pods: no. kubectl get mutatingwebhookconfigurations returned
   "No resources found". Floci's log says pod identity injection is off because Kubernetes only accepts an https
   webhook and Floci serves HTTP (FLOCI_TLS_ENABLED=false).
6. Pod calls sts:AssumeRoleWithWebIdentity: not possible without step 5, and on real AWS STS would also need to
   fetch the issuer's keys from that URL, which nothing serves for a cluster on my laptop.
So on this build pods still get AWS access only through the node role (usms-eks-node-role), which every pod on
the node shares. On real EKS, IRSA or EKS Pod Identity would give usms-enrolment its own role and nothing else.

## Step 22 - Persistence across a restart

Before: cluster ACTIVE 1.30, node group ACTIVE desired 2, deployments enrolment 2 / gateway 1 / results 2,
services with ClusterIPs 10.100.229.229, 10.100.65.173, 10.100.145.37 (outputs/lab-07-before-restart.txt).
Restarted with floci-down.sh / floci-up.sh. The cluster showed CREATING once and was ACTIVE about 10 s later;
Floci restarted the k3s container, and the existing kubeconfig still worked (same node, age 9h).
After: re-derived the cluster name from eks list-clusters and the node group from list-nodegroups, then printed
the same facts in the same format. diff: identical, PERSISTENCE PROVEN. The Services kept the same ClusterIPs,
so they survived rather than being recreated. Also still present: the Secret, usms-enrolment-sa, the five
ConfigMaps and the OIDC provider.

Handout bug: its before block prints the node group and the Service IPs, its after block prints the namespace
and ConfigMaps instead, so the diff always shows differences even when nothing was lost. My first run of it said
"differences" while every object was there. I fixed it by printing the same facts both times.

Earlier result, for the record: this morning a restart brought the cluster back empty, with new certificates,
and the old kubeconfig failed with x509 and then a credentials error. That cluster had been created on the
older Floci build before I upgraded to 2.2.0. My reading (from what I observed, not from Floci's documentation)
is that 2.2.0 had no k3s data of its own for that cluster and started a fresh one, while a cluster created on
2.2.0 keeps its k3s data in the hybrid storage folder; the reused node (age 4h55m when I recreated the cluster)
points the same way. On real EKS the control plane and etcd are managed by AWS and are not lost this way.

## Step 23 - configs/lab-07.env

Written with an unquoted heredoc, so the AWS values were looked up once and stored. All values populated
(no empty value, no None), 21 exports, lb_ports 8081,8082. The kubeconfig is not in it: on this build it is
outputs/lab-07-kubeconfig.yaml (git-ignored), taken from the k3s container because the get-token login is
not accepted.

## Section 8 - Verification

verify-lab-07.sh: PASS=30 FAIL=0, run from my home directory to prove it works from anywhere. On Path A all
three EKS checks pass (cluster ACTIVE, _lb_ports_ tag, node group ACTIVE).
Two fixes to the handout's script, both marked "# FIX" in the file:
1. The "no secret is tracked by git" check failed whenever outputs/.gitkeep is tracked (which the course
   requires); replaced with the same check verify-lab-02/04/05/06 use, which allows exactly that one file.
2. The script relied on KUBECONFIG already being exported. It now uses outputs/lab-07-kubeconfig.yaml when it
   exists, because on this build the aws eks get-token kubeconfig is rejected (Step 11).
Smoke test through the gateway: /, /enrolment/ and /results/ all answered (version 1.0.0, campus rtc),
SMOKE TEST PASSED.

## Exercise 5 part 3 - What Lab 08 needs from configs/lab-07.env

- USMS_EKS_CLUSTER: every aws eks call in Lab 08, and the cluster whose kubeconfig kubectl uses.
- USMS_EKS_NODEGROUP: Lab 08 changes the node group's scaling config from the AWS side (data-plane scaling).
- USMS_EKS_NAMESPACE: every kubectl command works in namespace usms.
- USMS_EKS_LB_PORTS: without the 8081,8082 tag a LoadBalancer Service has no host port on Floci, and the only fix
  is recreating the cluster, so this is the one to check before starting.
- USMS_EKS_ENDPOINT: to confirm after a restart that kubectl is talking to this cluster (https://localhost:6500).
- USMS_K8S_DEPLOY_ENROLMENT: the Deployment the HorizontalPodAutoscaler will target.
- USMS_K8S_DEPLOY_GATEWAY: the Deployment whose Service becomes a NodePort, then a LoadBalancer.
- USMS_K8S_CPU_REQUEST: 50m, so I can check the HPA's percentage myself (today 1m = 2%).
The role, policy and security group ARNs are not used by Lab 08 directly; they matter for cleanup and for the
CloudFormation lab later. Also needed but not in the file: outputs/lab-07-kubeconfig.yaml, because on Floci 2.2.0
the aws eks get-token kubeconfig is rejected.


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
