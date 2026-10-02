#!/usr/bin/env bash
# Sourced by wait scripts and deploy.sh. Provides poll_until.
#
#   poll_until <timeout_s> <interval_s> <probe-fn>
#
# The probe runs in the current shell and returns 0 (done), 1 (not yet) or
# 2 (fatal, stop now). It may set POLL_STATUS (one word, machine-parsable,
# default "waiting") and POLL_DETAIL (free text).
# Output on stdout: "status=<x> elapsed=<s> [detail]" at start, on every
# status change and every POLL_HEARTBEAT_MINUTES (default 5); the final line is
# status=done, status=failed or status=timeout.
# Return: 0 done, 1 timeout, 2 fatal probe.

poll_until() {
  local timeout=$1 interval=$2 probe=$3
  local heartbeat=$((${POLL_HEARTBEAT_MINUTES:-5} * 60))
  local start now elapsed rc last_status="" last_print=0

  start=$(date +%s)
  while true; do
    POLL_STATUS=waiting
    POLL_DETAIL=""
    rc=0
    "$probe" || rc=$?
    now=$(date +%s)
    elapsed=$((now - start))

    if [ "$rc" -eq 0 ]; then
      echo "status=done elapsed=$elapsed${POLL_DETAIL:+ $POLL_DETAIL}"
      return 0
    fi
    if [ "$rc" -ge 2 ]; then
      echo "status=failed elapsed=$elapsed${POLL_DETAIL:+ $POLL_DETAIL}"
      return 2
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "status=timeout elapsed=$elapsed last_status=$POLL_STATUS${POLL_DETAIL:+ $POLL_DETAIL}"
      return 1
    fi
    if [ "$POLL_STATUS" != "$last_status" ] || [ $((elapsed - last_print)) -ge "$heartbeat" ]; then
      echo "status=$POLL_STATUS elapsed=$elapsed${POLL_DETAIL:+ $POLL_DETAIL}"
      last_status=$POLL_STATUS
      last_print=$elapsed
    fi
    sleep "$interval"
  done
}
