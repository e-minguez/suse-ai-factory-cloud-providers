#!/usr/bin/env bash
# Invoked from image.tf via a creation-time local-exec provisioner on
# vultr_snapshot_from_url, on the operator's machine. The provider returns
# once the import is accepted, with the snapshot "pending"; this polls
# SNAPSHOT_ID until "complete". Needs curl and jq.
set -euo pipefail

: "${SNAPSHOT_ID:?SNAPSHOT_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"
: "${SNAPSHOT_DESCRIPTION:?SNAPSHOT_DESCRIPTION must be set}"

if [ -z "${VULTR_API_KEY:-}" ]; then
  echo "ERROR: VULTR_API_KEY is not set (Terraform passes vultr_api_key)." >&2
  exit 1
fi

# shellcheck source=../../../scripts/lib/poll.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/poll.sh"

API_BASE="https://api.vultr.com/v2"
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

# The API answers 5xx during maintenance windows, including mid-import; that
# neither fails the wait nor resets the clock. Give up after MAX_TRANSIENT
# consecutive failures.
TRANSIENT=0
MAX_TRANSIENT=20
FAIL_MSG=""

# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until; sets its POLL_* vars
probe() {
  local code status
  # Not -f: a 404 is diagnosed below. -4: see wait-for-lb-ipv4.sh. The key goes in on stdin
  # (curl config), not in argv, so it stays out of `ps`.
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY" |
    curl -4 -sS -K - -o "$BODY_FILE" -w '%{http_code}' --max-time 30 \
      "$API_BASE/snapshots/$SNAPSHOT_ID" || true)
  case "$code" in
    200)
      TRANSIENT=0
      status=$(jq -r '.snapshot.status // ""' "$BODY_FILE")
      POLL_STATUS=${status:-unknown}
      case "$status" in
        complete) return 0 ;;
        pending) return 1 ;;
        *)
          FAIL_MSG="snapshot $SNAPSHOT_ID is in status \"$status\", not \"pending\" or \"complete\""
          POLL_DETAIL="snapshot_status=$status"
          return 2
          ;;
      esac
      ;;
    404)
      FAIL_MSG="snapshot $SNAPSHOT_ID no longer exists. The platform deletes the record when its fetch fails: port 80 may not have propagated yet or the serve window ran out. The jumphost log (/var/log/elemental-factory.log) shows non-loopback fetches."
      POLL_DETAIL="http=404"
      return 2
      ;;
    000 | 5??)
      TRANSIENT=$((TRANSIENT + 1))
      POLL_STATUS=api_unavailable
      POLL_DETAIL="http=$code consecutive=$TRANSIENT/$MAX_TRANSIENT"
      if [ "$TRANSIENT" -ge "$MAX_TRANSIENT" ]; then
        FAIL_MSG="the Vultr API was unavailable for $MAX_TRANSIENT consecutive polls; the snapshot may still complete (vultr-cli snapshot get $SNAPSHOT_ID)"
        return 2
      fi
      return 1
      ;;
    *)
      FAIL_MSG="the Vultr API rejected the request (HTTP $code). Check that vultr_api_key is valid and, if IP-restricted, allows this machine."
      POLL_DETAIL="http=$code"
      return 2
      ;;
  esac
}

rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$rc" -eq 1 ] && FAIL_MSG="timed out with snapshot $SNAPSHOT_ID still pending; the jumphost has stopped serving, so it will not complete"
  {
    echo "ERROR: $FAIL_MSG"
    echo "The resource is in state with an id that may no longer exist. Before re-running apply:"
    echo "  terraform state rm 'module.ai_factory.vultr_snapshot_from_url.ai_factory[0]'"
  } >&2
  exit 1
fi

# The uefi flag is write-only on this endpoint; if reported, it must be truthy.
if jq -e '[.. | objects | to_entries[] | select(.key | test("uefi"; "i")) | .value] | any(. == false or . == null or . == 0 or . == "")' "$BODY_FILE" >/dev/null 2>&1; then
  echo "ERROR: snapshot $SNAPSHOT_ID reports a falsy EFI flag" >&2
  exit 1
fi

# The provider treats description as computed-only; set it here so the snapshot
# can be found by name (tools/leftovers/vultr.sh). Retries 000/5xx (PUT_ATTEMPTS, sleeping
# PUT_RETRY_SLEEP, default POLL_SECONDS); 4xx or exhausted retries fail the script.
PUT_BODY=$(jq -nc --arg d "$SNAPSHOT_DESCRIPTION" '{description: $d}')
attempt=0
while :; do
  attempt=$((attempt + 1))
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY" |
    curl -4 -sS -K - -o "$BODY_FILE" -w '%{http_code}' --max-time 30 -X PUT \
      -H "Content-Type: application/json" -d "$PUT_BODY" \
      "$API_BASE/snapshots/$SNAPSHOT_ID" || true)
  case "$code" in
    2??) break ;;
    000 | 5??)
      if [ "$attempt" -lt "${PUT_ATTEMPTS:-5}" ]; then
        sleep "${PUT_RETRY_SLEEP:-$POLL_SECONDS}"
        continue
      fi
      ;;
  esac
  echo "ERROR: setting the description of snapshot $SNAPSHOT_ID failed (HTTP ${code:-000}, attempt $attempt)" >&2
  exit 1
done
