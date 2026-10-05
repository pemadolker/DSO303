#!/usr/bin/env bash
# No -e on purpose: one failed lookup for one instance must not stop the
# report for the others. -u and pipefail still catch typos.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,PublicIpAddress,SubnetId,SecurityGroups[0].GroupId]' \
  --output text | while IFS=$'\t' read -r name priv pub subnet sg; do

  target=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$subnet" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text 2>/dev/null)

  sgcidrs=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`80`].IpRanges[].CidrIp' \
    --output text 2>/dev/null)

  case "$target" in
    igw-*) hasigw=yes ;;
    *)     hasigw=no ;;
  esac

  if [ "$hasigw" = no ]; then
    verdict="UNREACHABLE"; why="no igw route on subnet"
  elif [ -z "$pub" ] || [ "$pub" = "None" ]; then
    verdict="NO-ADDRESS"; why="igw route present but no public address"
  elif echo "$sgcidrs" | grep -q '0.0.0.0/0'; then
    verdict="REACHABLE"; why="igw route + sg allows 80/tcp from 0.0.0.0/0"
  else
    verdict="BLOCKED"; why="igw route but sg does not allow 80 from 0.0.0.0/0"
  fi

  [ "$pub" = "None" ] && pub="-"
  printf '%-14s %-12s %-16s %-12s %s\n' "$name" "$priv" "$pub" "$verdict" "$why"
done