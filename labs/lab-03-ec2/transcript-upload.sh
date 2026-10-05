#!/usr/bin/env bash
# Runs on usms-web-01. No access keys anywhere: credentials come from the
# instance profile via the metadata service.
set -euo pipefail
if [ $# -ne 2 ]; then
  echo "usage: $0 <student-id> <file-path>" >&2
  exit 2
fi
STUDENT_ID="$1"; FILE="$2"
[ -f "$FILE" ] || { echo "error: file not found: $FILE" >&2; exit 1; }
aws s3 cp "$FILE" "s3://usms-student-data/transcripts/${STUDENT_ID}/$(basename "$FILE")"