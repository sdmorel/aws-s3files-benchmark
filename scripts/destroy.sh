#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Safe destroy script for aws-s3-benchmark infrastructure
#
# Handles the tricky destruction order that Terraform struggles
# with, especially around S3 Files file systems that hold a lock
# on the S3 bucket.
#
# Lessons learned (the hard way):
#   1. S3 Files FS must be force-deleted BEFORE the bucket.
#      The FS holds a lock on the bucket (BucketHasS3FileSystemAttached)
#      that blocks bucket deletion entirely — even after the FS is
#      "deleted", AWS needs several minutes to release the lock.
#   2. The AWS CLI does NOT have an s3files/s3-files subcommand yet.
#      We use boto3 (the s3files service) with fileSystemId (camelCase)
#      and forceDelete=True to force-delete the file system.
#   3. S3 Files FS deletion requires removing mount targets AND
#      access points first. The API returns ConflictException if you
#      try to delete a FS that has mount targets or access points.
#   4. S3 bucket versioning can't be modified while S3 Files is
#      attached — remove S3 Files first.
#   5. Bucket must be emptied of ALL versions and delete markers
#      before deletion. Simple `aws s3 rm --recursive` is NOT enough
#      for versioned buckets.
#   6. Security group deletion can be slow (ENI cleanup). Removing
#      the EC2 instance first helps but doesn't eliminate the delay.
#   7. After S3 Files FS force-delete, the bucket remains locked for
#      5-10 minutes. Poll until the bucket can be deleted.
#   8. On t3.micro (1 GiB RAM), 200MB fio tests cause OOM kills.
#      Stick to file sizes ≤ 100MB on memory-constrained instances.
#
# Usage:  ./scripts/destroy.sh [options]
#
# Options:
#   --skip-confirmation   Skip the "are you sure?" prompt
#   --keep-bucket         Keep the S3 bucket (only destroy compute/IAM)
#   --dry-run             Show what would be destroyed, don't actually destroy
# ============================================================

SKIP_CONFIRM=false
KEEP_BUCKET=false
DRY_RUN=false
REGION=""

for arg in "$@"; do
    case "$arg" in
        --skip-confirmation) SKIP_CONFIRM=true ;;
        --keep-bucket)       KEEP_BUCKET=true ;;
        --dry-run)           DRY_RUN=true ;;
        -h|--help)
            echo "Usage: $0 [--skip-confirmation] [--keep-bucket] [--dry-run]"
            echo ""
            echo "Safely destroys the aws-s3-benchmark infrastructure,"
            echo "handling S3 Files FS force-delete and bucket lock delays."
            exit 0 ;;
    esac
done

# ---------------------------------------------------------------------------
# 0. Read region from tfvars if not set
# ---------------------------------------------------------------------------
REGION=$(grep -E '^region\s*=' terraform.tfvars 2>/dev/null | sed "s/.*=.*['\"]//;s/['\"].*//" || echo "")
if [ -z "$REGION" ]; then
    REGION="eu-south-2"
fi

if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN — no changes will be made ==="
    echo ""
fi

# ---------------------------------------------------------------------------
# 1. Gather info from state
# ---------------------------------------------------------------------------
echo "Gathering infrastructure details from Terraform state..."

BUCKET_NAME=$(tofu output -raw bucket_name 2>/dev/null || echo "")
FS_ID=$(tofu output -raw s3_files_file_system_id 2>/dev/null || echo "")

if [ -z "$BUCKET_NAME" ]; then
    echo "ERROR: Could not determine bucket name from state."
    echo "       Is the infrastructure deployed? Run: tofu output"
    exit 1
fi

echo "  Bucket:         $BUCKET_NAME"
echo "  S3 Files FS ID: ${FS_ID:-none}"
echo "  Region:         $REGION"
echo ""

