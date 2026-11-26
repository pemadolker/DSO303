# Lab 10 Notes: Edge Functions with AWS Lambda

Commands ran in one shell session so variables carried from step to step.

## Step 1-2: Environment
- floci-up, storage check, whoami. Sourced lab-01 to lab-09 env files.
- `USMS_ROLE_LAMBDA` is a plain name (`usms-lambda-exec-role`) in my lab-01.env, so `--role-name` works. `USMS_ROLE_EC2` is still an ARN, which matters in Lab 13.
- The handout's `cd ~/aws-floci-course` is wrong for me; my repo is `~/Desktop/Y4S1/DSO303/aws-floci-course` (`$COURSE_ROOT`).

## Step 4: Support probe
- Saved to `outputs/lab-10-support-probe.txt`. An earlier attempt (12 Nov) said `iam get-role` UNSUPPORTED; that was the old lab-01.env holding an ARN in `USMS_ROLE_LAMBDA`, the same problem I found in Lab 09. The CloudFront line decides Step 15's path.

## Step 5: The bucket
- `usms-student-data` created without `--create-bucket-configuration` (us-east-1 is the one region where `LocationConstraint` must be omitted).
- An IAM policy can name a resource that does not exist. `USMSStudentDataReadWrite` has been "granting access to nothing" since Lab 01. Floci still does not enforce it.

## Step 6: Trust policy
- Before: `lambda.amazonaws.com` only. After: `lambda.amazonaws.com` and `edgelambda.amazonaws.com`. `update-assume-role-policy` replaces the whole document, so both principals have to be in the file.

## Steps 7-11: Viewer-request
- Header values in a CloudFront event are arrays of `{key, value}`; that is why the code reads `headers['x-usms-student'][0].value`.
- The heredoc is quoted (`<< 'EOF'`) so the JavaScript template literal `${studentId.toLowerCase()}` is written literally, not expanded by bash. The verify script checks for it.
- Returning the request = continue. Returning an object with `status` = stop here. Allow: URI lowercased, header stamped. Deny (my "Your turn" file `templates/lab-10-viewer-request-denied.json`): 403 response object, no `uri`.
- `--log-type Tail` returns the last 4 KB of log base64-encoded; `openssl base64 -d -A` decodes it the same way on Linux and macOS.
- Published version 1. The ARN ends `:1`. That is the only shape CloudFront accepts.

## Steps 12-13: Origin-response
- Security headers at origin-response, not viewer-response: the result is cached, so the function runs once per cache miss instead of once per request.
- `cache-control: public, max-age=300, s-maxage=3600`: browsers keep it 5 minutes, the edge an hour.

## Step 14: Restrictions
- Setting environment variables on the viewer function succeeded. That is the trap: Lambda does not know the function is meant for the edge; CloudFront checks at association time. Removed them, then the eligibility report: no `NO` lines.

## Step 15: Distribution
- CallerReference uses `$(date +%s)` so it is unique, which is why the heredoc here is unquoted. Both `LambdaFunctionARN` values end in a version number. Path A reads them back from `get-distribution`; Path B validates the document with eleven structural checks. If a distribution already exists from an earlier run, reuse its id instead of creating a duplicate.

## Step 16: Simulator
- `usms-edge-simulate.sh` invokes viewer-request; if the result has `status` it stops (deny), otherwise it builds an origin-response event carrying the modified request and invokes origin-response. The allow trace has 3 stages and `x-usms-edge-chain` shows both functions ran.

## Steps 17-21: Notifier
- Python, 256 MB, 30 s, environment variables: none of that would be allowed at the edge, and none of it needs to be.
- `unquote_plus` because S3 URL-encodes keys in events.
- Alias `live` -> 1. Your turn: published version 2 (same code), moved `live` to 2 and back to 1; versions list kept $LATEST, 1, 2. Rollback is instant because nothing is deleted and no trigger changes.
- `add-permission` with `--source-arn arn:aws:s3:::usms-student-data` and `--source-account`. The assertion in Step 19 checks the condition really contains the bucket.
- Notification: `s3:ObjectCreated:*`, prefix `transcripts/`, suffix `.json`, target is the **alias ARN**.
- Filter your turn: `notes/ignore-me.json` is excluded by the prefix rule; `transcripts/evidence/ignore-me.txt` by the suffix rule. Neither produced a `USMS_NOTIFY` line, both are in the bucket.

## Step 22-23: Restart and env file
- Inventory before and after compared with `diff`; the edge chain still composes after the restart.
- `configs/lab-10.env`: 25 exports. Version ARNs come from the variables captured in Steps 11 and 13.

## Section 8
- `verify-lab-10.sh` (51 checks): PASS=50 FAIL=1. Several checks are static substitutes for enforcement Floci does not do: no env vars on edge functions, qualified ARNs, resource policy scoped to one bucket.
- The one FAIL is "no secret is tracked": `! git ls-files | grep -q "^outputs/"` fails on `outputs/.gitkeep`, which Lab 01's `.gitignore` tracks on purpose. False positive, left as written; Labs 11-13 use `! git ls-files outputs/ | grep -qv "^outputs/.gitkeep$"`.

