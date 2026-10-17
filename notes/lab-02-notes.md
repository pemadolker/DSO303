# Lab 02 Review Questions 

#### 1. A colleague creates a subnet, names it public-subnet, tags it Tier=public, and turns on auto-assign public IPv4. Instances launched into it cannot reach the internet. Explain exactly what is missing, and explain why the name, the tag and the public IP address all failed to make it public.

The missing piece is how routing works from the route table of the subnet to the Internet Gateway. A subnet is not a public subnet because of its name, a tag, or because it has hosts with public IP addresses. What matters with respect to the subnet being public is whether there is a route available in its associated route table with the destination of 0.0.0.0/0 pointing to an Internet Gateway attached to the VPC.

This is the issue that caused difficulties for me conceptually prior to performing Stage 13. I thought that "public" was some sort of attribute assigned to the subnet itself, like an option that you check but the subnet is considered public due to the fact that its route table contains a 0.0.0.0/0 route pointing to the internet gateway.

The `name` is simply a string, which does not play any role in routing. The `Tier=public` is the property of the subnet, which is not known by AWS routing systems. Finally, the `MapPublicIpOnLaunch` just implies that new instances launched in the subnet will receive public IP addresses but having a public IP doesn't help if there's no path back to the internet for that IP to actually route through. 


The actual fix is: create/associate a route table with a 0.0.0.0/0 -> igw-xxxx route, and
associate that route table with the subnet. 

#### 2. Security groups are stateful and network ACLs are stateless. Describe a specific USMS request path name the ports and the direction of each leg where that difference changes how many rules you must write. Then say which of the two you would reach for first when a new requirement arrives, and why.

The clearest example in our build is the app tier talking to the database: `usms-web-01` in `usms-public-subnet-a` (10.0.1.0/24) opens a connection to `usms-db-01` in `usms-private-subnet-a` (10.0.3.0/24) on TCP 5432.

- **Leg 1, the request:** 10.0.1.x, random ephemeral port (say 50123) → 10.0.3.x, port 5432.
- **Leg 2, the reply:** 10.0.3.x, port 5432 → 10.0.1.x, port 50123.

With the **security group** I write one rule: `usms-db-sg` allows inbound 5432 from `usms-app-sg`. The reply in leg 2 is allowed automatically, because a security group is stateful and remembers that it let the request in.

With the **NACL** on the private subnet I need two rules, because a NACL is stateless and judges every packet on its own: inbound 5432 from 10.0.1.0/24 for leg 1, and outbound 1024-65535 to 10.0.1.0/24 for leg 2. If I forget the second one, the database receives the query but its answer is dropped on the way out, and the connection just hangs. (In our `usms-private-nacl` these are inbound rule 100 and outbound rule 100, written for the whole VPC range, 10.0.0.0/16.)

(The public subnet uses the default NACL, which allows everything, so a student → web server example would not show the difference in our VPC.)

For a new requirement I would reach for security groups first. They need fewer rules, they can name another group instead of an address range (so they keep working when instances move or scale), and they are attached to exactly the resource being protected. I would only touch the NACL for a subnet-wide rule, such as blocking a known bad address range for everything in the subnet, or as a second safety layer.

#### 3. usms-db-sg allows PostgreSQL from usms-app-sg rather than from 10.0.1.0/24. Give two concrete changes to the USMS architecture that would silently break the CIDR-based version while leaving the group-referenced version correct.

**1. The web tier is spread across two Availability Zones.** For high availability we add web servers in `usms-public-subnet-b`, which is 10.0.2.0/24. They are in `usms-app-sg` like the others, so the group-based rule lets them reach the database straight away. A CIDR rule for 10.0.1.0/24 would refuse them, and it would be silent: there is no error message saying "wrong security group", the database connection simply times out, and the problem only shows up when traffic lands on the new servers.

**2. The web tier moves behind a load balancer into the private subnets.** Lab 05 did exactly this for the enrolment service. If the web servers were moved out of the public subnet into 10.0.3.0/24 and 10.0.4.0/24, with only the load balancer left in public, every one of them would have a new address outside 10.0.1.0/24. They are still in `usms-app-sg`, so the group rule still works, while the CIDR rule would block the whole tier from its own database.

The general point: a CIDR rule describes *where* the client happens to be today, while a group rule describes *what* the client is. Architectures change where things live far more often than what they are. (A CIDR rule can also be too *wide*: anything else placed in 10.0.1.0/24 later, like a bastion or a test box, would get database access without anyone deciding it should.)

#### 4. The NAT gateway sits in usms-public-subnet-a but exists to serve usms-private-subnet-a. Explain why it must be in the public subnet. Then explain what would happen to the private subnet in AZ b if AZ a became unavailable, and what that implies about where the availability boundary really sits.

