# AWS CLI + Floci — USMS Course Project

Infrastructure for the **University Student Management System (USMS)**, built lab by lab
with the AWS CLI against [Floci](https://floci.io), a local AWS emulator.

## Quick start

```bash
source configs/course.env
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

## Daily workflow

```bash
./scripts/setup/floci-up.sh      # start or resume (idempotent)
# ... lab work ...
./scripts/setup/floci-down.sh    # pause; state is kept
```

## Never run these

| Command | Why |
|---|---|
| `docker compose down -v` | `-v` deletes volumes |
| `docker volume prune` | Unfiltered; use scripts/cleanup/floci-prune-volumes.sh |
| `floci start ...` | Bypasses Compose; disables persistence |
| `rm -rf ~/floci-data` | That directory is the IAM state |

## Labs

| Lab | Topic | Status | Write-up |
|-----|-------|--------|----------|
| 01  | IAM   | [x] complete | `labs/lab-01-iam/`, `notes/lab-01-notes.md` |
| 02  | VPC   | [x] complete | `labs/lab-02-vpc/`, `notes/lab-02-notes.md` |
| 03  | EC2   | [x] complete | `labs/lab-03-ec2/`, `notes/lab-03-notes.md` |
| 04  | ECS on Fargate | [x] complete | `labs/lab-04-ecs/`, `notes/lab-04-notes.md` |
| 05  | ECS behind an ALB | [x] complete | `labs/lab-05-ecs-alb/`, `notes/lab-05-notes.md` |
| 06  | ECS auto scaling | [x] complete (support path C) | `labs/lab-06-ecs-autoscaling/`, `notes/lab-06-notes.md` |
| 07  | EKS | [ ] in progress | `notes/lab-07-notes.md` |

Known Floci limitations (security-group references not returned, `revoke-security-group-ingress`
not applied, no load-balancer data path, and others) are recorded in each lab's notes, with what
real AWS would have done instead.

## Conventions

- All resources are prefixed `usms-`
- Region - `us-east-1`  ·  Floci account: `000000000000`
- Storage mode: `hybrid`, bind-mounted to `~/floci-data`
- Secrets live in `outputs/` and are **never** committed



