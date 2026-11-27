#!/usr/bin/env bash
# Trace one release from source bytes to the running service, using only command output.
# Usage: usms-release-evidence.sh [release-tag]     Writes: outputs/lab-12-release-evidence.md
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
TAG="${1:-r7}"
OUT=outputs/lab-12-release-evidence.md
P=usms-enrolment-pipeline

sec() { printf '\n### %s\n\n```text\n' "$1"; }
end() { printf '```\n'; }

{
  printf '# Release evidence for %s\n\nGenerated %s by scripts/utilities/usms-release-evidence.sh.\n' "$TAG" "$(date -u +%FT%TZ)"

  sec "1. Source archive versions (S3 version IDs)"
  echo '$ aws s3api list-object-versions --bucket usms-pipeline-artifacts --prefix source/usms-enrolment-src.zip'
  aws s3api list-object-versions --bucket usms-pipeline-artifacts --prefix source/usms-enrolment-src.zip \
    --query 'Versions[].[VersionId,LastModified,IsLatest]' --output text
  end

  sec "2. Pipeline executions and the source revision each consumed"
  echo "$ aws codepipeline list-pipeline-executions --pipeline-name $P"
  aws codepipeline list-pipeline-executions --pipeline-name "$P" \
    --query 'pipelineExecutionSummaries[].[pipelineExecutionId,status,sourceRevisions[0].revisionId]' --output text
  end

  sec "3. Builds of usms-enrolment-build (newest first)"
  echo '$ aws codebuild list-builds-for-project --project-name usms-enrolment-build'
  aws codebuild list-builds-for-project --project-name usms-enrolment-build --query 'ids[0:5]' --output text | tr '\t' '\n'
  end

  sec "4. Image digest for tag $TAG: registry now, and as recorded at push time"
  echo "$ aws ecr describe-images --repository-name usms-enrolment --image-ids imageTag=$TAG"
  aws ecr describe-images --repository-name usms-enrolment --image-ids "imageTag=$TAG" \
    --query 'imageDetails[0].[imageDigest,imagePushedAt]' --output text
  echo "$ grep '^$TAG ' outputs/lab-12-image-digest.txt"
  grep "^$TAG " outputs/lab-12-image-digest.txt
  end

  sec "5. Task definition revisions and the image each names"
  echo '$ aws ecs list-task-definitions --family-prefix usms-enrolment  (+ describe each)'
  for a in $(aws ecs list-task-definitions --family-prefix usms-enrolment --query 'taskDefinitionArns' --output text); do
    printf '%s  ' "${a##*/}"
    aws ecs describe-task-definition --task-definition "$a" --query 'taskDefinition.containerDefinitions[0].image' --output text
  done
  end

  sec "6. The service's current task definition"
  echo '$ aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc'
  aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
    --query 'services[0].taskDefinition' --output text
  end
} > "$OUT"
echo "wrote $OUT"
