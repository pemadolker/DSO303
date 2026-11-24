# Lab 10 – Edge Functions with AWS Lambda

**Module:** DSO303 · **Environment:** Floci (local AWS emulator)

## Overview
This lab adds serverless functions to USMS in two places: at the **CloudFront edge** (Lambda@Edge), where they run on the request path before the origin is touched, and **regionally**, where a function reacts to events after they happen (an S3 upload).

A student requests a transcript such as `/transcripts/2026/stu-00417.json`. The viewer-request function normalises the URI and blocks requests with no auth header (403) so they never reach the bucket. On a cache miss, CloudFront fetches from S3 and the origin-response function adds the security headers S3 can't. Separately, any upload under `transcripts/` triggers the regional notifier.

## What I built
| Resource | Purpose |
|---|---|
| `usms-student-data` | S3 bucket used as the CloudFront origin |
| `usms-edge-viewer-request` | Lambda@Edge (Node.js): lowercases the URI and returns 403 if the auth header is missing |
| `usms-edge-origin-response` | Lambda@Edge (Node.js): adds security headers to origin responses |
| `usms-transcript-notifier` | Regional Lambda (Python) triggered by S3 `ObjectCreated` on `transcripts/` |
| Version 1 of each function + alias `live` on the notifier | Edge needs a fixed version; the alias gives triggers a stable target |
| `usms-transcript-cdn` | CloudFront distribution with both edge functions attached |
| `usms-lambda-exec-role` trust policy | Updated to trust both `lambda` and `edgelambda` |
| `scripts/utilities/usms-edge-simulate.sh` | Runs the edge chain end to end without CloudFront |

## Main steps
1. Created the origin bucket and updated the execution role so edge Lambda could assume it.
2. Wrote, packaged and deployed both edge functions, invoked them with real CloudFront event payloads, checked the logs, and published versions.
3. Checked both functions against the Lambda@Edge restrictions, attached them to a distribution, and tested the chain with the simulator script.
4. Built the notifier, gave it the alias `live`, added a resource policy scoped so only the bucket can invoke it, wired the S3 notification, and confirmed it ran.
5. Restarted Floci, checked everything was still there, saved IDs to `configs/lab-10.env`, and committed.

## Key concepts
- **Edge vs regional functions.** Edge functions sit on the request path and must be fast and small. Regional functions handle what happens afterwards (notifications, processing).
- **Why edge needs a version.** CloudFront copies the function out to edge locations, so it has to point at an immutable published version, not `$LATEST`.
- **Two kinds of policy.** The execution role (trust policy) controls what the function can do. The resource-based policy on the function controls who can invoke it, which here is S3 only.
- **Aliases.** Triggers point at `live` rather than a version number, so a new release is just repointing the alias, with no changes to the trigger.
- **CloudFront Functions vs Lambda@Edge.** CloudFront Functions are lighter and cheaper but only handle viewer events. Lambda@Edge is needed for origin events or anything heavier.

## Notes / limitations
Floci doesn't run a real CloudFront edge network, so I validated the distribution config and proved the edge chain with `usms-edge-simulate.sh` rather than through live CloudFront traffic.