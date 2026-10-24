#!/usr/bin/env bash
# USMS exposure report: one line per network interface in usms-vpc.
# The verdict is computed from the interface's subnet route table, its public address
# and its security groups' ingress rules - never from names, tags or descriptions
# (names are only used as labels).
#
# set -uo pipefail, deliberately WITHOUT -e: one failed lookup (a deleted group, a
# subnet with no table) must not kill the whole report. Each lookup degrades to
# "unknown" and the row still prints, which is more useful than no report at all.
# Read-only. Also writes outputs/lab-09-exposure.json.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
[ -n "$VPC" ] || { echo "USMS_VPC_ID is not set in configs/lab-02.env" >&2; exit 2; }

python3 - "$VPC" "$REPO_ROOT/outputs/lab-09-exposure.json" << 'PY'
import json, subprocess, sys
vpc, out_path = sys.argv[1], sys.argv[2]

def aws(*args):
    for _ in range(3):
        r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            try: return json.loads(r.stdout)
            except Exception: pass
    return None

flt = f"Name=vpc-id,Values={vpc}"
enis = (aws("ec2", "describe-network-interfaces", "--filters", flt) or {}).get("NetworkInterfaces", [])
rts  = (aws("ec2", "describe-route-tables", "--filters", flt) or {}).get("RouteTables", [])
sgs  = {g["GroupId"]: g for g in (aws("ec2", "describe-security-groups", "--filters", flt) or {}).get("SecurityGroups", [])}
# Elastic IP associations: on real AWS they also appear on the interface, but some
# builds only record them here, so read both.
eip_by_eni, eip_by_inst = {}, {}
for a in (aws("ec2", "describe-addresses") or {}).get("Addresses", []):
    if a.get("NetworkInterfaceId"): eip_by_eni[a["NetworkInterfaceId"]] = a.get("PublicIp")
    if a.get("InstanceId"):         eip_by_inst[a["InstanceId"]] = a.get("PublicIp")
inst = {}
for res in (aws("ec2", "describe-instances", "--filters", flt) or {}).get("Reservations", []):
    for i in res.get("Instances", []):
        tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
        inst[i["InstanceId"]] = (tags.get("Name", i["InstanceId"]), i.get("State", {}).get("Name"))

# subnet -> route table: the explicit association, otherwise the VPC's main table
main_rt, by_subnet = None, {}
for rt in rts:
    for a in rt.get("Associations", []):
        if a.get("Main"): main_rt = rt
        if a.get("SubnetId"): by_subnet[a["SubnetId"]] = rt

def igw_route(subnet):
    rt = by_subnet.get(subnet, main_rt)
    if rt is None:
        return None
    return any(str(r.get("GatewayId", "")).startswith("igw-") and r.get("DestinationCidrBlock") == "0.0.0.0/0"
               for r in rt.get("Routes", []))

def group(gid):
    if gid not in sgs:   # not in the first listing: ask for it directly
        g = (aws("ec2", "describe-security-groups", "--group-ids", gid) or {}).get("SecurityGroups", [])
        sgs[gid] = g[0] if g else None
    return sgs[gid]

def internet_ports(gids):
    ports, any_rule, unknown = set(), False, False
    for gid in gids:
        g = group(gid)
        if g is None:
            unknown = True
            continue
        for p in g.get("IpPermissions", []):
            srcs  = [r.get("CidrIp") for r in p.get("IpRanges", [])]
            srcs += [r.get("CidrIpv6") for r in p.get("Ipv6Ranges", [])]
            srcs += [x.get("GroupId") for x in p.get("UserIdGroupPairs", [])]
            srcs += [x.get("PrefixListId") for x in p.get("PrefixListIds", [])]
            if any(srcs): any_rule = True
            if "0.0.0.0/0" in srcs or "::/0" in srcs:
                lo, hi = p.get("FromPort"), p.get("ToPort")
                ports.add("all" if lo is None else (str(lo) if lo == hi else f"{lo}-{hi}"))
    return sorted(ports), any_rule, unknown

rows = []
for e in enis:
    att = e.get("Attachment") or {}
    iid = att.get("InstanceId")
    if iid and iid in inst:
        label, state = inst[iid]
        if state == "terminated": label += " (terminated)"
    elif not iid and e.get("Status") == "available":
        label = "unattached interface"
    else:
        desc = e.get("Description") or e.get("InterfaceType") or "interface"
        label = ("ECS task" if desc.startswith("ECS task") else desc)[:26]
    priv = e.get("PrivateIpAddress") or "-"
    pub  = ((e.get("Association") or {}).get("PublicIp")
            or eip_by_eni.get(e.get("NetworkInterfaceId"))
            or (eip_by_inst.get(iid) if iid else None)
            or "-")
    gids = [g["GroupId"] for g in e.get("Groups", [])]
    igw  = igw_route(e.get("SubnetId"))
    ports, any_rule, unknown = internet_ports(gids)
    if igw is None:      verdict, why = "UNKNOWN",     "no route table found for the subnet"
    elif not igw:        verdict, why = "ISOLATED",    "no igw route on subnet"
    elif pub == "-":     verdict, why = "ISOLATED",    "igw route, but no public address"
    elif ports:          verdict, why = "EXPOSED",     "igw route + sg allows " + ",".join(ports) + " from 0.0.0.0/0"
    elif not any_rule:   verdict, why = "ADDRESSABLE", "igw route + public address, but no ingress rule at all"
    else:                verdict, why = "ADDRESSABLE", "igw route + public address, ingress only from groups or private ranges"
    if unknown: why += " (a group could not be read)"
    rows.append({"name": label, "interface": e.get("NetworkInterfaceId"), "private": priv, "public": pub,
                 "subnet": e.get("SubnetId"), "groups": gids, "verdict": verdict, "reason": why})

order = {"EXPOSED": 0, "ADDRESSABLE": 1, "UNKNOWN": 2, "ISOLATED": 3}
rows.sort(key=lambda r: (order[r["verdict"]], r["name"], r["private"]))
for r in rows:
    print(f'{r["name"]:<26} {r["private"]:<13} {r["public"]:<15} {r["verdict"]:<11} {r["reason"]}')
counts = {}
for r in rows: counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
print()
print("  ".join(f"{k}={v}" for k, v in sorted(counts.items())) + f"  interfaces={len(rows)}")
json.dump({"vpc": vpc, "interfaces": rows, "counts": counts}, open(out_path, "w"), indent=2)
PY
