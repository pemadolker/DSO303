# Lab 08 Notes: EKS Scaling and Exposure

## Step 1: Start and check what Lab 7 left
- Floci up, account 000000000000, kubectl context is `default` (the k3s kubeconfig from Lab 7, outputs/lab-07-kubeconfig.yaml), namespace set to usms.
- usms-enrolment CPU request: {"cpu":"50m","memory":"32Mi"}. This is the number the HPA divides by.
- _lb_ports_ tag: 8081,8082 in both configs/lab-07.env and on the cluster.
- verify-lab-07: PASS=30 FAIL=0.
- I have four Deployments, not three, because usms-timetable was added in Lab 7 Exercise 1. Five ConfigMaps plus kube-root-ca.crt, and the Secret usms-enrolment-secret.
- Enrolment also already has a PDB (minAvailable 1) and spread rules from Lab 7 Exercise 4.

## Step 2: Baseline
- Saved to outputs/lab-08-baseline.txt (not committed).
- enrolment 2/2, gateway 1/1, results 2/2, timetable 1/1.
- All four Services are ClusterIP with no external address.
- One node only: i-acfd2de022a9365b8.ec2.internal, Ready, 8 CPU, about 7.5 GiB. The node group says desired 2, but Floci runs a single k3s node. Node capacity is my whole machine, so the HPA works off the pod request, not the node.
- Lab 7 Exercise 5 files are there (cpu-baseline and lab06-readiness).
- The node carries workload=usms and tier=app (from the Lab 7 node group labels), so a nodeSelector on workload=usms in Step 11 will match.

## Step 3: The four dimensions of scaling
- Horizontal workload: more pods (spec.replicas, moved by me or the HPA). Limit is room on the nodes.
- Vertical workload: bigger pods (requests/limits). The pod gets replaced. Limit is the largest node.
- Horizontal infrastructure: more nodes (node group desiredSize). Limit is maxSize, quota and budget.
- Vertical infrastructure: bigger nodes, which means a new node group and draining the old one. Cannot be done in place.
- ECS on Fargate only has the first two, since there are no nodes to manage.

### Your turn: usms-enrolment at ten times the traffic

Order I would use: 1, then 3, then 2 only if needed, and 4 last.

1. Horizontal workload (more pods) first. I would raise replicas, or let the HPA do it, because it is the fastest change and needs nothing else to move. The gateway reaches enrolment through the Service, so new pods get traffic as soon as they are Ready.
   Check before moving on: every new pod is Running and Ready, the endpoints list grew, and no pod is stuck Pending. If pods are Pending with "Insufficient cpu", the nodes are full and adding more pods does nothing.

2. Horizontal infrastructure (more nodes) next. If pods go Pending, I would raise the node group's desiredSize (up to maxSize), or let Cluster Autoscaler or Karpenter do it.
   Check before moving on: the new nodes join and show Ready in kubectl get nodes, the Pending pods get scheduled onto them, and the endpoints now cover all replicas.

3. Vertical workload (bigger pods) only if one pod at its current size cannot handle a single request well, for example if pods are being CPU throttled or OOMKilled even when there are enough of them.
   Check before and after: kubectl top pods against the limits, and restart counts. Changing requests replaces every pod, and it also changes the HPA's denominator, so the same 50% target now means a different amount of real load. I would re-check the HPA target after this.

4. Vertical infrastructure (bigger nodes) last, and only planned. If pods need more than a node can give, or the node count is getting too high, I would create a second node group with a bigger instance type, cordon and drain the old one (the PDB keeps enrolment up during the drain), then delete it.
   Check: the new node group is ACTIVE and its nodes are Ready before draining, and enrolment stays available the whole time.

Starting with dimension 4 would be wrong because it is slow and cannot be done in place. Skipping dimension 3 would also be wrong, because the HPA can only add pods, not the room to run them.

## Step 4: Scale by hand
- kubectl scale --replicas=5: rollout status counted up 2, 3, 4 of 5 available, then 5/5. Only spec.replicas changed, so the same ReplicaSet (75c78fff5) grew and no new rollout happened.
- Endpoints showed 5 addresses (10.42.0.10, .11, .12 + 2 more). They were added one by one as each pod became Ready, not when it started.
- Traffic test through the gateway: 5 different pod names answered (20, 20, 14, 14, 12). The gateway was not restarted or changed, it still uses the one ClusterIP of usms-enrolment.
- The counts add up to 80 instead of 40, because kubectl could not attach to the busybox pod and fell back to streaming its logs, so the output came twice. The spread across 5 pods is what matters.
- All 5 pods were on the same node, since there is only one node and the Lab 7 anti-affinity is only "preferred".
- Scaled back to 2: the endpoints went back to 10.42.0.3 and 10.42.0.8, which are the two original pods. Kubernetes removed the newest pods first.
- After scaling back to 2, the same traffic test only reached the two remaining pods (21 and 19, adding up to 40 this time since kubectl attached normally).
- On scale-in a pod is taken out of the endpoints first, then gets SIGTERM and 30 seconds grace before SIGKILL. This is like the 30 second deregistration delay on the Lab 5 ALB.

## Step 5: Scaling by manifest and configuration drift
- Part 1: kubectl scale --replicas=6 made the cluster say 6, but the file still says replicas: 2 (line 35 in my file, not 28 like the handout, because my 20-enrolment.yaml has the spread and anti-affinity rules from Lab 7 Exercise 4). Nothing warns about the difference.
- Part 2: kubectl apply on the same file printed "deployment.apps/usms-enrolment configured" and the count went straight back to 2. It silently removed 4 pods. In real life someone applying an unrelated change to this file would wipe out capacity that was added by hand.
- Part 3: changed the file to replicas: 3 and ran kubectl diff first. The diff showed exactly what would change: replicas 2 to 3 (and generation 13 to 14, which is just Kubernetes counting the change). Then apply gave 3.
- kubectl diff exits with 1 when there is a difference. That is not an error, so `|| true` is used to keep the shell going.
- Part 4: put the file back to replicas: 2, applied, removed the .bak files. All four Deployments back at their baseline (2, 1, 2, 1).
- Three ways to avoid drift: never scale by hand (change the file, commit, apply), let the HPA own the replicas field (Step 8), and always run kubectl diff before apply.

## Step 6: Requests, limits and QoS classes
- requests are what the scheduler reserves on a node. limits are what the kubelet enforces while running: going over the CPU limit gets the pod throttled (slowed down), going over the memory limit gets the container OOMKilled and restarted.
- QoS classes:
  - Guaranteed: requests equal limits for CPU and memory in every container. Evicted last.
  - Burstable: requests set but lower than limits. Evicted after BestEffort.
  - BestEffort: nothing set. Evicted first, and the HPA cannot work with it because there is no request to divide by.
- Part 1: every USMS pod (enrolment, gateway, results and timetable) is Burstable, with 50m CPU request and 200m CPU limit.
- Part 2: kubectl describe node shows "Allocated resources" as a percentage of allocatable, not capacity, because the node keeps some CPU and memory back for the kubelet and system. With one node of 8 CPU, the USMS pods only reserve a small part of it.
- Part 3: the HPA target of 50% means 50% of the 50m request per pod, so about 25m on average. It is not 50% of the node and not 50% of the limit. A pod using 30m is at 60% and the HPA would scale out.

