# AWS Practical Laboratory 10 Report

**Student Name:** Pema Dolker 
**Module:** DSO303   
**Practical:** Lab 10 - Edge Functions with AWS Lambda   
**Environment:** Floci (local AWS API emulator, Docker Compose, hybrid storage), account 000000000000, us-east-1

**Support path:** CloudFront probe gave Path A (6 of 6 probes SUPPORTED). Lambda, S3 and CloudWatch Logs are emulated; no emulator runs Lambda@Edge, so the edge chain is proven with `usms-edge-simulate.sh`.

Step notes and the six review questions are in `notes/lab-10-notes.md`, the exercises are in `labs/lab-10-lambda-edge/exercises.md`, and the Exercise 4 design is in `notes/lab-10-edge-design.md`.

> Labels used below:
> **Observed** = I ran it and saw it.
> **Floci limitation** = behaved differently from real AWS.
> **Conceptual** = only possible on real AWS, so I explained it instead.

## 1. Aim / Objective

The aim of this practical is to add serverless functions to USMS in the two places they belong. At the edge, two Lambda@Edge functions guard and decorate transcript downloads on the CloudFront request path. In the region, a normal Lambda function reacts to transcript uploads after they happen. On the way I created `usms-student-data`, the bucket that Lab 01's policies have named since the first day, published versions and an alias, wrote the resource-based policy that lets S3 call the notifier, and checked both edge functions against the Lambda@Edge restrictions.

## 2. Introduction

AWS Lambda runs a function when an event arrives and charges only for the time it runs. Lambda@Edge is the same idea moved into CloudFront: CloudFront copies a published version of the function to its edge locations and runs it at one of four trigger points on the request path (viewer-request, origin-request, origin-response, viewer-response). The order matters. Viewer-request runs before the cache is checked, so it can refuse a request without the origin ever being touched. Origin-response runs after the origin answers but before the object is cached, so anything it adds is cached once and served to everyone.

The main ideas I used in this lab:

- **Edge versus regional functions** - edge functions are on the request path and must be small and fast; regional functions handle what happens afterwards.
- **Versions and aliases** - a version freezes code and configuration; an alias is a movable name for a version.
- **Why edge needs a version** - CloudFront replicates one exact version, so it only accepts a version-qualified ARN, never `$LATEST` or an alias.
- **Execution role versus resource policy** - the role says what the function may do; the resource policy says who may invoke it.
- **Confused deputy** - `--source-arn` and `--source-account` stop another bucket from using my permission to invoke my function.
- **Edge restrictions** - no environment variables, no VPC, Node.js or Python only, 128 MB and 5 s at the viewer triggers.

## 3. Use Case

- Refusing an unauthenticated transcript request at the edge, without paying for an origin fetch.
- Adding security headers (HSTS, nosniff, frame denial) to objects served from a bucket that cannot add them itself.
- Normalising URIs so `/STU-00417.json` and `/stu-00417.json` are one cache entry, not two.
- Notifying the results service whenever a new transcript lands in the bucket.
- Rolling a regional function forward and back by moving an alias, without touching any trigger.

## 4. System Architecture / Design

![Lab 10 architecture](../../screenshots/lab10/lab-10-architecture.png)

## 5. Implementation Procedure

1. **Steps 1 to 4** - started Floci, sourced nine env files, created the function directories and probed what this build supports.
2. **Step 5** - created and tagged `usms-student-data`; the ARNs in `USMSStudentDataReadWrite` now resolve to a real bucket.
3. **Step 6** - read `usms-lambda-exec-role` back and added `edgelambda.amazonaws.com` to its trust policy.
4. **Steps 7 to 11** - wrote the viewer-request handler, zipped it, created it, invoked it with a real CloudFront event (allow and deny), read its logs and published version 1.
5. **Steps 12 and 13** - wrote, created, invoked and published the origin-response function.
6. **Step 14** - deliberately set environment variables on an edge function (the call succeeded), removed them, and ran an eligibility check on both functions.
7. **Step 15** - wrote the distribution configuration with two version-qualified associations and created or validated it.
8. **Step 16** - wrote `usms-edge-simulate.sh` and ran the chain in CloudFront's order for both the allow and the deny case.
9. **Steps 17 to 21** - built the notifier, published it, gave it the alias `live`, moved the alias forward and back, added a scoped resource policy, wired the bucket notification, uploaded objects and proved the notifier ran.
10. **Steps 22 and 23** - restarted Floci, compared before and after, and wrote `configs/lab-10.env`.
11. **Section 8, Exercises, Step 24** - built `verify-lab-10.sh` and the cleanup script (not run), did Exercises 1 to 5, re-verified and committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Steps 1 to 4 - environment and support probe**

