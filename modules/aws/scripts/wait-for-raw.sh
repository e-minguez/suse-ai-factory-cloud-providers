#!/usr/bin/env bash
# Run from build.tf (local-exec) on the operator's machine. Waits until the
# jumphost's raw image exists in S3; Terraform then imports it. A multipart
# upload is invisible under its key until complete, so a HEAD is enough.
set -euo pipefail

: "${BUCKET:?BUCKET must be set}"
: "${RAW_KEY:?RAW_KEY must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"

# shellcheck source=../../../scripts/lib/poll.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/poll.sh"

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

# 404 means not built yet. Any other error will not fix itself by waiting.
# POLL_STATUS/POLL_DETAIL are read by poll_until.
# shellcheck disable=SC2034
probe() {
  local size
  if size=$(aws s3api head-object --region "$AWS_REGION" --bucket "$BUCKET" \
    --key "$RAW_KEY" --query ContentLength --output text 2>"$ERR_FILE"); then
    POLL_DETAIL="size_mib=$((size / 1024 / 1024))"
    return 0
  fi
  if grep -qE '\(404\)|Not Found' "$ERR_FILE"; then
    POLL_STATUS=building
    return 1
  fi
  POLL_DETAIL="head-object failed: $(tr '\n' ' ' <"$ERR_FILE")"
  return 2
}

echo "waiting for s3://$BUCKET/$RAW_KEY" >&2
rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
case "$rc" in
  0) ;;
  1)
    echo "ERROR: timed out waiting for s3://$BUCKET/$RAW_KEY. Follow the build with scripts/build-logs.sh." >&2
    exit 1
    ;;
  *)
    echo "ERROR: head-object failed for s3://$BUCKET/$RAW_KEY (see status line above)" >&2
    exit 1
    ;;
esac
