#!/usr/bin/env bash
# Run from image.tf (local-exec) once the gallery image version exists: deletes
# the uploaded VHD, which Terraform does not own. BLOB_URL is the blob URL with
# a SAS that allows delete. A blob that is already gone is fine; the URL is not printed.
set -euo pipefail

: "${BLOB_URL:?BLOB_URL must be set}"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 --retry 3 --retry-delay 10 \
  -X DELETE -H "x-ms-version: 2021-08-06" "$BLOB_URL") || code=000

case "$code" in
  202 | 404) echo "VHD blob deleted (HTTP $code)" >&2 ;;
  *)
    echo "ERROR: deleting the VHD blob returned HTTP $code; delete it by hand or set keep_build_artifacts = true." >&2
    [ "$code" = 403 ] && echo "HTTP 403: the SAS token has probably expired; run deploy.sh --rebuild for a new one." >&2
    exit 1
    ;;
esac
