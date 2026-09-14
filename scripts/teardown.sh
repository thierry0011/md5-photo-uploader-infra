#!/usr/bin/env bash
# Deletes the root stack (cascades all 9 nested stacks) then purges the Retain/Snapshot resources CFN leaves behind. Re-run-safe.
#
# Does NOT touch bootstrap.yaml's or templates/ecr.yaml's stacks - both are Git-sync-managed and meant to survive teardown.
#
# Usage: AWS_PROFILE=admin ./teardown.sh [--yes] [--delete-snapshot] [--schedule-key-deletion-days=N]
set -euo pipefail

REGION="us-east-1"
PROJECT="photo-gallery"
ENV="dev"
ACCOUNT_ID="711387109786"
PROFILE="${AWS_PROFILE:-admin}"
ROOT_STACK="${PROJECT}-${ENV}-root"

IMAGES_BUCKET="${PROJECT}-${ENV}-images-${ACCOUNT_ID}"
ACCESS_LOGS_BUCKET="${PROJECT}-${ENV}-access-logs-${ACCOUNT_ID}"
PIPELINE_ARTIFACT_BUCKET="${PROJECT}-${ENV}-pipeline-artifacts-${ACCOUNT_ID}"
DB_SECRET="${PROJECT}-${ENV}-db-credentials"
KMS_ALIAS="alias/${PROJECT}-${ENV}"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

DELETE_SNAPSHOT=false
SCHEDULE_KEY_DAYS=""
SKIP_CONFIRM=false

for arg in "$@"; do
  case "$arg" in
    --yes) SKIP_CONFIRM=true ;;
    --delete-snapshot) DELETE_SNAPSHOT=true ;;
    --schedule-key-deletion-days=*) SCHEDULE_KEY_DAYS="${arg#*=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "About to tear down: $ROOT_STACK (region $REGION, account $ACCOUNT_ID, profile $PROFILE)"
if [ "$SKIP_CONFIRM" != true ]; then
  read -rp "Type the stack name to confirm: " CONFIRM
  [ "$CONFIRM" = "$ROOT_STACK" ] || { echo "Aborted - input didn't match."; exit 1; }
fi

empty_bucket_all_versions() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "    $bucket doesn't exist, skipping"
    return
  fi
  local vcount
  vcount=$(aws s3api list-object-versions --bucket "$bucket" --query 'length(Versions || `[]`)' --output text)
  if [ "$vcount" != "0" ] && [ "$vcount" != "None" ]; then
    aws s3api list-object-versions --bucket "$bucket" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json > /tmp/teardown-versions.json
    aws s3api delete-objects --bucket "$bucket" --delete file:///tmp/teardown-versions.json >/dev/null
  fi
  local mcount
  mcount=$(aws s3api list-object-versions --bucket "$bucket" --query 'length(DeleteMarkers || `[]`)' --output text)
  if [ "$mcount" != "0" ] && [ "$mcount" != "None" ]; then
    aws s3api list-object-versions --bucket "$bucket" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json > /tmp/teardown-markers.json
    aws s3api delete-objects --bucket "$bucket" --delete file:///tmp/teardown-markers.json >/dev/null
  fi
}

# --- 1. Empty the pipeline artifact bucket -------------------------------
# Versioned and non-empty would make CicdPipelineStack (and the root stack) fail deletion
echo "==> Emptying $PIPELINE_ARTIFACT_BUCKET so stack deletion doesn't stall on it..."
empty_bucket_all_versions "$PIPELINE_ARTIFACT_BUCKET"

# No ECR-emptying step here on purpose: the repo now lives in standalone templates/ecr.yaml and must survive teardown

# --- 2. Delete the root stack (cascades all 9 nested stacks) -------------
echo "==> Deleting stack $ROOT_STACK ..."
aws cloudformation delete-stack --stack-name "$ROOT_STACK"
echo "==> Waiting for deletion to complete (typically 10-20 min)..."
if ! aws cloudformation wait stack-delete-complete --stack-name "$ROOT_STACK"; then
  cat <<'EOF'

