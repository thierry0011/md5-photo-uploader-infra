#!/usr/bin/env bash
# Tears down the photo-gallery-dev root stack cleanly through CloudFormation
# (a single delete-stack call cascades all 9 nested stacks, in the right
# order, automatically - no manual per-resource deletion), then purges the
# handful of resources that deliberately survive stack deletion because of
# their DeletionPolicy (Retain/Snapshot - see each template). Re-run-safe:
# every step checks whether there's anything left to do before acting.
#
# Does NOT touch bootstrap.yaml's stack (md5-PhotoUploaderLab) or
# templates/ecr.yaml's stack - both are CloudFormation Git-sync-managed
# (no CLI-scriptable delete path) and, for ecr.yaml, deliberately meant to
# survive every teardown/respin cycle on purpose (see that template's
# Description). See HANDOFF.md for the console steps to remove either, and
# for why you'd want to leave them in place most of the time anyway.
#
# Usage:
#   AWS_PROFILE=admin ./teardown.sh [--yes] [--delete-snapshot] [--schedule-key-deletion-days=N]
#
#   --yes                            Skip the "type the stack name" confirmation.
#   --delete-snapshot                Also delete the final RDS snapshot CFN
#                                    creates on DBInstance deletion. Default:
#                                    leave it - it's the only way to restore
#                                    this lab's data later.
#   --schedule-key-deletion-days=N   Schedule the retained KMS key for
#                                    deletion after N days (7-30). Default:
#                                    leave the key pending-retention forever;
#                                    only the alias is removed (so a respin
#                                    can reuse the alias name immediately -
#                                    a respin's new key doesn't need this
#                                    one gone, only the alias free).
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
DJANGO_SECRET="${PROJECT}-${ENV}-django-secret-key"
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
# No DeletionPolicy on this one (defaults to Delete) but it's versioned and
# CodePipeline writes to it continuously on every deploy. A non-empty
# versioned bucket makes CicdPipelineStack - and so the whole root stack -
# fail deletion, which is exactly the "stuck stack" pattern from earlier.
# Emptying it up front avoids that entirely.
echo "==> Emptying $PIPELINE_ARTIFACT_BUCKET so stack deletion doesn't stall on it..."
empty_bucket_all_versions "$PIPELINE_ARTIFACT_BUCKET"

# NOTE: there used to be a step here that emptied the ECR repository before
# deleting the stack. Not anymore, on purpose - the repository now lives in
# templates/ecr.yaml, a standalone Git-sync stack outside this tree, so
# root's deletion never touches it and there's nothing here to empty. Do
# NOT reintroduce an "empty the ECR repo" step: that would defeat the whole
# point of pulling it out (keeping the last working image across a
# teardown/respin cycle).

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

# 3a. Secrets Manager - force-delete (no recovery window) so a respin can
#     recreate a secret with the same name immediately, instead of hitting
#     "already scheduled for deletion".
for secret in "$DB_SECRET" "$DJANGO_SECRET"; do
  if aws secretsmanager describe-secret --secret-id "$secret" >/dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery >/dev/null
    echo "    deleted secret: $secret"
  else
    echo "    secret already gone: $secret"
  fi
done

# 3b. S3 buckets (versioned, Retain) - empty every version + delete marker,
#     then delete the bucket itself. Bucket names are deterministic (no
#     random suffix), so leaving these behind would block a respin's
#     StorageCdnStack from creating a bucket with the same name.
for bucket in "$IMAGES_BUCKET" "$ACCESS_LOGS_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    empty_bucket_all_versions "$bucket"
    aws s3api delete-bucket --bucket "$bucket"
    echo "    deleted bucket: $bucket"
  else
    echo "    bucket already gone: $bucket"
  fi
done

# 3c. KMS - AppKmsKeyAlias has no DeletionPolicy of its own (only AppKmsKey
#     does), so CloudFormation already deletes the alias itself as a normal
#     part of root-stack deletion, well before this script ever runs. That
#     means looking the key up *through* the alias (the old approach here)
#     always finds nothing and silently skips scheduling deletion - the
#     underlying Retain'd key it should have found stays pending forever
#     regardless of --schedule-key-deletion-days. Instead, scan every KMS
#     key in the account for this project's Description tag and schedule
#     deletion on any of them that currently have zero aliases pointing at
#     them - a key still under any alias is still in active use somewhere
#     (e.g. a not-yet-cleaned-up orphaned nested stack) and must be left
#     alone. This also sweeps up any keys orphaned by earlier teardown runs,
#     not just the one from this run.
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

# 3d. RDS final snapshot - CloudFormation names it automatically when
#     DBInstance is deleted under a Snapshot policy, using the nested
#     stack's own logical/physical IDs (e.g.
#     "photo-gallery-dev-root-databasestack-<id>-snapshot-dbinstance-<id>"),
#     not a name you can predict from ProjectName/Environment alone -
#     match loosely by substring instead of assuming a prefix.
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