# ---------------------------------------------------------------------------
# 2. Confirmation prompt
# ---------------------------------------------------------------------------
if [ "$SKIP_CONFIRM" = false ]; then
    echo "This will DESTROY all benchmark infrastructure:"
    echo "  - EC2 instance"
    echo "  - S3 Files file system (force-delete)"
    echo "  - S3 bucket and ALL objects (including versioned)"
    echo "  - IAM roles and policies"
    echo "  - Security groups"
    echo ""
    echo "WARNING: S3 Files force-delete may leave the bucket locked"
    echo "         for 5-10 minutes. This script will poll until the"
    echo "         bucket can be deleted, up to 15 minutes."
    echo ""
    read -rp "Are you sure? Type 'destroy' to continue: " confirm
    if [ "$confirm" != "destroy" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 3. Destroy EC2 instance and IAM via Terraform (partial destroy)
#    We destroy compute first so the security group can be released.
# ---------------------------------------------------------------------------
echo ""
echo "[1/7] Destroying EC2 instance and IAM resources via Terraform..."

if [ "$DRY_RUN" = false ]; then
    tofu destroy -var-file=terraform.tfvars -auto-approve \
        -target='module.ec2_benchmark.aws_instance.benchmark' \
        -target='module.ec2_benchmark.aws_iam_role_policy.s3_access' \
        -target='module.ec2_benchmark.aws_iam_role_policy_attachment.s3_files_client_full' \
        -target='module.ec2_benchmark.aws_iam_instance_profile.ec2_profile' \
        -target='module.ec2_benchmark.aws_iam_role.ec2_s3_role' \
        2>&1 | tail -5 || true
else
    echo "  Would destroy EC2 instance and IAM resources"
fi

# ---------------------------------------------------------------------------
# 4. Force-delete S3 Files file system via boto3
# ---------------------------------------------------------------------------
if [ -n "$FS_ID" ]; then
    echo ""
    echo "[2/7] Force-deleting S3 Files file system: $FS_ID"

    if [ "$DRY_RUN" = false ]; then
        # Remove from Terraform state first (so destroy doesn't block on it)
        tofu state rm 'module.ec2_benchmark.aws_s3files_mount_target.this[0]' 2>/dev/null || true
        tofu state rm 'module.ec2_benchmark.aws_s3files_file_system.this[0]' 2>/dev/null || true
        tofu state rm 'module.ec2_benchmark.aws_iam_role_policy.s3_files_service_policy[0]' 2>/dev/null || true
        tofu state rm 'module.ec2_benchmark.aws_iam_role.s3_files_service_role[0]' 2>/dev/null || true

        # Force-delete via boto3 (the AWS CLI doesn't support s3files yet)
        # Must remove mount targets and access points before deleting the FS
        python3 -c "
import boto3, sys, time
try:
    client = boto3.client('s3files', region_name='$REGION')

    # Step 1: Delete mount targets
    try:
        mts = client.list_mount_targets(fileSystemId='$FS_ID')
        for mt in mts.get('mountTargets', []):
            mt_id = mt['mountTargetId']
            print(f'  Deleting mount target: {mt_id}')
            try:
                client.delete_mount_target(mountTargetId=mt_id)
            except Exception as e:
                print(f'  Mount target {mt_id} delete error: {e}')
        if mts.get('mountTargets'):
            print('  Waiting 15s for mount targets to delete...')
            time.sleep(15)
    except Exception as e:
        print(f'  List mount targets error: {e}')

    # Step 2: Delete access points
    try:
        aps = client.list_access_points(fileSystemId='$FS_ID')
        for ap in aps.get('accessPoints', []):
            ap_id = ap['accessPointId']
            print(f'  Deleting access point: {ap_id}')
            try:
                client.delete_access_point(accessPointId=ap_id)
            except Exception as e:
                print(f'  Access point {ap_id} delete error: {e}')
        if aps.get('accessPoints'):
            print('  Waiting 15s for access points to delete...')
            time.sleep(15)
    except Exception as e:
        print(f'  List access points error: {e}')

    # Step 3: Force-delete the file system
    client.delete_file_system(fileSystemId='$FS_ID', forceDelete=True)
    print('  S3 Files FS force-deleted successfully.')
except Exception as e:
    print(f'  boto3 error: {e}')
    print('  Attempting fallback: check if FS already deleted...')
    try:
        client = boto3.client('s3files', region_name='$REGION')
        client.get_file_system(fileSystemId='$FS_ID')
        print(f'  WARNING: FS $FS_ID still exists!')
        print(f'  Delete manually from AWS Console:')
        print(f'    https://$REGION.console.aws.amazon.com/s3/files-home')
    except:
        print('  FS appears already deleted.')
" 2>/dev/null || {
            # Fallback: install boto3 to a venv if not available
            echo "  boto3 not found, setting up temporary venv..."
            python3 -m venv /tmp/destroy-venv 2>/dev/null || true
            /tmp/destroy-venv/bin/pip install boto3 -q 2>/dev/null || true
            /tmp/destroy-venv/bin/python3 -c "
import boto3, time
client = boto3.client('s3files', region_name='$REGION')

# Delete mount targets
try:
    mts = client.list_mount_targets(fileSystemId='$FS_ID')
    for mt in mts.get('mountTargets', []):
        try:
            client.delete_mount_target(mountTargetId=mt['mountTargetId'])
        except: pass
    if mts.get('mountTargets'):
        time.sleep(15)
except: pass

# Delete access points
try:
    aps = client.list_access_points(fileSystemId='$FS_ID')
    for ap in aps.get('accessPoints', []):
        try:
            client.delete_access_point(accessPointId=ap['accessPointId'])
        except: pass
    if aps.get('accessPoints'):
        time.sleep(15)
except: pass

# Force-delete FS
try:
    client.delete_file_system(fileSystemId='$FS_ID', forceDelete=True)
    print('  S3 Files FS force-deleted successfully.')
except Exception as e:
    print(f'  Force-delete error: {e}')
    print('  FS may already be deleted or require manual intervention.')
"
            rm -rf /tmp/destroy-venv
        }
    else
        echo "  Would force-delete S3 Files FS"
    fi