### Your turn: gateway to Guaranteed and back
- Before: requests 50m/32Mi, limits 200m/128Mi, pod usms-gateway-9c658748c-b62sd, QOS Burstable.
- Set requests equal to the limits (200m/128Mi for both). The limits did not change, so the pod can do exactly the same amount of work, it just reserves more. New pod usms-gateway-7b5ccf955-2lpj6, QOS Guaranteed.
- Put it back to 50m/32Mi requests and 200m/128Mi limits. New pod usms-gateway-9c658748c-rrnsw, QOS Burstable. The ReplicaSet hash 9c658748c is the original one, because the template was identical again, but the pod itself was still new.
- kubectl diff against manifests/lab-07/40-gateway.yaml showed no difference afterwards, so no drift was left behind.
- The pod was replaced each time, not adjusted in place. Requests and limits are part of the pod template, so changing them is a new template and a rollout. This is dimension 2 from Step 3, and it is why VerticalPodAutoscaler is used much less than the HPA: every resize means restarting pods.
- When I would actually want Guaranteed: for something critical that must not be evicted when the node runs short of memory, like a database or the gateway in a busy period, where reserving the full amount is worth the cost.

## Step 7: The metrics pipeline
- The HPA reads CPU and memory from the metrics.k8s.io API. This is not core Kubernetes, it comes from metrics-server, which is an add-on. The kubelets expose per-container usage, metrics-server collects it and registers the API, and both kubectl top and the HPA read from that API. So if kubectl top works, the HPA has data.
- It only gives CPU and memory. Scaling on something like request count or queue depth (like Lab 6 did with SQS) needs a separate adapter.
- Part 1: APIService v1beta1.metrics.k8s.io is registered and True, metrics-server is 1/1 in kube-system (k3s ships it by default, it has been there 2 days since the cluster was created), and the metrics API is AVAILABLE. So I skipped Parts 2 and 3, and did not need the --kubelet-insecure-tls flag.
- kubectl top nodes: the node at 79m CPU (4%) and 603Mi memory (38%).
- kubectl top pods: every USMS pod idles at 1m CPU and 7 to 8Mi memory. 1m out of a 50m request is 2%. This is the idle figure for Step 9.
- The node percentages looked too high for an 8 CPU node, so I checked capacity against allocatable. Capacity is 8 CPU and about 7.5 GiB (my whole machine), but allocatable is only 1930m CPU and about 1.5 GiB (1588540Ki). Floci reserves the rest for the system and kubelet. kubectl top and the scheduler both use allocatable, which is why 79m showed as 4% and 603Mi as 38%.
- What this means: the scheduler can only place about 38 pods that request 50m CPU each (1930 / 50), not 160 like capacity suggests. The HPA's maxReplicas of 8 fits easily.

## Step 8: The HorizontalPodAutoscaler
- Every 15 seconds the HPA controller reads the CPU of every ready enrolment pod, works out the average as a percentage of the request, then calculates desired = ceil(current replicas x current % / target %), keeps it between min and max, applies the behavior rules, and writes the result into the Deployment's spec.replicas. That is all it does. It is the same as me running kubectl scale, just automatic.
- Worked example from the handout: two pods at 40m with a 50m request is 80%. ceil(2 x 80 / 50) = ceil(3.2) = 4 pods.
- Manifest: manifests/lab-08/10-hpa-enrolment.yaml, autoscaling/v2 (v1 only supports CPU and has no behavior block). Target usms-enrolment, min 2, max 8, CPU 50% of the request.
- I first applied it with the handout's label lab: "05b", which looks like a leftover from an older version of the course, so I changed it to lab: "08" with sed and applied again. It said "configured", the HPA was not recreated, and --show-labels shows lab=08.
- behavior means "scale out fast, scale in slowly", the same idea as Lab 6's ScaleInCooldown 300:
  - scaleUp window 0: react straight away.
  - scaleUp policies with selectPolicy Max: either double the pods or add 2 pods every 15 seconds, whichever allows more. At 2 pods both give +2, at 6 pods doubling gives +6. So it speeds up as the load grows.
  - scaleDown window 300: before removing pods it uses the highest recommendation from the last 5 minutes, so one quiet minute does not remove capacity.
  - scaleDown policy: at most 1 pod per minute, selectPolicy Min takes the slowest option.
- Result: TARGETS cpu: 2%/50%, MINPODS 2, MAXPODS 8, REPLICAS 2. It showed 2% straight away (20 seconds old) because metrics-server was already running.
- Conditions: AbleToScale True (ScaleDownStabilized, "recent recommendations were higher than current one"), ScalingActive True (ValidMetricFound, "the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)"), ScalingLimited False (DesiredWithinRange).
- From now on the HPA owns spec.replicas. kubectl scale would be overwritten within about 15 seconds, and replicas: 2 in the Lab 7 file is only the starting value.

Comparing with Lab 6 (Application Auto Scaling on ECS):
| Lab 06 | Lab 08 | Note |
|---|---|---|
| RegisterScalableTarget with a resource ID string | scaleTargetRef | Here it is a typed reference to the Deployment |
| MinCapacity / MaxCapacity | minReplicas / maxReplicas | Same idea |
| Target tracking on ECSServiceAverageCPUUtilization | cpu averageUtilization | ECS measures against the task's reserved CPU, the HPA against the container's request, so 50 does not mean the same load |
| ScaleInCooldown 300 | scaleDown stabilizationWindowSeconds 300 | Same idea |
| ScaleOutCooldown | scaleUp window plus policies | Kubernetes can also rate limit |
| Two CloudWatch alarms made for you | No alarms, the controller polls | Biggest difference |
| Runs in an AWS service | Runs in the cluster's controller manager | If the cluster is broken, so is the autoscaler |

## Step 9: Load and the HPA moving
- Wrote scripts/utilities/hpa-watch.sh, a read-only loop that prints the HPA CPU, desired replicas, ready replicas and pod count every 10 seconds. Ran it in a second terminal for 90 rounds.
- Load generator: manifests/lab-08/20-loadgen.yaml, 3 busybox pods each looping wget against the gateway's /enrolment/, so both the gateway and enrolment do work. I applied it with the handout label lab: "05b" by mistake and changed it to "08" with sed and applied again. That only changed the Deployment's own label, not the pod template, so the load pods were not restarted.
- What the watcher showed (times are UTC):
  - 06:20:07 to 06:21:28: 2% CPU, 2 replicas (idle).
  - 06:21:38: 42%, then at 06:21:49 the HPA set replicas to 3 (READY 2, PODS 3, the new pod starting).
  - 06:21:59: 59% with 3 ready, then 54%, then it settled at about 40% with 3 pods for the rest of the load.
- Why 3 and not 4 like the handout example:
  - At 54% nothing happens because the HPA has a 10% tolerance. 54/50 = 1.08, which is inside it.
  - At 59% the formula gives ceil(3 x 59 / 50) = 4, but when scaling up the HPA counts pods that just started and have no metrics yet as 0%, so the average it used was lower. By the next check the load was spread over 3 pods and dropped to 54% and then 40%.
  - Three busybox loops on my machine can only make this much load. With 3 pods each one is under 50%, so 3 is the correct answer for this amount of traffic.
- Removed the load at about 06:25:20 (kubectl scale usms-loadgen --replicas=0). CPU dropped to 6% and then 2% within 20 seconds, but replicas stayed at 3 for about 5 minutes. This is the scaleDown stabilizationWindowSeconds 300: the HPA keeps using the highest recommendation from the last 5 minutes, so one quiet period does not take away capacity.
- At about 06:30:30 it went down to 2. It only needed one step because minReplicas is 2.
- HPA events, quoted:
  - "New size: 3; reason: cpu resource utilization (percentage of request) above target"
  - "New size: 2; reason: All metrics below target"