![Step 1](../../screenshots/lab10/step1.png)
![Step 2](../../screenshots/lab10/step2.png)
![Step 3](../../screenshots/lab10/step3.png)
![Step 4](../../screenshots/lab10/step4.png)

**Observed:** storage check and identity fine, nine env files sourced. The probe recorded 6 of 6 probes SUPPORTED, so Step 15 took Path A.

**Step 5 - the origin bucket**

![Step 5](../../screenshots/lab10/step5.png)
![Step 5 verify](../../screenshots/lab10/step5-2.png)

**Observed:** `head-bucket` exits 0 for the first time in the course, three tags, and `USMSStudentDataReadWrite` names `arn:aws:s3:::usms-student-data` and `.../*`. The policy was never wrong, it was waiting for the bucket. **Floci limitation:** the permission is still not enforced.

**Step 6 - the edge principal**

![Step 6 before](../../screenshots/lab10/step6.png)
![Step 6 after](../../screenshots/lab10/step6-2.png)

**Observed:** the trust policy went from one principal to two, and `edgelambda.amazonaws.com` is present. Without it CloudFront cannot replicate the function on real AWS.

**Steps 7 to 11 - the viewer-request function**

![Step 7](../../screenshots/lab10/step7.png)
![Step 8](../../screenshots/lab10/step8.png)
![Step 9 allow](../../screenshots/lab10/step9.png)
![Step 9 deny (your turn)](../../screenshots/lab10/step9-2.png)
![Step 10 logs](../../screenshots/lab10/step10.png)
![Step 11 version](../../screenshots/lab10/step11.png)

**Observed:** with the header present the function returned the **request** with the URI lowercased and `x-usms-edge: viewer-request-allow;student=stu-00417`. Without the header it returned a **response** object with status `403` and no `uri` key, which is how a viewer-request function stops a request. Status 200 with no `FunctionError` in both cases: the function made a decision, it did not fail. Version 1 was published and its ARN ends in a number.

**Steps 12 and 13 - the origin-response function**

![Step 12](../../screenshots/lab10/step12.png)
![Step 13](../../screenshots/lab10/step13.png)

**Observed:** the response came back with the four security headers, `cache-control: public, max-age=300, s-maxage=3600` and `x-usms-edge-chain` ending `;origin-response`. Version 1 published.

**Step 14 - the edge restrictions**

![Step 14 the trap](../../screenshots/lab10/step14.png)
![Step 14 eligibility](../../screenshots/lab10/step14-2.png)

**Observed:** `update-function-configuration` accepted environment variables on an edge function without complaint. **Conceptual:** on real AWS the mistake is only caught later, when CloudFront rejects the distribution update. After removing them, the eligibility report had no `NO` lines for either function.

**Step 15 - the distribution**

![Step 15 config](../../screenshots/lab10/step15.png)
![Step 15 result](../../screenshots/lab10/step15-2.png)

**Observed:** Path A. Distribution: ENAZOFOL6V1Q1N. Both associations are version-qualified ARNs and `IncludeBody` is only on the request trigger. **Floci limitation:** associations are stored without the validation real CloudFront does, and nothing runs at an edge location.

**Step 16 - the chain without CloudFront**

![Step 16](../../screenshots/lab10/step16.png)
![Step 16 trace](../../screenshots/lab10/step16-2.png)

**Observed:** the allow trace has three stages (viewer-request, origin, origin-response) and the final headers include `x-usms-edge-chain: viewer-request-allow;student=stu-00417;origin-response`, which proves the two functions compose. The deny trace stops after one stage with 403.

**Steps 17 to 21 - the regional notifier**

