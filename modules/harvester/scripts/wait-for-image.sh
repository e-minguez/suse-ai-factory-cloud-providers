#!/usr/bin/env bash
# Run from build.tf (local-exec) on the operator's machine. Polls the status file
# the buildhost serves over HTTP ("<build_id> <building|done|failed> <detail>")
# until it reports done for BUILD_ID; failed stops at once. Another build id is
# stale. The buildhost is created by the same apply, so the first polls can fail.
# POWER_OFF=true: then waits until the buildhost stops answering (it powers off
# after it sees this poll), so the export reads a detached volume; a timeout
# there only warns (export from a running VM works too).
set -euo pipefail

: "${STATUS_URL:?STATUS_URL must be set}"
: "${BUILD_ID:?BUILD_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"
POWER_OFF=${POWER_OFF:-false}
OFF_TIMEOUT_SECONDS=${OFF_TIMEOUT_SECONDS:-900}

# shellcheck source=../../../scripts/lib/poll.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/poll.sh"

# POLL_STATUS and POLL_DETAIL are read by poll_until.
# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until
probe() {
  local body line id state detail
  if ! body=$(curl -fsS -m 10 "$STATUS_URL" 2>/dev/null); then
    POLL_STATUS=unreachable
    return 1
  fi
  line=${body%%$'\n'*}
  read -r id state detail <<<"$line"
  if [ "$id" != "$BUILD_ID" ]; then
    POLL_STATUS=waiting
    return 1
  fi
  case "$state" in
    done) POLL_DETAIL=$detail; return 0 ;;
    failed) POLL_DETAIL=$detail; return 2 ;;
    *) POLL_STATUS=${detail%%:*}; POLL_DETAIL=$detail; return 1 ;;
  esac
}

echo "waiting for build \"$BUILD_ID\" via $STATUS_URL (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)" >&2
rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
case "$rc" in
  0) ;;
  2)
    echo "ERROR: the build failed. Read its log with scripts/build-logs.sh (build host: output build_status)." >&2
    exit 1
    ;;
  *)
    echo "ERROR: timeout after ${TIMEOUT_SECONDS}s. A build stuck on one step is failing there; an unreachable status URL means the buildhost cannot be reached from this machine, never booted, or already powered off after an earlier apply was interrupted (start it in Harvester: it serves the status again). Follow it with scripts/build-logs.sh." >&2
    exit 1
    ;;
esac

[ "$POWER_OFF" = true ] || exit 0

# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until
probe_off() {
  if curl -fsS -m 10 -o /dev/null "$STATUS_URL" 2>/dev/null; then
    POLL_STATUS=powering_off
    return 1
  fi
  POLL_DETAIL="buildhost off"
  return 0
}

echo "waiting for the buildhost to power off (timeout ${OFF_TIMEOUT_SECONDS}s)" >&2
if ! poll_until "$OFF_TIMEOUT_SECONDS" "$POLL_SECONDS" probe_off; then
  echo "WARNING: the buildhost still answers after ${OFF_TIMEOUT_SECONDS}s; exporting from the running VM." >&2
fi
