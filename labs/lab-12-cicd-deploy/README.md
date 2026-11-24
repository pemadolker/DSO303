# Lab 12 – Deploying to Amazon ECS from the Pipeline

**Module:** DSO303 · **Environment:** Floci (local AWS emulator)

## Overview
Lab 11's pipeline stopped after building. This lab adds a third stage, **Deploy**, so the pipeline continues all the way to a running service. The build now produces a container image and pushes it to ECR. The deploy stage then updates the ECS service, which pulls the new image and replaces its tasks.

```
Before:  source ─► build ─► artifact   (stops)
After:   source ─► build ─► artifact ─► deploy
                    │                      │
              builds image,          updates ECS service,
              pushes to ECR          rolls tasks to new image
```

The application code itself doesn't change. This lab is about how the code gets to a running task.

## What I built / changed
| Resource | Purpose |
|---|---|
| `usms-enrolment` (ECR) | The first private container registry in the course |
| `Dockerfile` in `labs/lab-11-cicd/app/` | Packages the enrolment service |
| `usms-enrolment:3` task definition | New revision pointing at my image |
| `USMSCodeBuildBase` v2 | Adds ECR push permission, set as the default version |
| `USMSCodePipelineBase` v2 | Adds `ecs:UpdateService` and a second scoped `iam:PassRole` |
| Deploy stage | Third stage of `usms-enrolment-pipeline`, provider ECS |
| `imagedefinitions.json` | Written by the build and read by the deploy action |
| `templates/lab-12-appspec.yaml` | Blue/green spec, written and validated but not run |

## Main steps
1. Created the ECR repo and logged Docker in by passing the auth token on stdin.
2. Wrote the Dockerfile, then built, tagged and pushed the image by hand and confirmed it was in the registry.
3. Made a new task definition revision (describe → strip read-only fields → register) and deployed revision 3 by hand.
4. Published v2 of both pipeline policies, allowed the build to run Docker, and extended the buildspec to build the image and write `imagedefinitions.json`.
5. Added the Deploy stage using get → modify → update on the pipeline JSON, ran it end to end, and confirmed the service moved to the new image.
6. Ran a rollback drill on a bad release, wrote up blue/green with CodeDeploy on paper, then recorded outputs and committed.

## Key concepts
- **Tag vs digest.** A tag like `:latest` or `:v3` can be moved to point at a different image. A digest (`sha256:...`) is the exact image content and never changes. Deploying by digest guarantees you run exactly what was built.
- **Task definition revisions.** These can't be edited after creation. Each change registers a new revision, and the service is pointed at it.
- **Rolling update and circuit breaker.** ECS swaps tasks over gradually. The circuit breaker stops and rolls back a deployment whose new tasks keep failing.
- **IAM policy versions.** A managed policy is updated by creating a new version and setting it as default, keeping up to 5 versions. That makes rolling back permissions easy too.
- **Blue/green with CodeDeploy.** Runs the new version (green) next to the old one (blue) and shifts traffic across. Rollback is instant because blue is still running.

## Notes / limitations
The blue/green deployment was specified and validated only, not actually performed, because Floci doesn't support the CodeDeploy traffic shift. The rolling deploy and the rollback drill were done for real.