The reason why the NAT gateway should reside in the public subnet is that the NAT gateway requires a route to the Internet Gateway. NAT gateway is meant for enabling resources within the private subnet to initiate outbound connections to the Internet without allowing unsolicited inbound connections into them. Internet-bound traffic from the private route table will go to the NAT gateway and use the public subnet and Internet Gateway to connect to the Internet.

In case the private subnet in AZ b relies on NAT gateway which is only located in AZ a, loss of AZ a will lead to the loss of NAT gateway path for the private subnet in AZ b. The resources in AZ b might still exist, but will be unable to communicate with the internet through this NAT gateway.

This example proves that the boundary of the availability zone is not limited by location of the private subnet only. The existence of a dependency like a NAT gateway may result in a cross AZ dependency. It would be better to have separate NAT gateway and private route table in each AZ.


#### 5. This lab created a gateway endpoint for S3. Describe the path a request from a private instance to usms-student-data takes with the endpoint, and the path it would take without one. Identify which path leaves the AWS network and what that costs in money and in exposure.

**With the endpoint:** the private instance asks for `usms-student-data`. Its route table, `usms-private-rt`, has a route for the S3 prefix list (`pl-xxxx`) that points at the gateway endpoint, and that route is more specific than `0.0.0.0/0`, so it wins. The request goes straight to S3 over the AWS network, never touching the NAT gateway or the internet gateway.

**Without the endpoint:** the only matching route is `0.0.0.0/0 → usms-nat`. The request goes to the NAT gateway in the public subnet, which swaps the private address for its public Elastic IP and sends it out through `usms-igw` to S3's public endpoint. This is the path that leaves the private network and uses public addressing.

**Money:** the NAT gateway charges $0.045 for every GB it processes, on top of its hourly charge. If the web tier uploads 100 GB of transcripts a month, that is $4.50 a month for nothing. A gateway endpoint for S3 has no charge at all (and if the instance and the NAT are in different AZs, there is cross-AZ data transfer on top).

**Exposure:** through the NAT, S3 traffic shares the same path as all other internet-bound traffic, and S3 sees requests coming from a public IP. With the endpoint, the traffic stays private, and it can also be locked down further: an endpoint policy can limit which buckets are reachable through it, and the bucket policy can require `aws:SourceVpce`, so the bucket only accepts requests that came through our endpoint.

On Floci the endpoint was created and reported `available`, but no `pl-xxxx` route appeared in the route table, so I could confirm the object exists but not prove the routing. The description above is how it works on real AWS.

Source for prices: [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/).

#### 6. Step 23 restarted Floci and looked the VPC up by tag rather than reusing the VPC_ID shell variable. Explain what specifically would not have been proven had the variable been reused. Relate your answer to the failure described in Lab 1 Step 14.

If I use the same variable for $VPC_ID after restarting Floci, it will only confirm that the variable still contains the value in my shell. It won't prove that the VPC itself was kept after restarting. Therefore, the variable will contain the same ID in case the VPC has been removed from the Floci storage.

By re-deriving the ID of the VPC with the help of the Name tag used in the command, the command sends a new request to the API after the restart and searches for the VPC again. If the VPC has not been kept, the look-up would not give the right resource. Thus, finding the VPC and checking for the count of subnets and security groups gives proof of the survival of VPC and other resources after the restart.

The same idea was used in Lab 1 Step 14. The important point here is that one should not think that the fact that the command has been performed successfully means that the resource is saved for the future. The resource has to be checked again after the environment has been destroyed.


#### 7. Floci does not enforce security groups. Given that, explain how you can still be confident that the rules you wrote in Steps 14 and 15 are correct and describe one specific mistake that this lab's verification would catch and one that it would not.

Given that Floci does not enforce security group rules, it is impossible to use a traffic test alone to validate the correctness of those rules. A successful or unsuccessful connection attempt in Floci does not necessarily mean that my security group configuration is correct, since the rules will not be enforced in the simulator.

The only way to validate my configuration is to read the rules defined for each security group via the API and compare them against the requirements. For instance, it is possible to validate that usms-app-sg has the required rules for ports 80 and 443, including SSH access, while usms-db-sg has a PostgreSQL port 5432 rule allowing the traffic from the application security group. This proves that the security groups were configured correctly, but does not prove that the rules will be enforced.

For instance, such validation will catch a bug in the configuration that results in omitting the port 80 requirement or using the incorrect source range for that rule. In other words, the validation catches configuration errors, which can be found by simply checking security group rules declarations.

On the other hand, there might be a case where the security groups are configured correctly but the expected behaviour is influenced by some other component. An example of such a component is an OS firewall or a NACL. Additionally, the limitation discussed above about Floci not enforcing security group rules means that it cannot prove the runtime behaviour of those rules either.

In summary, the verification gives us confidence that the security groups match our design, but does not prove that the network as a whole works the same way in our Floci environment as in the AWS cloud environment.