else
    echo ""
    echo "[2/7] No S3 Files file system found — skipping"
fi

# ---------------------------------------------------------------------------
# 5. Empty the S3 bucket (versions + delete markers + objects)
# ---------------------------------------------------------------------------
if [ "$KEEP_BUCKET" = false ]; then
    echo ""
    echo "[3/7] Emptying S3 bucket: $BUCKET_NAME"

    if [ "$DRY_RUN" = false ]; then
        # Delete all objects first (fast, non-versioned)
        aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$REGION" 2>/dev/null || true

        # Delete all versioned objects and delete markers in batches
        echo "  Removing versioned objects..."
        VERSIONS_JSON=$(aws s3api list-object-versions \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" \
            --output json 2>/dev/null || echo '{}')

        echo "$VERSIONS_JSON" | python3 -c "
import sys, json, subprocess
try:
    d = json.load(sys.stdin)
    objs = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in d.get('Versions', [])]
    objs += [{'Key': m['Key'], 'VersionId': m['VersionId']} for m in d.get('DeleteMarkers', [])]
    if objs:
        # Batch delete (max 1000 per call)
        for i in range(0, len(objs), 1000):
            batch = objs[i:i+1000]
            delete_json = json.dumps({'Objects': batch, 'Quiet': True})
            result = subprocess.run(
                ['aws', 's3api', 'delete-objects',
                 '--bucket', '$BUCKET_NAME',
                 '--region', '$REGION',
                 '--delete', delete_json],
                capture_output=True, text=True
            )
        print(f'  Deleted {len(objs)} versions/markers.')
    else:
        print('  No versions or markers found.')
except Exception as e:
    print(f'  Warning: {e}')
" 2>/dev/null || echo "  Warning: Could not fully clean versioned objects"

        echo "  Bucket emptied."
    else
        echo "  Would empty bucket (delete all versions and markers)"
    fi
else
    echo ""
    echo "[3/7] Keeping S3 bucket (--keep-bucket)"
fi

