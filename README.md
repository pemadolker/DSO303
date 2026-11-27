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

All 14 labs (00–13) are complete.

| Lab | Topic | Status | Write-up |
|-----|-------|--------|----------|
| 01  | IAM   | [x] complete | `labs/lab-01-iam/`, `notes/lab-01-notes.md` |
| 02  | VPC   | [x] complete | `labs/lab-02-vpc/`, `notes/lab-02-notes.md` |
| 03  | EC2   | [x] complete | `labs/lab-03-ec2/`, `notes/lab-03-notes.md` |
| 04  | ECS on Fargate | [x] complete | `labs/lab-04-ecs/`, `notes/lab-04-notes.md` |
| 05  | ECS behind an ALB | [x] complete | `labs/lab-05-ecs-alb/`, `notes/lab-05-notes.md` |
| 06  | ECS auto scaling | [x] complete (support path C) | `labs/lab-06-ecs-autoscaling/`, `notes/lab-06-notes.md` |
| 07  | EKS | [x] complete | `notes/lab-07-notes.md` |
| 08  | EKS scaling | [x] complete | `notes/lab-08-notes.md` |
| 09  | Security hardening (IAM, security groups, IMDS, S3) | [x] complete | `notes/lab-09-notes.md` |
| 10  | Lambda@Edge and CloudFront | [x] complete | `labs/lab-10-lambda-edge/`, `notes/lab-10-notes.md` |
| 11  | CI/CD with CodeBuild and CodePipeline | [x] complete | `labs/lab-11-cicd/`, `notes/lab-11-notes.md` |
| 12  | ECR and deploying to ECS from the pipeline | [x] complete | `labs/lab-12-cicd-deploy/`, `notes/lab-12-notes.md` |
| 13  | CloudWatch logging, monitoring and X-Ray | [x] complete | `labs/lab-13-cloudwatch-xray/`, `notes/lab-13-notes.md` |

Known Floci limitations are recorded in each lab's report and notes, with what real AWS
would have done instead. The main ones:

- Labs 02–05: security-group references not returned, `revoke-security-group-ingress` not applied, no load-balancer data path
- Lab 11: CodeBuild and CodePipeline are recorded but not executed (builds report SUCCEEDED with no logs or artifacts), so the buildspec was proven with the local runner
- Lab 12: the pipeline's ECS Deploy stage fails (no build artifact to read); ECR works for real
- Lab 13: no X-Ray, Logs Insights, alarm history or composite alarms; logs, metric filters, metrics, alarms and dashboards work

## Local setup notes

- `docker-compose.override.yml` puts Lambda containers on Floci's Compose network, so functions can reach the Lambda runtime API (Lab 10)
- `/etc/docker/daemon.json` lists `000000000000.dkr.ecr.us-east-1.localhost:4566` under `insecure-registries`, because Floci's registry is plain HTTP (Lab 12)
- Floci runs ECR as its own registry container on port 5100, so the `5100-5104` range in `docker-compose.yml` stays commented

## Conventions

- All resources are prefixed `usms-`
- Region - `us-east-1`  ·  Floci account: `000000000000`
- Storage mode: `hybrid`, bind-mounted to `~/floci-data`
- Secrets live in `outputs/` and are **never** committed