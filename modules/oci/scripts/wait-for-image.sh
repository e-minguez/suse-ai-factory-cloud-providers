#!/usr/bin/env bash
# Run from build.tf (local-exec) on the operator's machine. Waits until the
# jumphost has uploaded the qcow2: it writes the done marker last, and DONE_URL
# is a read-only pre-authenticated request for that object. HEAD, so a poll
# never pulls data.
set -euo pipefail

: "${DONE_URL:?DONE_URL must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

# shellcheck source=../../../scripts/lib/poll.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/poll.sh"

# 404 means not uploaded yet. The URL is not printed: it is a credential.
# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until; sets its POLL_* vars
probe() {
  if curl -sfI -o /dev/null --max-time 10 "$DONE_URL" 2>/dev/null; then
    return 0
  fi
  POLL_STATUS=building
  return 1
}

echo "waiting for the image upload marker" >&2
rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
if [ "$rc" -ne 0 ]; then
  {
    echo "ERROR: the done marker did not appear in time."
    echo "Either the build failed or the pre-authenticated request expired. Follow the build with scripts/build-logs.sh."
  } >&2
fi
exit "$rc"
