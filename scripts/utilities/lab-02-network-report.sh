#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

subnet_ids=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$USMS_VPC_ID" \
  --query 'Subnets[].SubnetId' --output text)

for s in $subnet_ids; do
  name=$(aws ec2 describe-subnets --subnet-ids "$s" \
    --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)
  cidr=$(aws ec2 describe-subnets --subnet-ids "$s" \
    --query 'Subnets[0].CidrBlock' --output text)
  az=$(aws ec2 describe-subnets --subnet-ids "$s" \
    --query 'Subnets[0].AvailabilityZone' --output text)

  rt=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$s" \
    --query 'RouteTables[0].RouteTableId' --output text)

  if [ -z "$rt" ] || [ "$rt" = "None" ]; then
    printf '%-24s %-14s %-12s ISOLATED no route table\n' "$name" "$cidr" "$az"
    continue
  fi

  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' --output text)
  nat=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' --output text)

  if [ "$igw" != "None" ] && [ -n "$igw" ]; then
    printf '%-24s %-14s %-12s PUBLIC   via %s\n' "$name" "$cidr" "$az" "$igw"
  elif [ "$nat" != "None" ] && [ -n "$nat" ]; then
    printf '%-24s %-14s %-12s PRIVATE  via %s\n' "$name" "$cidr" "$az" "$nat"
  else
    printf '%-24s %-14s %-12s ISOLATED no default route\n' "$name" "$cidr" "$az"
  fi
done