![Step 17](../../screenshots/lab10/step17.png)
![Step 18](../../screenshots/lab10/step18.png)
![Step 18 alias roll (your turn)](../../screenshots/lab10/step18-2.png)
![Step 19 resource policy](../../screenshots/lab10/step19.png)
![Step 20 notification](../../screenshots/lab10/step20.png)
![Step 21 logs](../../screenshots/lab10/step21.png)
![Step 21 direct invoke](../../screenshots/lab10/step21-2.png)
![Step 21 filter (your turn)](../../screenshots/lab10/step21-3.png)

**Observed:** the notifier runs on python3.12 with environment variables (legal here, the contrast with Step 14 is the point). `live` pointed at 1, moved to 2 and back to 1, and no version was deleted. The resource policy names `s3.amazonaws.com` with a source-ARN condition on this bucket and a source-account condition. Did the upload invoke the notifier by itself? yes - the S3 upload invoked the notifier and a USMS_NOTIFY line is in its log group. The direct invocation through `live` with a real S3 event shape printed a `USMS_NOTIFY` line. The two uploads with the wrong prefix (`notes/ignore-me.json`) and the wrong suffix (`.txt`) produced no new `USMS_NOTIFY` line, while `list-objects-v2` shows they were stored. **Floci limitation:** the resource policy is stored and returned, never checked.

**Steps 22 and 23 - restart and env file**

![Step 22](../../screenshots/lab10/step22.png)
![Step 22 after restart](../../screenshots/lab10/step22-2.png)
![Step 22 chain after restart](../../screenshots/lab10/step22-3.png)
![Step 23](../../screenshots/lab10/step23.png)

**Observed:** pre- and post-restart inventories were IDENTICAL, and the edge chain still composed. `configs/lab-10.env` has 25 exports and no empty values.

**Section 8 and Step 24 - verification, cleanup script, commit**

![Verification](../../screenshots/lab10/section8-verify.png)
![Cleanup script](../../screenshots/lab10/section8-cleanup.png)
![Verification after the exercises](../../screenshots/lab10/step24-verify.png)
![Commit](../../screenshots/lab10/step24.png)

**Observed:** `verify-lab-10.sh` gave PASS=50 FAIL=1. After the exercises: PASS=50  FAIL=1. The one failure is **"no secret is tracked"**, and it is a false positive. The check is `! git ls-files | grep -q "^outputs/"`, so it fails if *anything* under `outputs/` is tracked. The only tracked file there is `outputs/.gitkeep`, which my Lab 01 `.gitignore` keeps on purpose (`outputs/*` then `!outputs/.gitkeep`) so the folder exists in a fresh clone, and which Step 24 itself says `git ls-files outputs/` should list. Every check about the lab's actual resources passed. I left the script as the handout wrote it and recorded the reason here; for Labs 11 to 13 I changed the same check to `! git ls-files outputs/ | grep -qv "^outputs/.gitkeep$"`, which still fails on any real file under `outputs/`. The cleanup script is written and syntax checked but not run, and no `.zip` is tracked.

### 6.2 AWS Management Console Verification

Floci has no web console, so there is no console screenshot for this lab. The `get`, `list` and `describe` output in 6.1 is the verification.

## 7. Analysis and Discussion

The objectives were achieved. Both edge functions behave correctly when given real CloudFront events, they are version 1, eligible for the edge, and they compose in CloudFront's order. The notifier has an alias and a resource policy scoped to one bucket in one account, and every artefact survived a restart.

What this lab showed most clearly is the difference between a command succeeding and a configuration being valid. Setting environment variables on an edge function succeeded; on real AWS it would only fail later, at the distribution update, with an error about a different resource. The same is true of the S3 permission: Floci fires the notification whether or not the resource policy exists, so a working notification here proves nothing about the permission. In both cases the evidence has to come from reading the configuration (the eligibility report, the `get-policy` assertion), not from the absence of an error.

Separating observed from recorded: I **observed** functions created and invoked, requests modified and refused, responses modified, the chain composing, versions, the alias moving, the resource policy, the bucket and its notification filter, and persistence. I only **recorded** the two-principal trust rule, the distribution associations, the qualified-ARN rule, the no-environment-variables rule and the memory and timeout caps. Latency, caching, replication and cost were not available and are not claimed.

Problems I ran into and how I handled them:

