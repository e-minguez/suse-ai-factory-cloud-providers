#!/usr/bin/env bash
# Run from build.tf (local-exec) on the operator's machine. Polls the guest
# attributes the jumphost writes (namespace $NAMESPACE: build_id, state, message)
# through the Compute API until it reports "done" for BUILD_ID. "failed" stops
# at once. ACCESS_TOKEN is a credential: it goes to curl on stdin, never into
# the process list or the output.
set -euo pipefail

: "${PROJECT:?PROJECT must be set}"
: "${ZONE:?ZONE must be set}"
: "${INSTANCE:?INSTANCE must be set}"
: "${NAMESPACE:?NAMESPACE must be set}"
: "${BUILD_ID:?BUILD_ID must be set}"
: "${ACCESS_TOKEN:?ACCESS_TOKEN must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

# shellcheck source=../../../scripts/lib/poll.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/poll.sh"

URL="https://compute.googleapis.com/compute/v1/projects/${PROJECT}/zones/${ZONE}/instances/${INSTANCE}/getGuestAttributes?queryPath=${NAMESPACE}/"

err() {
  echo "[wait-for-image] $*" >&2
}

# Guest attributes exist once the jumphost has written the first one: 404 means
# "not yet" (the instance is booting), anything else but 200 is an error.
# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until; sets its POLL_* vars
probe() {
  local body code state id message
  body=$(mktemp)
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" |
    curl -sS -K - -m 20 -o "$body" -w '%{http_code}' "$URL" 2>/dev/null) || code=000
  case "$code" in
    200) ;;
    404)
      rm -f "$body"
      POLL_STATUS=booting
      return 1
      ;;
    401)
      rm -f "$body"
      POLL_DETAIL="http=401"
      err "ERROR: the access token expired (it lives about an hour from the plan). Run deploy.sh again; the build goes on on the jumphost."
      return 2
      ;;
    000)
      rm -f "$body"
      POLL_STATUS=unreachable
      return 1
      ;;
    *)
      rm -f "$body"
      POLL_DETAIL="http=$code"
      err "ERROR: reading the guest attributes of $INSTANCE failed with HTTP $code (the Compute API needs compute.instances.getGuestAttributes)."
      return 2
      ;;
  esac
  state=$(jq -r '[.queryValue.items[]? | select(.key == "state")][0].value // ""' "$body")
  id=$(jq -r '[.queryValue.items[]? | select(.key == "build_id")][0].value // ""' "$body")
  message=$(jq -r '[.queryValue.items[]? | select(.key == "message")][0].value // ""' "$body")
  rm -f "$body"
  # Another build id is a leftover of an earlier jumphost.
  if [ -n "$id" ] && [ "$id" != "$BUILD_ID" ]; then
    POLL_STATUS=stale
    return 1
  fi
  case "$state" in
    done) return 0 ;;
    failed)
      POLL_DETAIL="$message"
      return 2
      ;;
    building)
      POLL_STATUS=${message%%:*}
      POLL_STATUS=${POLL_STATUS// /_}
      return 1
      ;;
    *)
      POLL_STATUS=waiting
      return 1
      ;;
  esac
}

err "waiting for build \"$BUILD_ID\" on $INSTANCE (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"
rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
case "$rc" in
  0) err "build \"$BUILD_ID\" is on the target disk" ;;
  2) err "the build failed or could not be read. Read the log with scripts/build-logs.sh, fix the cause and run deploy.sh --rebuild: a plain rerun reads the same failed build." ;;
  *) err "TIMEOUT after ${TIMEOUT_SECONDS}s. Follow the build with scripts/build-logs.sh: a step that keeps failing shows there." ;;
esac
exit "$rc"
