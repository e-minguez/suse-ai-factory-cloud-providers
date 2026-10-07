#!/usr/bin/env bash
# Invoked from control-plane.tf via a local-exec provisioner on the operator's
# machine. Polls the Kubernetes API through the NLB until it answers with any
# HTTP status: the first control plane member has bootstrapped the cluster and
# passes the NLB healthcheck, so joining members can reach it.
set -euo pipefail

: "${API_URL:?API_URL must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

# shellcheck source=../../../scripts/lib/poll.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/poll.sh"

# -k: the serving certificate is the cluster's own CA. 000 means no answer.
# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until; sets its POLL_* vars
probe() {
  local code
  code=$(curl -4 -ks -o /dev/null -w '%{http_code}' --max-time 10 "$API_URL" 2>/dev/null || true)
  [ "$code" != "000" ] && [ -n "$code" ] && return 0
  POLL_STATUS=bootstrapping
  return 1
}

rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
if [ "$rc" -ne 0 ]; then
  {
    echo "ERROR: the Kubernetes API does not answer at $API_URL."
    echo "Either the first control plane member failed to bootstrap, or api_cidrs does not admit this machine."
    echo "Check the member through the jumphost (ssh.sh needs the outputs; the pool member's address is in the Exoscale portal)."
  } >&2
fi
exit "$rc"