- usms-loadgen is scaled to 0 but still exists, Step 12 uses it again.
- Nothing went Pending. Each enrolment pod requests 50m, and the node has 1930m allocatable, so there was plenty of room for 3 pods (and would be for the max of 8).

## Step 10: Scaling the node group from the AWS side (dimension 3)
- Part 1, node group before (saved to outputs/lab-08-nodegroup-before.json): usms-eks-nodes, ACTIVE, minSize 2, maxSize 4, desiredSize 2, instance type t3.small, subnets subnet-5b834146 and subnet-536f6eab (the two private subnets from Lab 2), labels tier=app and workload=usms.
- Part 2: aws eks update-nodegroup-config with minSize 2, maxSize 6, desiredSize 3 failed with:
  "An error occurred (UnknownOperationException) when calling the UpdateNodegroupConfig operation: Unknown operation: POST /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config"
- So Floci 2.2.0 does not have this operation at all. The handout expected Floci to save the new numbers and just not start a third node, but on my build the change is not even accepted.
- list-updates and describe-update also did not work ("describe-update unsupported on this build"), so I read the node group directly instead.
- Part 3: the node group is still min 2, max 4, desired 2, and Kubernetes still sees one node (i-acfd2de022a9365b8.ec2.internal, Ready, workload=usms). Since nothing changed, Part 4 (putting it back) was not needed. outputs/lab-08-nodegroup-after.json records this.
- What would happen on real AWS: update-nodegroup-config returns an Update object with status InProgress (EKS does every change this way, so you poll describe-update). The node group's Auto Scaling group launches a third EC2 instance, it joins the cluster as Ready within a few minutes, and only then can pods that were Pending be scheduled.
- update-nodegroup-config can only change the scaling numbers (and labels, taints). It cannot change the instance type, AMI, subnets, node role or disk size. Bigger nodes means a new node group (dimension 4).
- The main point: raising replicas (Kubernetes API, Step 9) and raising desiredSize (AWS API, this step) are two separate operations on two different APIs. Nothing links them unless something like Cluster Autoscaler or Karpenter is installed (Step 11).

## Step 11: Cluster Autoscaler, Karpenter and a nodeSelector
- Something has to raise the node group's desiredSize automatically when pods are Pending. The two options:
| | Cluster Autoscaler | Karpenter |
|---|---|---|
| Watches | Pods Pending because no node fits | The same |
| Does | Raises an Auto Scaling group's desired capacity, waits for EKS to add a node from that group | Launches EC2 instances directly, picking an instance type that fits the pending pods |
| Needs declared first | Node groups, one per instance shape | A NodePool of allowed instance families and limits |
| Scale-out time | Minutes | Under a minute |
| Bin-packing | Only as good as the node groups | Picks a size that fits, less waste |
| Maturity | Long-standing upstream project | Newer AWS project, now used beyond EKS |
- Cluster Autoscaler thinks in groups I defined. Karpenter thinks in capacity that would fit.
- Neither is installed here. Both are Deployments that call AWS APIs through IRSA, which Lab 7 showed does not work on Floci, and Cluster Autoscaler also needs a tagged Auto Scaling group, which Floci does not have. On real EKS it needs an IAM policy with autoscaling describe and SetDesiredCapacity, an IRSA role, the Helm chart, and the ASG tags k8s.io/cluster-autoscaler/enabled and k8s.io/cluster-autoscaler/<cluster-name>. What it does is connect Step 9 (Pending pods) to Step 10 (desiredSize).
- Part 1: the node already has workload=usms and tier=app. The label loop in Part 2 printed "not labeled" because the labels were already there, so --overwrite had nothing to change. kubectl get nodes -L workload,tier showed both columns. The node's roles are control-plane,master, so on Floci one k3s node is both the control plane and the worker. On real EKS the control plane nodes are hidden from you.
- Part 3: patched usms-enrolment with nodeSelector workload=usms. It rolled out a new ReplicaSet (6b697978b5), the two new pods 5rmdj and 6ptnd landed on the only node. The old pod 8m9zl was Terminating and had 2 restarts from when Floci was restarted.
- Part 4: patched the nodeSelector to workload=nonexistent. After 15 seconds the new pod 67f6489c4-s6gr6 was Pending and the two old pods were still Running and serving. The FailedScheduling event (from kubectl get events, because describe over all three pods only showed the running ones) said "0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector".
- This shows the selector is enforced, and also that maxUnavailable 0 from Lab 7 protects the service: the rollout cannot remove an old pod until a new one is Ready, so it just gets stuck instead of breaking. Stuck is better than broken.
- Part 5: patched it back to workload=usms. It rolled out instantly and the pods were the same two (5rmdj and 6ptnd). The template matched ReplicaSet 6b697978b5 again, so Kubernetes only had to delete the Pending pod.
- Recorded the change in manifests/lab-07/20-enrolment.yaml so the file matches the cluster (the lesson from Step 5). The handout's Python looks for "spec:" directly followed by "containers:", which would not match my file because of the affinity and topologySpreadConstraints from Lab 7 Exercise 4, so I used a version that inserts the nodeSelector right under the pod template's spec. It went on lines 52 and 53, and kubectl diff printed nothing afterwards.

## Step 12: PodDisruptionBudgets
- Voluntary disruptions go through the eviction API, and a PDB is checked: kubectl drain, a cluster autoscaler removing a node, node upgrades.
- Involuntary disruptions ignore the PDB: a node crash, the kubelet evicting because the node ran out of memory, someone terminating the EC2 instance, hardware failure.
- kubectl delete pod does not use the eviction API, so it goes straight through a PDB.
- Part 1: manifests/lab-08/30-pdb-gateway.yaml has two PDBs.
  - usms-gateway-pdb, minAvailable 1: created. ALLOWED DISRUPTIONS 0, because the gateway only has one replica. A single replica Deployment cannot be both highly available and drainable (Exercise 2 fixes this).
  - usms-enrolment-pdb, maxUnavailable 1: this already existed from Lab 7 Exercise 4 as minAvailable 1, so apply said "configured" and changed it. ALLOWED DISRUPTIONS 1. maxUnavailable is better here because it moves with the HPA's replica count, while minAvailable 1 is a fixed floor.
  - Use minAvailable for a fixed floor, maxUnavailable when the count changes.
  - To avoid drift I also changed manifests/lab-07/25-enrolment-pdb.yaml to maxUnavailable 1, so applying the Lab 7 folder again would not flip it back. The rule now matches. kubectl diff on that file still shows a difference, but only the lab: "08" and project: usms labels that the Lab 8 file adds, which do not change what the PDB does.
