# Lab 10 Exercise 4 - Transcript delivery design

The registrar's requirements: no transcript without a valid session token, and the check must not cost an origin request; a corrected transcript must stop being served within five minutes, without re-fetching unchanged ones every five minutes; a report of refused requests by faculty; and survival if one edge location cannot reach the origin.

## 1. Where each piece of logic runs

| Logic | Where | Why |
|---|---|---|
| Normalise the URI (lowercase, strip double slashes) | CloudFront Function, viewer-request | Pure string work on every request. CloudFront Functions are built for this: sub-millisecond, cheapest per request, and they run before the cache so the cache key is clean. |
| Validate the session token | CloudFront Function, viewer-request, if the token is an HMAC-signed value (HS256 JWT or a signed cookie) | The check has to run before the cache to protect cached transcripts, and must not reach the origin. CloudFront Functions can verify an HMAC with the built-in crypto module. If the portal issues RS256 tokens, this moves to Lambda@Edge viewer-request, because public-key verification and key handling are a better fit there. I would verify which one the portal uses before choosing. |
| Security headers and cache policy | Lambda@Edge origin-response (as built in this lab) | Runs once per cache miss and the result is cached. |
| Refusal counting | Not a function. Derived from logs (section 4). | Counting is not on the request path. |
| Transcript upload notification | Regional Lambda (`usms-transcript-notifier`) | Happens after an upload, nothing to do with viewers. |
| Invalidation on correction | Regional Lambda triggered by the corrected upload | Calls `CreateInvalidation` for that one path (section 3). |

## 2. The cache key

The cache key is the normalised URI only. The token is validated at viewer-request and the request is either refused or allowed; once allowed, every student who is permitted to see that transcript gets the same object, so the token must **not** be in the cache key (otherwise every session would be its own cache entry and the hit rate would collapse to zero). In this lab's configuration the `x-usms-student` header is forwarded and therefore part of the key; I would change that once the check is a real token check, and keep the authorisation decision ("may this student see this file") in the viewer-request function, comparing the student in the token with the student in the path. No cookies and no query strings in the key either.

What I would deliberately leave out: the token, cookies, `User-Agent`, `Accept-Encoding` beyond what compression needs, and any query string.

## 3. Five-minute corrections without five-minute re-fetches

There is more than one answer. The one I would choose:

- Long edge TTL (`s-maxage=86400`) so unchanged transcripts are not re-fetched, and a short browser TTL (`max-age=300`) so a student's browser checks back within five minutes.
- When a corrected transcript is uploaded, the regional function triggered by that upload calls `CreateInvalidation` for exactly that path. Invalidations usually complete in well under five minutes, and the first 1,000 paths a month are free; corrections are rare, so cost is negligible.

Alternative: keep `s-maxage=300` and rely on conditional requests (`If-None-Match` with the ETag). The edge still asks the origin every five minutes, but an unchanged object comes back as a small `304` instead of the full file. That meets "do not re-fetch" only loosely, which is why I prefer invalidation.

What I would measure first: how often transcripts are corrected and how many distinct transcripts are requested per day. If corrections were very frequent, invalidation volume and cost would change my mind towards the short-TTL plus 304 option.

## 4. The refusal report by faculty

Edge function logs are written to CloudWatch Logs in the region nearest the viewer, so they are spread across regions and hard to report on. Better sources:

- CloudFront **standard logs** or **real-time logs** for the distribution: every request with its status code and URI, delivered to one place (S3 or Kinesis). A refused request is a 403 with a `/transcripts/<faculty>/...` path, so faculty comes from the path. Athena over the S3 logs answers "refusals by faculty" with one query.
- If the token check is a Lambda@Edge function, it can also print a structured line per refusal; a CloudWatch Logs Insights query can run across several regions, but that is the second choice.

## 5. Surviving an edge location that cannot reach the origin

CloudFront **origin failover**: an origin group with `usms-student-data` as primary and a replica bucket in a second region (S3 Cross-Region Replication) as secondary, failing over on 5xx and timeouts. Cached objects keep being served while the origin is unreachable if the cache policy allows stale content (`stale-if-error`). Note this survives the origin being unreachable; one edge location being down is already handled by CloudFront routing viewers to another location.

## 6. Where an edge function is the wrong tool

The faculty refusal report: it is not on the request path at all, and computing it inside an edge function would mean either a network call per refused request or counters scattered across regions. Logs plus Athena is the right tool. Writing anything to a database from the edge is also the wrong tool for the same reason.

## What I would verify before building

- Which token format the portal issues (HS256 or RS256), which decides CloudFront Function versus Lambda@Edge for the check.
- Real request and correction volumes, which decide between invalidation and short TTLs.
- That `stale-if-error` behaves as expected for this distribution, with a test where the origin is made unavailable.