## Problem: every Lambda invoke timed out (Step 9)
- `Task timed out after 5 seconds`, even after pulling `public.ecr.aws/lambda/nodejs:20`.
- Floci log: `DockerHostResolver ... using current network IP for Runtime API: 10.0.0.2` then `LAMBDA_RUNTIME Failed to get next invocation. No Response from endpoint`.
- Cause: Floci is on two networks (`floci-course_default` and the Lab 02 VPC network, 10.0.0.0/16). It handed Lambda containers its VPC address, unreachable from `floci-course_default`.
- Fix: new `docker-compose.override.yml` with `FLOCI_SERVICES_LAMBDA_DOCKER_NETWORK=floci-course_default` and `FLOCI_SERVICES_LAMBDA_DOCKER_HOST_OVERRIDE=floci`, then `./scripts/setup/floci-up.sh`. Timeout left at 5 s.
- `lab-10-cleanup.sh` written, `bash -n` clean, **not run**. Order matters: notification first, then permission, then functions, then bucket.

---

## Review questions

### 1. Moving the whole enrolment API to Lambda@Edge
The first argument is data. Enrolment writes to a database in one region. An edge function in Thimphu still has to reach that database in us-east-1, so the slow part of the request (the write) does not move; only the code moves, and now every edge location needs network access and credentials to the database. The second is the restrictions: viewer triggers have a 5 second limit and 128 MB, no environment variables and no VPC, and every deploy is a replication that takes minutes to roll out and minutes to roll back. An API that changes often and talks to private resources is the worst fit for that. The colleague would be right for a small, read-mostly part of the API whose answer can be computed from the request alone, or from data that is cached or replicated globally, for example a course catalogue served from a globally replicated table, or redirecting and validating requests before they reach the API.

### 2. CloudFront Functions versus Lambda@Edge
CloudFront Functions run a restricted JavaScript runtime (cloudfront-js-2.0) only at viewer-request and viewer-response, with sub-millisecond limits, no network calls and no body access, and they cost roughly a sixth of Lambda@Edge per request. Lambda@Edge runs Node.js or Python at all four trigger points, can make network calls, can read the body at request triggers, and runs for up to 5 s (viewer) or 30 s (origin). Adding `/index.html` to a URI is a pure string change on every request, so a CloudFront Function. Checking a JWT signature needs a crypto operation on every request; CloudFront Functions support the crypto module for HMAC, so an HS256 token fits there, while RS256 with a key fetched from somewhere needs Lambda@Edge. Fetching a per-user redirect from DynamoDB needs a network call, so Lambda@Edge, ideally at origin-request so it only runs on a cache miss.

### 3. origin-response versus viewer-response for headers
At origin-response the function runs when the origin answers, before the object goes into the cache. The headers are stored with the object, so the function runs once per cache miss and every later hit is served with the headers already there. At viewer-response it runs on every response, hit or miss, which for a popular transcript is thousands of times more invocations for identical output. A requirement that would force viewer-response is anything that depends on the viewer and must not be cached: for example a header that includes the requesting student's id, or a per-request nonce for a Content-Security-Policy. Caching those would show one student's value to the next student.

### 4. Execution role versus resource policy on the notifier
They are about different callers. The resource policy is checked when someone calls `lambda:Invoke` on the function: it lets the S3 service invoke `usms-transcript-notifier:live`, but only for events from `usms-student-data` in this account. The execution role is what the function itself becomes when it runs: it lets the function's code call `s3:GetObject` on the bucket and write its logs. If I delete the resource policy, S3 is no longer allowed to invoke the function; on real AWS the notification silently stops (no error, no log, because the function never ran). If I delete the `s3:GetObject` grant from the role, the function still runs on every upload but its `head_object` call gets AccessDenied, so `readable` becomes false. One is the door in, the other is what you can touch once inside.

### 5. --source-arn and --source-account
Without them the statement says "the S3 service may invoke this function". S3 is a shared service, so any bucket in any account whose owner knows my function ARN could add a notification that targets it, and S3 would invoke my function with their events. The function would then process fake transcript events and spend my money. With `--source-arn` the invocation is only allowed when S3 is acting for `usms-student-data`, and with `--source-account` only when that bucket belongs to account 000000000000 (bucket names can be deleted and re-created by someone else, so the ARN alone is not enough). This is the confused deputy problem again, and the Lab 09 equivalent is the `aws:SourceArn` and `aws:SourceAccount` conditions I added to the ECS task role's trust policy. They are the same idea: a service principal acts for many customers, so the policy has to say on whose behalf.

### 6. Environment variables accepted on an edge function
Lambda validated the call against Lambda's rules, and environment variables are fine for a Lambda function. Nothing in the function says "this is for the edge". The edge rules are checked by CloudFront when a distribution is created or updated with an association to that version, and that can be much later and by a different person; on real AWS the whole distribution update is then rejected with an error about the Lambda function, not the distribution. So edge configuration has to be checked on its own, before association, by reading it: that is what the eligibility report and the verify script do. It is the same rule as the rest of the course: a command appearing to succeed only means that service accepted it, not that it does what I meant, so the check has to be a read-back against the requirement.
