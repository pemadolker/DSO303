# Lab 02 Review Questions 

#### 1. A colleague creates a subnet, names it public-subnet, tags it Tier=public, and turns on auto-assign public IPv4. Instances launched into it cannot reach the internet. Explain exactly what is missing, and explain why the name, the tag and the public IP address all failed to make it public.

The missing piece is how routing works from the route table of the subnet to the Internet Gateway. A subnet is not a public subnet because of its name, a tag, or because it has hosts with public IP addresses. What matters with respect to the subnet being public is whether there is a route available in its associated route table with the destination of 0.0.0.0/0 pointing to an Internet Gateway attached to the VPC.

This is the issue that caused difficulties for me conceptually prior to performing Stage 13. I thought that "public" was some sort of attribute assigned to the subnet itself, like an option that you check but the subnet is considered public due to the fact that its route table contains a 0.0.0.0/0 route pointing to the internet gateway.

The `name` is simply a string, which does not play any role in routing. The `Tier=public` is the property of the subnet, which is not known by AWS routing systems. Finally, the `MapPublicIpOnLaunch` just implies that new instances launched in the subnet will receive public IP addresses but having a public IP doesn't help if there's no path back to the internet for that IP to actually route through. 


The actual fix is: create/associate a route table with a 0.0.0.0/0 -> igw-xxxx route, and
associate that route table with the subnet. 

#### 2. Security groups are stateful and network ACLs are stateless. Describe a specific USMS request path name the ports and the direction of each leg where that difference changes how many rules you must write. Then say which of the two you would reach for first when a new requirement arrives, and why.

The clearest example from our own build is app tier -> db tier -> back.
Consider the case of a student sending a request to the USMS web server using HTTPS. The request is received on TCP port 443 and an inbound rule in the application security group allows HTTPS traffic. The response sent back to the student will, however, be automatically permitted by the security group.
This is due to the fact that security groups are stateful. 

The situation is different with the network ACL because it is stateless; both the incoming traffic on TCP port 443 and the outbound response have to be allowed separately.
The NACL must also take care of the relevant ephemeral ports for the outgoing TCP 443 traffic.

For a new requirement coming in, I'd reach for security groups first, basically always.
They're stateful (less rules), they can reference each other by group ID which is way more
maintainable than hardcoding CIDR ranges, and they're the more powerful/flexible layer. I'd
only touch NACLs when I require traffic control at the subnet level or an extra measure of security in the network .

#### 3. usms-db-sg allows PostgreSQL from usms-app-sg rather than from 10.0.1.0/24. Give two concrete changes to the USMS architecture that would silently break the CIDR-based version while leaving the group-referenced version correct.

Two changes that would quietly break the CIDR version but leave the group-referenced one
fine:

Firstly, if the web tier is rebuilt in another subnet or if a new subnet in a different CIDR range is introduced (like we did in our public subnet b example), a CIDR policy (ex. 10.0.1.0/24 policy) will stop working silently as soon as new web servers come into play without the defined CIDR range. The group-referenced policy is independent of whatever subnet or CIDR these app tier instances happen to be - as long as they are included in usms-app-sg.

Secondly, if USMS sets up an autoscaling group for the web tier and different private IPs start being assigned to web tier instances over the course of time, a CIDR policy still works as long as instances do not change subnets. However, if at some point a second subnet is added to the web tier (e.g. introducing HA in which multiple subnets are deployed, as we did in the example public subnet-b), the CIDR policy will not be applied. One would need to remember updating the security group every time the topology changes. Group reference always works since membership in usms-app-sg matters, while the location of instances does not matter.


#### 4. The NAT gateway sits in usms-public-subnet-a but exists to serve usms-private-subnet-a. Explain why it must be in the public subnet. Then explain what would happen to the private subnet in AZ b if AZ a became unavailable, and what that implies about where the availability boundary really sits.

The reason why the NAT gateway should reside in the public subnet is that the NAT gateway requires a route to the Internet Gateway. NAT gateway is meant for enabling resources within the private subnet to initiate outbound connections to the Internet without allowing unsolicited inbound connections into them. Internet-bound traffic from the private route table will go to the NAT gateway and use the public subnet and Internet Gateway to connect to the Internet.

In case the private subnet in AZ b relies on NAT gateway which is only located in AZ a, loss of AZ a will lead to the loss of NAT gateway path for the private subnet in AZ b. The resources in AZ b might still exist, but will be unable to communicate with the internet through this NAT gateway.

This example proves that the boundary of the availability zone is not limited by location of the private subnet only. The existence of a dependency like a NAT gateway may result in a cross AZ dependency. It would be better to have separate NAT gateway and private route table in each AZ.


#### 5. This lab created a gateway endpoint for S3. Describe the path a request from a private instance to usms-student-data takes with the endpoint, and the path it would take without one. Identify which path leaves the AWS network and what that costs in money and in exposure.

Using an S3 gateway endpoint allows a request made by an instance in the private subnet to follow the procedures set by the VPC endpoint when sent to usms-student-data. The route is found without any other steps as the request goes directly to S3 via the internal AWS network. As a result, there is no need for the data to go through any networks such as the NAT gateway or the Internet Gateway.

Without the endpoint, the request from the private instance would have followed the route specified by 0.0.0.0/0 as it appears in the private route table. This would have sent the packet to the NAT gateway, thereby incurring costs due to the NAT gateway data-processing.

Moreover, the endpoint can help avoid exposing the service to extra risks, because the endpoint does not require the service to use any internet routable path for accessing S3. However, in our lab, Floci had one limitation; even though the endpoint was correctly created and appeared to be in the 'available' state, Floci did not inject the expected pl-xxxx route into the route table. Thus, we were able to confirm that the endpoint object existed but we could not prove its routing capabilities.

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