# ---------------------------------------------------------------------------
# 6. Remove resources from state that Terraform struggles with
# ---------------------------------------------------------------------------
echo ""
echo "[4/7] Cleaning up Terraform state..."

if [ "$DRY_RUN" = false ]; then
    # Remove bucket versioning from state (can't be modified while S3 Files attached)
    tofu state rm 'module.s3_bucket.aws_s3_bucket_versioning.this' 2>/dev/null || true
    # Remove bucket policy if exists
    tofu state rm 'module.s3_bucket.aws_s3_bucket_policy.this' 2>/dev/null || true
else
    echo "  Would clean up Terraform state"
fi

# ---------------------------------------------------------------------------
# 7. Run tofu destroy for remaining resources
# ---------------------------------------------------------------------------
echo ""
echo "[5/7] Running tofu destroy for remaining resources..."

if [ "$DRY_RUN" = false ]; then
    tofu destroy -var-file=terraform.tfvars -auto-approve 2>&1 | tail -5 || true
else
    echo "  Would run: tofu destroy -var-file=terraform.tfvars -auto-approve"
fi

# ---------------------------------------------------------------------------
# 8. Wait for S3 Files lock to release and delete bucket
# ---------------------------------------------------------------------------
if [ "$KEEP_BUCKET" = false ]; then
    echo ""
    echo "[6/7] Waiting for S3 bucket lock to release (up to 15 min)..."

    if [ "$DRY_RUN" = false ]; then
        MAX_WAIT=900  # 15 minutes
        ELAPSED=0
        INTERVAL=30

        while [ $ELAPSED -lt $MAX_WAIT ]; do
            if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
                # Try to delete the bucket
                if aws s3 rb "s3://$BUCKET_NAME" --region "$REGION" --force 2>/dev/null; then
                    echo "  Bucket deleted successfully after ${ELAPSED}s."
                    break
                else
                    # Bucket exists but can't be deleted yet (S3 Files lock)
                    echo "  Bucket still locked... (${ELAPSED}s elapsed)"
                fi
            else
                echo "  Bucket already deleted."
                break
            fi

            sleep $INTERVAL
            ELAPSED=$((ELAPSED + INTERVAL))
        done

        if [ $ELAPSED -ge $MAX_WAIT ]; then
            echo "  WARNING: Bucket lock not released after 15 minutes."
            echo "  Try again later with:"
            echo "    aws s3 rb s3://$BUCKET_NAME --force --region $REGION"
        fi

        # Remove from state if bucket was deleted externally
        if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
            tofu state rm 'module.s3_bucket.aws_s3_bucket.this' 2>/dev/null || true
        fi
    else
        echo "  Would poll and delete bucket after S3 Files lock releases"
    fi
else
    echo ""
    echo "[6/7] Keeping S3 bucket (--keep-bucket)"
fi

# ---------------------------------------------------------------------------
# 9. Final cleanup
# ---------------------------------------------------------------------------
echo ""
echo "[7/7] Final cleanup..."

if [ "$DRY_RUN" = false ]; then
    # Remove any remaining state entries
    tofu state list 2>/dev/null | while read -r resource; do
        echo "  Removing from state: $resource"
        tofu state rm "$resource" 2>/dev/null || true
    done

    # Clean up local venv if we created one
    rm -rf /tmp/destroy-venv 2>/dev/null || true
else
    echo "  Would remove remaining state entries"
fi

echo ""
echo "============================================================"
echo "  Destroy complete!"
if [ "$DRY_RUN" = true ]; then
    echo "  (DRY RUN — no changes were made)"
fi
echo ""
echo "  Remaining resources to verify manually:"
echo "    - S3 bucket:     https://$REGION.console.aws.amazon.com/s3/buckets"
echo "    - S3 Files FS:   https://$REGION.console.aws.amazon.com/s3/files-home"
echo "    - IAM roles:     https://$REGION.console.aws.amazon.com/iam/roles"
echo "    - EC2 instances: https://$REGION.console.aws.amazon.com/ec2"
echo "============================================================"