- Part 2:
  - Eviction API on the gateway pod (kubectl create --raw to the pod's eviction subresource): refused with "Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget." That is the PDB working.
  - kubectl delete pod on the same pod (usms-gateway-9c658748c-rrnsw): deleted straight away, the PDB said nothing, and the replacement n4kj5 was 0/1 ContainerCreating for a moment. So the gateway was actually down briefly. A PDB is a rule for cooperative processes, not a lock.
- Part 3: kubectl drain --dry-run=client listed every pod it would evict, including the gateway, and said "node/i-acfd2de022a9365b8.ec2.internal drained (dry run)". The client dry run only lists pods and does not call the eviction API, so it does not check PDBs. A real drain would get stuck retrying the gateway eviction until the PDB allowed it. I did not run a real drain, since this one node is the whole cluster, and the node is still Ready (not cordoned).

## Step 13: Rung one, ClusterIP and port-forward
- The exposure ladder, each rung keeps the one below it:
  - ClusterIP (default): reachable only inside the cluster, gives a virtual IP and a DNS name. Most Services should be this.
  - NodePort: also opens the same port (30000 to 32767) on every node. Rarely used directly, it is what LoadBalancer is built on.
  - LoadBalancer: also creates a cloud load balancer with an external address.
  - ExternalName: just a DNS CNAME to something outside the cluster, for example a managed database.
  - kubectl port-forward: not a Service type, it is a tunnel from my terminal through the API server. Debugging only.
- Part 1: all USMS Services are ClusterIP. The gateway's ClusterIP is in 10.100.x.x, and curl to it from my machine failed, because my laptop has no route into the cluster's virtual network.
- Part 2: kubectl port-forward svc/usms-gateway 18080:80 in a second terminal. My second terminal had lost the KUBECONFIG export, so the first try failed with "You must be logged in to the server", because it fell back to the update-kubeconfig file that never worked. After exporting it again the tunnel came up.
- Results through localhost:18080, one "Handling connection for 18080" line per request:
  - / : usms-gateway pod n4kj5, routes /enrolment/, /results/, /timetable/
  - /enrolment/ : pod 6b697978b5-5rmdj on i-acfd2de022a9365b8.ec2.internal, env laboratory, version 1.0.0
  - /results/ : pod 7d4678fd86-7ng7s, campus rtc, version 1.0.0
  - /timetable/ : pod 75b4cd7c79-5bhc8, campus rtc, version 1.0.0 (the extra route from Lab 7 Exercise 1)
- The request reached the app through the API server, not through any networking I set up.
- Why port-forward is for debugging only: it is one tunnel to one pod (no load balancing), it only exists while the command runs on my machine, and all traffic goes through the control plane.

## Step 14: Rung two, NodePort
- type NodePort gives the Service one port (30000 to 32767) that is opened on every node. kube-proxy forwards it to any ready pod of the Service, even pods on other nodes. Because the port is the same on every node, a load balancer only needs to know "any node, port 30080".
- Part 1: manifests/lab-08/40-service-nodeport.yaml, a second Service usms-results-np that selects the same results pods. usms-results itself is unchanged. Result: NodePort, ClusterIP 10.100.212.149, PORT(S) 80:30080/TCP. So the ClusterIP on port 80 is still there and the node also answers on 30080. nodePort 30080 is pinned so it is predictable, but it could clash with another Service.
- Parts 2 and 3: the node's InternalIP is 172.17.0.2 (the Docker bridge, since the k3s node is a container). I only have one node, so I called it 4 times from a busybox pod instead of looping over nodes. The answers came from both results pods (7ng7s three times, xthld once), so the NodePort spreads across the pods.
- Part 4 from my own machine:
  - curl localhost:30080 failed. The node is a container and port 30080 was never published to my host. This is the Floci limitation in the handout.
  - curl 172.17.0.2:30080 did work and answered from xthld. My host can reach the Docker bridge network directly, so the NodePort really is open on the node. On real AWS the nodes are EC2 instances in the VPC and anything the security group allows can reach the NodePort, which is how a load balancer reaches them.
- Fallback: kubectl port-forward svc/usms-results-np 30080:80, then curl localhost:30080 answered from 7ng7s. This only proves the Service works, not that the NodePort is reachable from outside.

## Step 15: Rung three, LoadBalancer
- type LoadBalancer does everything NodePort does, and then a controller creates a load balancer and writes its address into status.loadBalancer.ingress. <pending> means it is not done yet, or that no controller is listening. One LoadBalancer Service means one load balancer and one bill, which is the cost argument for Ingress.
- Part 1: manifests/lab-08/50-service-loadbalancer.yaml is a full Service called usms-gateway that replaces the Lab 7 ClusterIP one (so the repo describes the cluster, not a patch). apply said "configured". The ClusterIP stayed 10.100.65.173, so the other services that reach the gateway by name were not affected, and a nodePort 30424 was added automatically.
- The three annotations are the only EKS-specific part, and they do nothing locally:
  - aws-load-balancer-type: external means use the AWS Load Balancer Controller, not the old in-tree one.
  - aws-load-balancer-nlb-target-type: ip registers pod IPs as targets, not node IPs. This is the same as the ip target type in Lab 5, for the same reason: a pod, like a Fargate task, has its own VPC address, so the load balancer can reach it directly without the NodePort hop.
  - aws-load-balancer-scheme: internet-facing puts the load balancer in the public subnets from Lab 2 (internal would use the private ones).
- Part 2: the watch showed EXTERNAL-IP <pending> first and then 172.17.0.2 a few seconds later. k3s has a built-in load balancer called ServiceLB. It started a pod svclb-usms-gateway-13c4f231-gxvlq in kube-system that listens on port 80 of the node and forwards to the Service. So on Floci the "load balancer" is just a pod on the node, and its address is the node's IP.
- Part 3:
  - localhost:8081 and localhost:8082 (the _lb_ports_ from Lab 7) returned nothing.
  - curl to the EXTERNAL-IP 172.17.0.2 from my machine worked: usms-gateway pod n4kj5, routes /enrolment/, /results/, /timetable/.
- Verify, the whole ladder on one object: type=LoadBalancer clusterIP=10.100.65.173 nodePort=30424 external=172.17.0.2. LoadBalancer contains NodePort contains ClusterIP. Endpoints: 10.42.0.39:80 (the one gateway pod).
- On real EKS with the AWS Load Balancer Controller this would create an NLB in the public subnets with the pod IPs as targets, and EXTERNAL-IP would be a DNS name like k8s-usms-usmsgat-xxxx.elb.us-east-1.amazonaws.com.
- Why 8081 and 8082 were empty: docker ps shows the only published port on the k3s container is 0.0.0.0:6500->6443 (the Kubernetes API). The _lb_ports_ tag (8081,8082) is stored on the cluster, but this Floci build never published those ports, so nothing on my host listens on them. On my machine the LoadBalancer is reachable only through the Docker bridge IP 172.17.0.2, which works because the k3s node is a container on that bridge.

## Step 16: Rung four, Ingress
- An Ingress is just a set of HTTP routing rules. It does nothing by itself, an ingress controller has to implement it:
  - Traefik: routing inside a pod in the cluster, the default on k3s.
  - ingress-nginx: the same idea with nginx.
  - AWS Load Balancer Controller: creates a real Application Load Balancer in the VPC.
- Part 1: no IngressClass and no controller pods. Floci starts k3s with Traefik turned off, so this is the no-controller case.
- Part 2: manifests/lab-08/60-ingress.yaml, usms-portal-ingress with four paths. I added /timetable to the handout's three because my gateway also serves it, otherwise /timetable would only work through the gateway's / rule. I first applied the handout version (label lab: 05b, no timetable) by mistake, then rewrote the file and applied again, which said "configured".
- Result: CLASS <none>, ADDRESS empty, Events <none>. But describe shows the API server already resolved every path to pod IPs:
  - /enrolment to usms-enrolment:80 (10.42.0.37, 10.42.0.38)
  - /results to usms-results:80 (10.42.0.24, 10.42.0.23)
  - /timetable to usms-timetable:80 (10.42.0.25)
  - / to usms-gateway:80 (10.42.0.39)
  That is exactly the list an ALB controller would register as ip targets. There is just nothing here to do it.
- Part 3: nothing on localhost:8081, ingress address none, status loadBalancer {}. The Ingress is a valid, stored object with nothing acting on it. On real EKS the same object gives an internet-facing ALB in the public subnets.
- Routing rules: the longest matching path wins, not the order written, so /enrolment/x goes to usms-enrolment even though / also matches. Lab 5's ALB used a numeric priority on each rule instead. pathType Prefix matches whole path segments, so /results matches /results/2026 but not /resultsarchive.
- /enrolment through the Ingress goes straight to the enrolment Service and skips the gateway, which normally strips the prefix and adds headers.

### What the AWS Load Balancer Controller would have done for me (the Lab 5 commands)
Since there is no controller, here is what the controller would run on real EKS, in order, which is what I did by hand in Lab 5:
1. aws elbv2 create-target-group, one per backend Service (enrolment, results, timetable, gateway), each with --target-type ip and the health check path /healthz from the annotation.
2. aws elbv2 create-load-balancer, an internet-facing ALB in the two public subnets (scheme annotation).
3. aws elbv2 create-listener on HTTP 80 (listen-ports annotation), with the default action forwarding to the gateway target group (the / path).
4. aws elbv2 create-rule, one per path (/enrolment, /results, /timetable) with a priority, forwarding to that path's target group.
After that it keeps calling register-targets and deregister-targets as the pod IPs in the Endpoints change, which ECS did for me in Lab 5. The tags annotation gets added to everything it creates.
- The big difference: in Lab 5 I ran each of those commands myself, here one Ingress object asks for the same ALB. Ten paths on one Ingress is still one load balancer, while ten LoadBalancer Services would be ten.

## Step 17: Practical 2 and Practical 4, compared with both running

What was running when I wrote this:
- ECS: usms-enrolment-svc desired 2, running 2, task definition usms-enrolment:2, behind target group usms-enrolment-tg, health check grace 60s. Scalable target service/usms-ecs-cluster/usms-enrolment-svc, min 2, max 10. Three policies: usms-enrolment-cpu-target-tracking (TargetTracking), usms-enrolment-requests-target-tracking (TargetTracking) and usms-enrolment-queue-step-out (StepScaling).
- EKS: enrolment 2/2, gateway 1/1, results 2/2, timetable 1/1, loadgen 0/0. HPA cpu 2%/50%, min 2, max 8, 2 replicas. Services: three ClusterIP, usms-gateway LoadBalancer (172.17.0.2, 80:30424), usms-results-np NodePort (80:30080). Ingress usms-portal-ingress with no class and no address. PDBs: enrolment maxUnavailable 1 (1 allowed), gateway minAvailable 1 (0 allowed).

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | The ECS service's desiredCount | The Deployment's spec.replicas |
| Who writes it? | Application Auto Scaling | The HPA controller |
| Where does that thing run? | In AWS, as a regional service outside anything I own | In the cluster's controller manager. On EKS AWS runs the control plane, so it is close to the same, but it is still part of my cluster |
| Where does the metric come from? | CloudWatch (ECS service CPU, ALB request count per target, and my SQS queue depth metric for step scaling) | metrics-server through the metrics.k8s.io API, polled every 15 seconds |
| What does "50% CPU" mean, 50% of what? | 50% of the CPU reserved for the task in the task definition | 50% of the container's CPU request, so 25m of the 50m request |
| How is scale-in slowed down? | ScaleInCooldown 300 seconds | scaleDown stabilizationWindowSeconds 300 plus a limit of 1 pod per 60 seconds |
| What happens if there is no capacity for the new instance/pod? | On Fargate this basically does not happen, AWS finds room for the task | The pod sits Pending until a node is added, which needs Cluster Autoscaler or Karpenter (not here) |
| What creates the alarms, if anything? | Target tracking creates its own CloudWatch alarms (a high and a low one per policy). For step scaling I made the queue alarm myself | Nothing. There are no alarms, the controller just polls the metric |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | One ALB (usms-enrolment-alb), one ip target group (usms-enrolment-tg), a listener, the listener rules and the security groups, each with its own aws elbv2 or ec2 command | None. One Ingress object, and on real EKS the controller would create the same ALB objects for me |
| What is the target type, and why? | ip, because Fargate tasks use awsvpc networking and each task has its own IP in the VPC | ip (target-type annotation), because with the VPC CNI each pod has its own VPC IP, so the ALB can skip the NodePort hop |
| How are targets registered and deregistered? | The ECS service registers and deregisters tasks itself, with the 30 second deregistration delay | The controller watches the Service Endpoints and registers or deregisters pod IPs as they change. On Floci nothing does this because there is no controller |
| How are competing routing rules disambiguated? | A numeric priority on each listener rule | The longest matching path wins |
| What would I change to move this to another cloud? | Almost everything. ECS, the ALB commands and Application Auto Scaling only exist on AWS | Mostly just the annotations and the ingress class. The Deployments, Services, HPA and Ingress rules would carry over |
| What is the cost of exposing ten services? | One ALB can serve them all with ten target groups and rules, but I build every one by hand | One Ingress, one ALB. Ten LoadBalancer Services instead would be ten load balancers and ten bills |

### Two paragraphs, in prose

1. If the AWS control plane has a bad afternoon: on ECS, the tasks that are already running keep running, but scaling depends on CloudWatch and Application Auto Scaling, which are both AWS services, so if they are having problems nothing scales and I can only look at it through the same AWS APIs or console that are having the problem. On EKS, the pods also keep running on the nodes. If only CloudWatch or Application Auto Scaling is broken, the HPA does not care, because its metrics come from metrics-server inside the cluster. If the EKS API server itself is down, then the HPA stops and kubectl stops working too, which I saw on Floci every time it restarted: kubectl failed until the cluster woke up. As long as the API server is up, Kubernetes is easier to debug because kubectl describe, events and the HPA conditions tell me exactly what it decided and why.

2. For USMS, one small team, one region, quiet for eight months and very busy for two, I would choose ECS on Fargate. There are no nodes to manage, so the "no capacity" problem from Step 9 does not exist, Lab 6 already covered the busy period with target tracking, step scaling on the queue and scheduled scale-out, and the team only has to learn AWS, not AWS plus Kubernetes. The strongest argument against my choice is lock-in: every part of the ECS setup (the service, the ALB commands, Application Auto Scaling) only works on AWS, while the Kubernetes manifests would move to another cloud with only the annotations changed. If USMS grows into many more services or has to leave AWS, the work I did for ECS would have to be redone, and one cluster with one Ingress would be cheaper to run than many separate pieces.

## Step 18: Persistence across a restart
- Part 1: recorded the HPA bounds, both PDBs, every Service type and nodePort, the Ingress paths and the node group scaling config into outputs/lab-08-before-restart.txt (07:37:52 UTC).
- Part 2: floci-down.sh (docker compose stop, which keeps the data directory, not down -v), then floci-up.sh. Instead of the handout's update-kubeconfig fallback, which never worked for me in Lab 7, I used a loop that calls describe-cluster until ACTIVE and then waits for the API server. It said "waiting for ACTIVE..." once, then ACTIVE, and kubectl cluster-info showed the control plane, CoreDNS and metrics-server running at https://127.0.0.1:6500. Storage mode is hybrid.
- Part 3: read the same things back into outputs/lab-08-after-restart.txt (07:39:33 UTC) and diffed them without the timestamp lines. Result: "PERSISTENCE PROVEN - scaling and exposure configuration identical".
  - usms-enrolment-hpa: min 2, max 8, target 50
  - usms-enrolment-pdb: maxUnavailable 1. usms-gateway-pdb: minAvailable 1
  - usms-gateway LoadBalancer nodePort 30424, usms-results-np NodePort 30080, the other three ClusterIP
  - usms-portal-ingress: /enrolment, /results, /timetable, /
  - node group: min 2, max 4, desired 2 (unchanged since update-nodegroup-config is not supported on this build)
- The handout said the gateway's nodePort might change because it was auto-allocated, but it stayed 30424. That is because the Service object itself was stored, not recreated. usms-results-np was pinned to 30080, which is the safer way if anything outside depends on the port.
- All of these are stored objects in the cluster's datastore, so they survive a restart. The things that act on them (the HPA controller, the svclb pod giving the EXTERNAL-IP) restart and pick them up again. On real AWS a load balancer lives outside the cluster and keeps its address anyway.

## Step 19: configs/lab-08.env
- 19 exports, all looked up live from the cluster and Floci when the file was written (the heredoc is unquoted on purpose so the $(...) commands run). Names, ports and numbers only, no secrets, so it is safe to commit.
- Values: HPA 2..8 at 50% CPU with a 300s scale-in window, NodePort usms-results-np on 30080, usms-gateway LoadBalancer with nodePort 30424, node group 2/4/2.
- The only empty value is USMS_INGRESS_CLASS, because there is no ingress controller (Step 16). The handout lists this as an expected exception.
- The node group values are 2/4/2, not the handout's 2/6/3, because update-nodegroup-config is not supported on my Floci build (Step 10).
- I named the last variable USMS_K8S_MANIFEST_DIR_08 instead of the handout's _05B. The "05b" looks like a leftover from an older numbering of this lab (the same as the lab: "05b" labels I changed in the manifests). Nothing reads this variable, so it is only for consistency.

## Section 8: Verification and cleanup
- scripts/utilities/verify-lab-08.sh: the handout script with three fixes marked # FIX:
  - it exports KUBECONFIG to outputs/lab-07-kubeconfig.yaml itself, so it works in any terminal (same as my Lab 7 fix).
  - "Ingress declares three paths" changed to "at least three", because my Ingress has four (/timetable added).
  - the "no secret is tracked by git" check ignores outputs/.gitkeep, which is tracked on purpose. The handout version would always fail because of it (same bug as in Labs 6 and 7).
- Result: PASS=33 FAIL=1. The one FAIL is "node group maxSize was raised to 6", because update-nodegroup-config is not supported on Floci 2.2.0 (Step 10). I left that check as it is, since it is the honest result. The handout expects the same failure on Path B.
- The _lb_ports_ tag check passed. The tag is stored on the cluster even though Floci never published the ports (Step 15).
- Smoke test through the gateway's DNS name for /, /enrolment/, /results/ and /timetable/: SMOKE TEST PASSED.
- scripts/cleanup/lab-08-cleanup.sh: written and syntax checked, NOT run. It removes things in this order: Ingress, then the LoadBalancer (patched back to ClusterIP) and the NodePort Service, then the HPA and PDBs, then the load generator, then the node group on the AWS side. Things that reference others go first, and anything that would create real cloud infrastructure (a load balancer) is released first, because a load balancer left behind by a deleted cluster keeps costing money and is hard to find. It has to run before lab-07-cleanup.sh. I added the same KUBECONFIG line as the verify script.
- Note: the cleanup also deletes usms-enrolment-pdb, which was first created in Lab 7 Exercise 4. Re-applying manifests/lab-07/25-enrolment-pdb.yaml would bring it back if needed.
- After the Step 18 restart the gateway's EXTERNAL-IP changed from 172.17.0.2 to 172.17.0.3, because Docker gave the k3s node container a new bridge IP. The Service object persisted, but the address that fulfils it did not. On real AWS the load balancer lives outside the cluster and its DNS name stays the same, which is what clients should use.

## Exercise 1: A second autoscaler for usms-results
- Checked usms-results has a CPU request first (50m, from Lab 7), since the HPA cannot work without it.
- manifests/lab-08/11-hpa-results.yaml: autoscaling/v2, target usms-results, min 2, max 6, CPU 60%, scaleUp adds at most 2 pods every 30 seconds, scaleDown stabilisation window 180 seconds. Client dry run passed ("created (dry run)") before applying for real.
- kubectl get hpa now shows two HPAs: usms-enrolment-hpa cpu 2%/50% (2 to 8) and usms-results-hpa cpu 2%/60% (2 to 6), both with 2 replicas and ScalingActive True.
- I did not write any scaleDown policies, so Kubernetes filled in its default: Percent 100 every 15 seconds. That means once the 180 second window passes, results can drop back to the minimum in one go, unlike enrolment which I limited to 1 pod per minute. For a read-mostly service that is fine, for enrolment I wanted it slower.
- Why 60% for results and 50% for enrolment: results is read-mostly and its traffic builds up more gradually (students checking results after they are released), so it can run hotter before adding pods, while enrolment has sudden spikes when registration opens and needs more headroom per pod to absorb the first burst while new pods start.

## Exercise 2: Making the gateway drainable
- Problem from Step 12: usms-gateway-pdb (minAvailable 1) on a single replica gateway allows 0 disruptions, so a drain would hang forever on it. The PDB is not the thing to change, the single replica is. I kept minAvailable 1.
- While checking manifests/lab-07/40-gateway.yaml I found two problems:
  - the file still had the old ClusterIP usms-gateway Service, which Step 15 replaced with the LoadBalancer one. kubectl diff on the file showed it would turn the gateway back into a ClusterIP and drop the nodePort and external IP. So the file could never be clean, and applying it would quietly undo Step 15.
  - the live Service had the label lab: 05b, because I had applied the handout version of 50-service-loadbalancer.yaml in Step 15. Fixed with sed and applied again (lab=08, type, nodePort 30424 and IP 172.17.0.3 unchanged).
- Fix: removed the Service from the Lab 7 file with a small Python script and left a comment saying it moved to manifests/lab-08/50-service-loadbalancer.yaml, so two files no longer fight over the same object. Then changed replicas: 1 to replicas: 2.
- kubectl diff before applying showed only replicas 1 to 2 (and generation 4 to 5). After apply: "clean: 40-gateway.yaml matches the cluster".
- Result: usms-gateway-pdb now has ALLOWED DISRUPTIONS 1. Two gateway pods (n4kj5 and the new j8m55), same ReplicaSet 9c658748c because only the count changed.
- Proof: the same eviction API call that was refused in Step 12 now returned "status":"Success","code":201 for j8m55. It was replaced by vghxz while n4kj5 kept serving, so the gateway was never down. While vghxz was still 0/1 starting, ALLOWED DISRUPTIONS went back to 0, so the PDB would have refused a second eviction until the new pod was Ready. That is what makes a drain safe: one gateway pod at a time.
- Spreading across nodes: I only have one node, so both pods are on it. On a cluster with more nodes I would add a topologySpreadConstraint on kubernetes.io/hostname (maxSkew 1, ScheduleAnyway), the same as I did for enrolment in Lab 7 Exercise 4, so a single node failure or drain cannot take both gateway pods at once. ScheduleAnyway keeps it from blocking scheduling if there is only one node.

## Exercise 3: The autoscaler that will not act
- Applied labs/lab-08-eks-scaling/ex3-reports-broken.yaml exactly as given: usms-reports (2 replicas, CPU limit 200m, no request) and usms-reports-hpa (min 4, max 4, 70% CPU).
- What I saw first: the HPA showed cpu: 0%/70% and scaled the Deployment straight to 4 ("New size: 4; reason: Current number of replicas below Spec.MinReplicas"). So the first fault did NOT give <unknown> like the handout expects.
- The reason is a Kubernetes rule: if a container sets a limit but no request, the request is set equal to the limit. The pods showed CPUREQ 200m, CPULIM 200m, QOS Guaranteed. So the HPA did have a denominator, just the wrong one: 70% of 200m means it would only scale at 140m per pod, close to the limit where the pod gets throttled.
- To prove the <unknown> case I removed the CPU limit too (kubectl patch, JSON remove). The new pods had no CPU request or limit (QOS Burstable, because the memory limit still sets a memory request), and the HPA went to cpu: <unknown>/70% with:
  "ScalingActive False FailedGetResourceMetric the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container reports of Pod usms-reports-85cc6c8476-lsq45"
- Fault 1, which gives <unknown>: the container has no CPU request, so the HPA has nothing to divide by. (With only a limit it is hidden, because the limit is copied into the request.)
- Fault 2, which stops it acting even with perfect metrics: minReplicas and maxReplicas are both 4, so every recommendation is clamped to 4 and 4 is the only possible value. The condition showed it: "ScalingLimited True TooFewReplicas the desired replica count is less than the minimum replica count". Under heavy load it would say TooManyReplicas instead and still stay at 4.
- Fixes, one field each, in labs/lab-08-eks-scaling/ex3-reports-fixed.yaml (diff shows only these two):
  - added resources.requests.cpu: "50m"
  - maxReplicas 4 to 8
- After applying: cpu: 0%/70%, min 4, max 8, ScalingActive True (ValidMetricFound), pods 50m request / 200m limit, Burstable. TooFewReplicas is still shown only because at 0% it would like to go below 4, but now it has room to scale up.
- While applying, the rollout said "1 out of 2 new replicas", because the file says replicas: 2. The HPA then set it back to 4 within seconds. Once an HPA owns a Deployment, replicas in the file is only a starting value (Step 8).
- Cleaned up afterwards: deleted usms-reports and usms-reports-hpa.

## Exercise 4: Exposing the results service properly
Brief: results reachable from the university network, at a stable address, on a normal HTTP port, on its own path, without giving enrolment the same exposure, and without a second load balancer. Plus cost and what breaks if the cluster is down.

Is the existing Ingress the answer? No, it is the wrong shape. usms-portal-ingress also has /enrolment, and its / path goes to the gateway, which proxies /enrolment/ too. Anyone who can reach it can reach enrolment. The gateway LoadBalancer Service from Step 15 has the same problem, and on real AWS it would also be a second load balancer (an NLB).

What I built: manifests/lab-08/61-ingress-results.yaml, usms-results-ingress with one rule, /results (Prefix) to the usms-results Service on port 80. Nothing else is in it: the path list is just /results and usms-enrolment appears 0 times in the object.

Rungs of the ladder:
- usms-results stays a ClusterIP Service (rung 1). The Ingress points at it by name, so it keeps working when pod IPs change (they did change after the Step 18 restart, from .24/.23 to .10/.8).
- usms-results-ingress is rung 4 (Ingress). On EKS it becomes an ALB.
- No NodePort or LoadBalancer Service is needed for this (rungs 2 and 3), because with target-type ip the ALB sends traffic straight to the pod IPs.

Choices:
- scheme internal: the ALB goes in the private subnets from Lab 2, so it is reachable from the university network over its VPN or Direct Connect into the VPC, but not from the internet. That is the "university network" part.
- A normal HTTP port: listen-ports HTTP 80. For real use I would add an ACM certificate (alb.ingress.kubernetes.io/certificate-arn) and listen on 443.
- A stable address: the ALB's DNS name does not change, and I would put a Route 53 private record (something like results.usms.internal) in front of it, so the Examinations Office never needs the AWS name. On Floci the closest thing I had was the gateway's 172.17.0.x address, which changed from .2 to .3 after a restart, so it is not stable.
- Its own path: /results with pathType Prefix, so /results/2026 matches but /resultsarchive would not.
- Enrolment not exposed: there is no enrolment rule and no / rule pointing at the gateway.
- No second load balancer: this one Ingress is the only one. I did not make a second type LoadBalancer Service because each one creates its own NLB with its own hourly charge, while one Ingress with any number of paths is one ALB. In production I would also turn usms-gateway back into a ClusterIP and remove usms-portal-ingress, so this ALB is the only load balancer. I kept them in this lab only because the lab and verify script still need them.

What I could not show on Floci: there is no ingress controller, so the Ingress has no ADDRESS and nothing routes through it. On real EKS the AWS Load Balancer Controller (installed with IRSA) would create the internal ALB, an ip target group for usms-results and a listener rule for /results. The scheme, target-type, listen-ports and healthcheck-path annotations are what drive that.

Cost: one ALB is billed per hour plus LCUs (load balancer capacity units) for traffic. In us-east-1 that is roughly $0.0225 an hour, around $16 to $17 a month before traffic (worth checking the current AWS pricing page). Adding more paths to the same Ingress does not add a load balancer. Each extra LoadBalancer Service would add another NLB at a similar base price.

If the cluster were unavailable: the ALB lives outside the cluster, so its DNS name keeps working and it keeps answering. If only the control plane is down, the pods on the nodes keep running and the ALB keeps sending traffic to the IPs it already knows, but nothing updates (no scaling, no new targets). If the nodes or pods are down, the ALB health checks fail and it returns 502 or 503 errors. The Examinations Office would see errors, not a timeout, and nothing comes back until the pods are back.

## Exercise 5: Artefacts for Lab 10
- Part 1: outputs/lab-08-scaling-evidence.json, built with Python from live kubectl get hpa -o json, kubectl get deploy -o json and aws eks describe-nodegroup, plus a UTC timestamp. It has the HPA spec and status, the Deployment's replicas and CPU request, and the node group scaling config with a note that update-nodegroup-config is not supported on this build. python3 -m json.tool accepts it, and git check-ignore shows .gitignore:7:outputs/* protects it.
- Part 2: outputs/lab-08-lab06-readiness.txt.
  - Policy arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite, default version v1.
  - Attached to three roles: usms-ec2-app-role, usms-ecs-task-role, usms-eks-node-role.
  - Bucket ARN read out of the policy document's Resource (not copied from Lab 7): arn:aws:s3:::usms-student-data. The bucket does not exist yet, Lab 10 creates it.
  - The ServiceAccount usms-enrolment-sa (Lab 7 Step 21) has no IRSA annotation yet. Under IRSA it would carry eks.amazonaws.com/role-arn: arn:aws:iam::000000000000:role/usms-enrolment-irsa-role, a dedicated role that trusts only system:serviceaccount:usms:usms-enrolment-sa through the cluster's OIDC provider and has USMSStudentDataReadWrite attached. Not usms-eks-node-role, because every pod on the node would share it, including the load generator and the gateway.
  - Also git-ignored by outputs/*.

### ECS or Kubernetes for USMS
I would keep USMS on ECS with Fargate.

USMS is run by a small team in one region, and its load is quiet for most of the year and very busy for about two months. Fargate fits that, because there are no nodes, and nodes were where most of my extra work in Labs 7 and 8 came from.

Three things I saw myself:
1. In Lab 6, target tracking on ECS created its CloudWatch alarms for me and scaled on CPU, request count and queue depth. In Step 9 the HPA did scale enrolment from 2 to 3 and held it for 300 seconds before going back, but only because k3s already had metrics-server, which I had to check for in Step 7. And it can only use CPU and memory unless I install an adapter, so the SQS queue scaling from Lab 6 has no easy equivalent.
2. In Step 10, more pods also needs more nodes, which is a second scaling loop that only something like Cluster Autoscaler or Karpenter connects to the first. On Floci update-nodegroup-config was not even supported. On Fargate that whole layer does not exist.
3. In Step 12 and Exercise 2 the single replica gateway made a drain impossible until I added a second replica, and Step 11 showed a bad nodeSelector leaves pods Pending. PDBs, drains and node placement are all operational work that ECS on Fargate just does not have.

Add to that the Lab 7 problems: kubectl could not log in with the normal kubeconfig, and after every Floci restart nothing worked until I woke the cluster up.

The strongest argument against my choice is what Step 16 showed. In Lab 5 I built the ALB, target group, listener and rules by hand, all AWS-only. In Kubernetes one Ingress object asked for the same ALB, ten paths would still be one load balancer, and the Deployments, Services, HPAs and Ingress would move to another cloud with only the annotations changed. The HPA's behavior block also gave me finer control (separate scale-up and scale-down rates) than the cooldowns in Lab 6. If USMS grows into many services, or the university wants to leave AWS, Kubernetes would pay off and the ECS work would have to be redone.

## Review questions

### 1. "Scales when the node hits 50% CPU"
That is wrong. averageUtilization 50 is 50% of the container's CPU request, averaged over the ready pods, not 50% of the node. For enrolment that is 25m of the 50m request, while the node has 1930m allocatable. In Step 9 the HPA scaled at 42% to 59% of the request while the node itself was nowhere near busy.

If someone halves the request to 25m and leaves the HPA alone, the same real usage now shows as twice the percentage, so the HPA adds pods much earlier and reaches maxReplicas 8 sooner. It looks like more capacity, because there are more pods, but each pod is only guaranteed half as much CPU, and the scheduler packs twice as many onto a node on paper. Under real load they fight over the same CPU and get throttled. So the workload ends up with less guaranteed capacity, and it hits the max of 8 earlier, leaving no room for a real spike.

### 2. Ten times the traffic by Monday
1. Add pods first (dimension 1): raise the HPA's maxReplicas (and minReplicas for Monday morning) in the manifest. Check: new pods Ready, endpoints grew, nothing Pending.
2. Add nodes (dimension 3): raise the node group's desiredSize and maxSize, or let Cluster Autoscaler or Karpenter do it. Check: new nodes Ready, Pending pods scheduled.
3. Only if single pods are struggling (throttled or OOMKilled), raise the requests and limits (dimension 2). Check kubectl top against the limits, and re-check the HPA target, because the denominator changed.
4. Bigger nodes (dimension 4) is the one that cannot change in place: the instance type of a node group is fixed. Instead I would create a second node group with the bigger type, wait for its nodes to be Ready, then cordon and drain the old one (with the PDBs keeping enrolment and the gateway up) and delete it. That needs planning, so not for Monday.

### 3. Application Auto Scaling outside, the HPA inside
- Failure: Application Auto Scaling keeps working even if something inside my ECS service is broken, because it lives in AWS. The HPA lives in the cluster's control plane, so if the API server is down it stops too. I saw this every time Floci restarted: nothing in the cluster answered until it was woken up. The other way round, if CloudWatch has a problem, ECS scaling stops, but the HPA does not care because its metrics come from metrics-server inside the cluster.
- Debugging and speed: with the HPA I can read exactly what it decided with kubectl describe (the conditions and events like "New size: 3; reason: cpu resource utilization above target"), and it checks every 15 seconds. With Application Auto Scaling I have to go through CloudWatch alarm history and scaling activities, and target tracking alarms need several minutes of datapoints before they fire.

### 4. 4 to 8 replicas, four pods Pending for twenty minutes
There are two separate control loops. The HPA is a Kubernetes loop that writes the Deployment's replicas, and it did its job by setting 8. The node group's desiredSize is an AWS loop that decides how many nodes exist, and nothing told it to change. So the four extra pods are Pending with "Insufficient cpu", because there is nowhere to put them. Nothing connects the two loops unless Cluster Autoscaler or Karpenter is installed, which watches for Pending pods and raises desiredSize (or launches instances directly).

Lowering the CPU request would make the pods "fit" on paper, but the nodes do not actually have more CPU, so all pods end up fighting for it and get throttled. It also changes the HPA's denominator, so the same load now looks like a higher percentage and the HPA asks for even more pods. It hides the problem instead of fixing it.

### 5. NodePort versus LoadBalancer
A NodePort opens the same port (30000 to 32767) on every node, and that is all. A client still needs to know a node's IP, the IPs change when nodes are replaced (on Floci the node went from 172.17.0.2 to 172.17.0.3 after a restart), and if that node dies the client has nothing to fall back to. A LoadBalancer Service adds a load balancer in front with one address, health checks and spreading across all nodes or pods.

Requirement: "students must reach the gateway at one address on port 80 that keeps working when a node is replaced". NodePort fails it (high port, a node IP that changes, no health checking). LoadBalancer meets it (port 80, one stable DNS name on AWS, unhealthy targets removed).

### 6. /enrolment through the Ingress or through the gateway
I would send /enrolment through the gateway and delete the /enrolment (and /results, /timetable) rules from the Ingress, leaving just / to the gateway. The gateway strips the /enrolment prefix before passing the request on and adds headers, and an ALB cannot rewrite paths, so the direct Ingress rule would hand enrolment requests in a different shape than it gets from the gateway. Having one entry point also means one place for routing, logging and headers, and one route to test. The cost is an extra hop and the gateway becoming critical, which is why Exercise 2 gave it two replicas and a PDB that allows one disruption. If the gateway ever needed to be removed, the prefix stripping and headers would have to move into the apps first.

### 7. A PDB did not stop kubectl delete pod
That is correct behaviour. A PDB only limits evictions, which go through the eviction API, and kubectl delete pod does not use that API. Step 12 showed both: the eviction was refused with "Cannot evict pod as it would violate the pod's disruption budget", and the delete went straight through.

Voluntary disruptions are ones something asked for through the API: kubectl drain, node upgrades, a cluster autoscaler removing a node. The PDB is checked for these. Involuntary ones nobody asked for: a node crashing, the kubelet evicting pods because memory ran out, an EC2 instance being terminated. The PDB cannot stop those.

Realistic scenario: during enrolment week the team upgrades the managed node group's AMI. EKS drains the old nodes one by one, and the PDB on enrolment (maxUnavailable 1) and on the gateway (minAvailable 1 with two replicas, from Exercise 2) make the drain wait until replacement pods are Ready, so students never see the gateway or enrolment completely down during the upgrade.