Deletion didn't finish cleanly. Check the stack events:
  aws cloudformation describe-stack-events --stack-name photo-gallery-dev-root --max-items 20

If a VPC endpoint is stuck in DELETE_IN_PROGRESS with an "UPDATE_PENDING is
too recent" error, that's a known AWS timing quirk we hit before, not a bug
here - wait ~15-20 minutes and just re-run this script (it's safe to re-run;
already-deleted resources are skipped automatically).
EOF
  exit 1
fi
echo "==> Root stack deleted."

# --- 3. Clean up the resources it deliberately left behind ---------------
echo "==> Cleaning up retained resources..."

# 3a. Secrets Manager - force-delete so a respin can reuse the name; Django secret key is a separate SSM param, untouched here
for secret in "$DB_SECRET"; do
  if aws secretsmanager describe-secret --secret-id "$secret" >/dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery >/dev/null
    echo "    deleted secret: $secret"
  else
    echo "    secret already gone: $secret"
  fi
done

# 3b. S3 buckets - empty and delete; deterministic names mean leftovers would block a respin's StorageCdnStack
for bucket in "$IMAGES_BUCKET" "$ACCESS_LOGS_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    empty_bucket_all_versions "$bucket"
    aws s3api delete-bucket --bucket "$bucket"
    echo "    deleted bucket: $bucket"
  else
    echo "    bucket already gone: $bucket"
  fi
done

# 3c. KMS - the alias is already gone by the time this runs, so scan all keys by description and schedule deletion on alias-less ones
echo "    scanning for orphaned KMS keys tagged for ${PROJECT}-${ENV}..."
ALIASED_KEY_IDS=" $(aws kms list-aliases --query 'Aliases[?TargetKeyId!=`null`].TargetKeyId' --output text) "
FOUND_ORPHAN=false
for KEY_ID in $(aws kms list-keys --query 'Keys[].KeyId' --output text); do
  STATE=$(aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "")
  [ "$STATE" = "Enabled" ] || continue
  case "$ALIASED_KEY_IDS" in
    *" $KEY_ID "*) continue ;;
  esac
  DESC=$(aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.Description' --output text)
  case "$DESC" in
    "CMK for ${PROJECT}-${ENV} "*)
      FOUND_ORPHAN=true
      if [ -n "$SCHEDULE_KEY_DAYS" ]; then
        aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days "$SCHEDULE_KEY_DAYS" >/dev/null
        echo "    scheduled orphaned key $KEY_ID for deletion in $SCHEDULE_KEY_DAYS days"
      else
        echo "    orphaned key found: $KEY_ID - pass --schedule-key-deletion-days=N to schedule its deletion"
      fi
      ;;
  esac
done
[ "$FOUND_ORPHAN" = true ] || echo "    no alias-less orphaned keys found for ${PROJECT}-${ENV}"

# 3d. RDS final snapshot - CFN names it unpredictably, so match loosely by substring instead of an assumed prefix
SNAPSHOT=$(aws rds describe-db-snapshots \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier, \`${PROJECT}-${ENV}\`)].DBSnapshotIdentifier" \
  --output text)
if [ -n "$SNAPSHOT" ] && [ "$SNAPSHOT" != "None" ]; then
  echo "    final RDS snapshot: $SNAPSHOT"
  if [ "$DELETE_SNAPSHOT" = true ]; then
    aws rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT" >/dev/null
    echo "    deleted snapshot: $SNAPSHOT"
  else
    echo "    left in place - pass --delete-snapshot to remove it too (it's your only restore point)"
  fi
else
  echo "    no final RDS snapshot found"
fi

echo
echo "==> Done. Root stack and its retained resources are handled."
echo "==> bootstrap.yaml's stack (md5-PhotoUploaderLab) is untouched by design -"
echo "    see HANDOFF.md if you also want to tear that down."