- **Lambda invocations timed out after 5 seconds.** The first invoke in Step 9 returned `Task timed out after 5 seconds`. Floci's log showed why: `DockerHostResolver ... using current network IP for Runtime API: 10.0.0.2`, then `LAMBDA_RUNTIME Failed to get next invocation. No Response from endpoint`. The Floci container is attached to two Docker networks, the normal `floci-course_default` and the network for the Lab 02 VPC (`10.0.0.0/16`). Floci auto-detected its VPC address and told the Lambda container to call back on `10.0.0.2`, which the container (on `floci-course_default`) cannot reach, so the runtime never received the event and the 5 s timeout ran out. `docker events` confirmed the container was created, started and killed without ever getting work. I fixed it without touching `docker-compose.yml`, in a new `docker-compose.override.yml` that Compose merges automatically: `FLOCI_SERVICES_LAMBDA_DOCKER_NETWORK=floci-course_default` and `FLOCI_SERVICES_LAMBDA_DOCKER_HOST_OVERRIDE=floci` (Docker's DNS resolves the container name on the shared network). After restarting Floci the same invoke returned the normalised request. I did not raise the timeout: 5 s is the viewer-trigger limit this lab is testing, and raising it would only have hidden the cause.
- **A verify check that cannot pass.** See Section 8: "no secret is tracked" fails on `outputs/.gitkeep`, a file the course deliberately tracks.
- **The handout path.** The handout assumes `~/aws-floci-course`; my repository is under `~/Desktop/Y4S1/DSO303/`, so every `cd` uses `$COURSE_ROOT`.
- **Re-runs.** `create-function` fails if the function already exists and leaves the ARN variable empty, which then breaks every later step. I fell back to `update-function-code` and read the ARN back with `get-function-configuration`.
- **Python bytecode.** `py_compile` leaves a `__pycache__` folder in the notifier directory; it is removed so it is not committed with the source.

## 8. Reflection

**What I learned.** I had used Lambda before but never thought of where a function runs as a design decision. The trigger point decides cost (viewer triggers run on every request, origin triggers only on cache misses) and what the function can see. The rule that the edge needs a version, not an alias, finally made sense once I thought of it as replication: CloudFront copies bytes to hundreds of places and needs to know exactly which bytes.

**Challenges.** Keeping track of which policy does what. The execution role and the resource policy both look like "permissions for the function", but they answer opposite questions. Writing both out for the notifier (who it can call, who can call it) helped.

**Real world use.** On a real account I would put the auth check in a CloudFront Function rather than Lambda@Edge if it only needs headers, because it is cheaper and faster, and keep Lambda@Edge for origin-side work. I would also use Origin Access Control so the bucket only answers CloudFront.

**What I want to explore more.** Signed URLs and signed cookies for transcripts, and how edge logs in many regions are pulled together for a report.

## 9. Conclusion

The objectives were achieved. USMS now has its origin bucket, two Lambda@Edge functions that are version-qualified and edge-eligible, a distribution configuration that associates them, and a regional notifier on an alias with a resource policy limited to one bucket. The chain was proven end to end with the simulator, the alias rolled forward and back, the filter excluded the wrong prefix and suffix, and everything survived a restart.

The key ideas I am taking from this lab: the trigger point decides what an edge function can do and what it costs; a version freezes code and configuration while an alias only names it; the execution role and the resource policy answer different questions; and a command that succeeds is not proof that the configuration is valid.

## 10. Appendix

- Notes and the six review questions: `notes/lab-10-notes.md`
- Exercises 1 to 5: `labs/lab-10-lambda-edge/exercises.md`; design document: `notes/lab-10-edge-design.md`
- Function source: `labs/lab-10-lambda-edge/edge-viewer-request/index.mjs`, `edge-origin-response/index.mjs`, `transcript-notifier/notifier.py`
- Policies: `policies/trust-lambda-edge.json`, `policies/usms-edge-basic-policy.json` (Exercise 2)
- Templates: `templates/lab-10-*.json`
- Scripts: `scripts/utilities/usms-edge-simulate.sh`, `usms-edge-report.sh` (Exercise 3), `verify-lab-10.sh`, `scripts/cleanup/lab-10-cleanup.sh` (not run)
- Floci fix: `docker-compose.override.yml` (Lambda containers' network and Runtime API host)
- Recorded names and ARNs: `configs/lab-10.env`
- Screenshots: `screenshots/lab10/`
- Kept locally, git-ignored: the zips, invoke outputs, edge trace, function inventory, restart files and `outputs/lab-10-s3-readiness.txt`
