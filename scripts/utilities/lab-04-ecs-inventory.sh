#!/usr/bin/env bash

set -uo pipefail

# Deliberately do not use set -e.
# The inventory must continue when an individual service has missing optional
# data, such as networkConfiguration, instead of stopping the entire report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/configs/lab-04.env"

OUTPUT_FILE="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"

mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "ECS inventory: $USMS_ECS_CLUSTER"
echo

# Discover every service dynamically. No service name is hard-coded.
SERVICE_ARNS=$(aws ecs list-services \
  --cluster "$USMS_ECS_CLUSTER" \
  --query 'serviceArns[]' \
  --output text)

# Start the JSON array.
printf '[\n' > "$OUTPUT_FILE"

first_json=true

for SERVICE_ARN in $SERVICE_ARNS; do

    SERVICE_JSON=$(aws ecs describe-services \
      --cluster "$USMS_ECS_CLUSTER" \
      --services "$SERVICE_ARN" \
      --query 'services[0]' \
      --output json)

    SERVICE_NAME=$(printf '%s' "$SERVICE_JSON" |
      jq -r '.serviceName // "UNKNOWN"')

    DESIRED=$(printf '%s' "$SERVICE_JSON" |
      jq -r '.desiredCount // 0')

    RUNNING=$(printf '%s' "$SERVICE_JSON" |
      jq -r '.runningCount // 0')

    TASKDEF=$(printf '%s' "$SERVICE_JSON" |
      jq -r '.taskDefinition // "UNKNOWN"' |
      awk -F/ '{print $NF}')

    # Get the task definition used by the service.
    TASKDEF_JSON=$(aws ecs describe-task-definition \
      --task-definition "$TASKDEF" \
      --query 'taskDefinition' \
      --output json)

    EXEC_ROLE=$(printf '%s' "$TASKDEF_JSON" |
      jq -r '.executionRoleArn // ""')

    TASK_ROLE=$(printf '%s' "$TASKDEF_JSON" |
      jq -r '.taskRoleArn // ""')

    if [ "$EXEC_ROLE" = "$TASK_ROLE" ]; then
        ROLES="SAME"
    else
        ROLES="SEPARATE"
    fi

    # networkConfiguration may not exist for an EC2 launch-type service.
    PUBLIC_IP=$(printf '%s' "$SERVICE_JSON" |
      jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "N/A"')

    case "$PUBLIC_IP" in
        ENABLED)
            PUBLICIP_VERDICT="RISK"
            ;;
        DISABLED)
            PUBLICIP_VERDICT="OK"
            ;;
        *)
            PUBLICIP_VERDICT="N/A"
            ;;
    esac

    printf "%-22s desired=%-2s running=%-2s taskdef=%-22s roles=%-8s publicip=%s\n" \
      "$SERVICE_NAME" \
      "$DESIRED" \
      "$RUNNING" \
      "$TASKDEF" \
      "$ROLES" \
      "$PUBLICIP_VERDICT"

    # Append the same information to the JSON report.
    if [ "$first_json" = true ]; then
        first_json=false
    else
        printf ',\n' >> "$OUTPUT_FILE"
    fi

    jq -n \
      --arg service "$SERVICE_NAME" \
      --argjson desired "$DESIRED" \
      --argjson running "$RUNNING" \
      --arg taskdef "$TASKDEF" \
      --arg roles "$ROLES" \
      --arg publicip "$PUBLICIP_VERDICT" \
      '{
        service: $service,
        desired: $desired,
        running: $running,
        taskdef: $taskdef,
        roles: $roles,
        publicip: $publicip
      }' >> "$OUTPUT_FILE"

done

printf '\n]\n' >> "$OUTPUT_FILE"

echo
echo "JSON report: $OUTPUT_FILE"
