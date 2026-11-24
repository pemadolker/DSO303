# Lab 11 – CI/CD Pipeline with AWS CodePipeline and CodeBuild

**Module:** DSO303 · **Environment:** Floci (local AWS emulator)

## Overview
This lab sets up continuous integration for the USMS enrolment service. The placeholder nginx image from Lab 04 is replaced with a real source tree (a static portal, a health endpoint, a validated config and a `buildspec.yml`), and a two-stage pipeline builds it automatically.

```
S3 (source zip) ──► Source stage ──► Build stage (CodeBuild) ──► build artifact back in S3
```

I used S3 as the source instead of CodeCommit because CodeCommit has been closed to new customers since July 2024. It also shows clearly how artifacts move between stages.

## What I built
| Resource | Purpose |
|---|---|
| `usms-pipeline-artifacts` | Versioned S3 bucket holding both the source and the pipeline artifacts |
| `source/usms-enrolment-src.zip` | The versioned source archive the pipeline pulls |
| `usms-codebuild-role` + `USMSCodeBuildBase` | CodeBuild's own identity and permissions |
| `usms-codepipeline-role` + `USMSCodePipelineBase` | CodePipeline's identity, including a conditioned `iam:PassRole` |
| `usms-enrolment-build` | The CodeBuild project |
| `usms-enrolment-pipeline` | Two-stage pipeline: Source → Build |
| `labs/lab-11-cicd/app/` | Enrolment service source tree and `buildspec.yml` |
| `scripts/utilities/usms-buildspec-run.sh` | Runs a buildspec locally, phase by phase |

## Main steps
1. Created the artifact bucket, turned on versioning, and proved it worked by uploading, changing and reading back an object.
2. Wrote the enrolment service source and its `buildspec.yml`.
3. Created separate, scoped service roles for CodeBuild and CodePipeline.
4. Created the CodeBuild project, uploaded the source zip, ran a standalone build and read its output and logs. I also ran the same buildspec with the local runner.
5. Wrote the pipeline definition, created the pipeline, ran it end to end, and checked the output artifact's contents to prove it actually used my source.
6. Broke the build on purpose, worked out the cause from the logs, fixed it, then recorded outputs and committed.

## Key concepts
- **buildspec phases.** `install → pre_build → build → post_build`, then `artifacts` lists which files get handed to the next stage.
- **Stages and actions.** A pipeline is a set of stages, and each stage contains actions. Stages pass work to each other only through artifacts stored in S3.
- **Separate build and deploy identities.** CodeBuild and CodePipeline each get their own role, so neither has more permissions than its job needs.
- **`iam:PassRole` and the confused deputy problem.** Passing a role to a service is restricted with a condition, so the pipeline can only hand its roles to the intended service and can't be used to escalate privileges.
- **S3 versioning.** Each source upload gets its own version ID, which makes builds traceable and repeatable.

## Notes / limitations
CodeBuild/CodePipeline support in Floci varies by build. I probed support first, and used the local buildspec runner to prove the build logic where the emulator fell short.