#!/usr/bin/env bash
# Runs on the operator's machine (build.tf, terraform_data.image_written).
# Polls the status relay on the jumphost until every zone reports
# "done <BUILD_ID>"; "failed <BUILD_ID>" on any zone stops at once. Status
# lines are "<state> <build_id> <step>: <text>"; other build ids are stale.
set -euo pipefail

: "${STATUS_URL:?STATUS_URL must be set}"
: "${ZONES:?ZONES must be set}"
: "${BUILD_ID:?BUILD_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"
IMAGE_READY=${IMAGE_READY:-false}
# Consecutive relay failures before a zone counts as unreachable; the jumphost
# is created by the same apply, so the first polls legitimately find nothing.
UNREACHABLE_AFTER=3

# shellcheck source=../../../scripts/lib/poll.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/poll.sh"

err() {
  echo "[wait-for-image] $*" >&2
}

if [ "$IMAGE_READY" = "true" ]; then
  err "ERROR: build \"$BUILD_ID\" has to be waited for, but image_ready = true and nothing is building."
  err "An image-affecting input changed since pass 1. Rebuild: ./deploy.sh --rebuild (or set image_ready = false and apply)."
  exit 1
fi

# Parallel arrays: bash 3.2 has no associative ones.
read -r -a ZONE_LIST <<<"$ZONES"
ZONE_DONE=() # 1 once the zone reported done for BUILD_ID; latched
LAST=()      # last known step name per zone
FAILS=()     # consecutive polls without reaching the relay
for i in "${!ZONE_LIST[@]}"; do
  ZONE_DONE[i]=0
  LAST[i]=waiting
  FAILS[i]=0
done
STEPS="waiting prereqs pre_build check customize locate deliver"

# POLL_STATUS and POLL_DETAIL are read by poll_until.
# shellcheck disable=SC2034
probe() {
  local i z body rc line state id text step pending=0 detail="" best=99 rank n
  for i in "${!ZONE_LIST[@]}"; do
    [ "${ZONE_DONE[i]}" = 1 ] && continue
    z=${ZONE_LIST[i]}
    rc=0
    body=$(curl -fsS -m 10 "$STATUS_URL/$z" 2>/dev/null) || rc=$?
    line=""
    case "$rc" in
      0) FAILS[i]=0; line=${body%%$'\n'*} ;;
      22) FAILS[i]=0 ;; # relay answered, zone published nothing yet
      *) FAILS[i]=$((FAILS[i] + 1)) ;;
    esac
    state="" id="" text=""
    read -r state id text <<<"$line"
    if [ -n "$state" ] && [ "$id" != "$BUILD_ID" ]; then
      state=stale
    fi
    case "$state" in
      done) ZONE_DONE[i]=1; detail="$detail $z=done"; continue ;;
      failed)
        POLL_DETAIL="zone=$z $text"
        FAILED_ZONE=$z
        return 2
        ;;
      building) LAST[i]=${text%%:*} ;;
      *) LAST[i]=waiting ;;
    esac
    if [ "${FAILS[i]}" -ge "$UNREACHABLE_AFTER" ]; then
      LAST[i]=unreachable
    fi
    pending=$((pending + 1))
    detail="$detail $z=${LAST[i]}"
    rank=0 n=0
    for step in $STEPS; do
      [ "$step" = "${LAST[i]}" ] && rank=$n
      n=$((n + 1))
    done
    if [ "$rank" -lt "$best" ]; then
      best=$rank
      POLL_STATUS=${LAST[i]}
    fi
  done
  POLL_DETAIL=${detail# }
  [ "$pending" -eq 0 ]
}

FAILED_ZONE=""
err "waiting for build \"$BUILD_ID\" in zone(s) $ZONES via $STATUS_URL (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"
rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
case "$rc" in
  0) err "build \"$BUILD_ID\" ready in ${#ZONE_LIST[@]} zone(s)" ;;
  2)
    err "zone $FAILED_ZONE FAILED. Read its log with scripts/build-logs.sh --host <ip> (hosts: output build_status)."
    exit 1
    ;;
  *)
    err "TIMEOUT after ${TIMEOUT_SECONDS}s. A zone stuck on a step is failing there; one that is unreachable or never published never started or cannot reach the relay."
    exit 1
    ;;
esac
