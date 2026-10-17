# Lab 01 Notes - IAM

<!-- TODO: answer every section in your own words (prose, no pasted command output), then delete this comment. -->

## Step 7 - storage modes

If `--persist` mounts a directory correctly, why is the directory almost empty in memory mode? (two sentences)

## Step 32 - policy simulator prediction

My prediction for `usms-audit-01`, written before running anything:
- `ec2:CreateVpc`:
- `ec2:DescribeVpcs`:

What the simulator (or the policy JSON) actually said, and whether I was right:

## Attached vs inline policies

## Exercise 3 - should the analytics role use `sts:ExternalId`?

## Exercise 4 - user, group, or role? (one paragraph)

## Exercise 4 - three ways the policy could still be abused, and how to close each

## Exercise 5 - updating verify-lab-01.sh to v3

## Review questions

### 1. Trust vs permissions

### 2. Explicit vs implicit deny

### 3. Roles over keys

### 4. The S3 ARN trap

### 5. The Floci illusion

### 6. The persistence trap

### 7. Configuration as evidence
