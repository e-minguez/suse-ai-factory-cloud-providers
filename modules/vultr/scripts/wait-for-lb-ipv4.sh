#!/usr/bin/env bash
# Creation-time local-exec of each vultr_load_balancer (loadbalancer.tf), run on
# the operator's machine. The provider can return before the LB has a public
# IPv4; the address is baked into the image, so creation waits for it.
# Needs curl and jq.
set -euo pipefail

: "${LB_ID:?LB_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

if [ -z "${VULTR_API_KEY:-}" ]; then
  echo "ERROR: VULTR_API_KEY is not set (Terraform passes vultr_api_key)." >&2
  exit 1
fi

# shellcheck source=../../../scripts/lib/poll.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/poll.sh"

# -4: an IP-restricted key gets 401 over IPv6. API errors are retried until
# the timeout; the LB exists, the API only has to answer once.
# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until; sets its POLL_* vars
probe() {
  local body ipv4
  # The key goes in on stdin (curl config), not in argv, so it stays out of `ps`.
  body=$(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY" |
    curl -4 -fsS -K - --max-time 10 \
      "https://api.vultr.com/v2/load-balancers/$LB_ID" 2>/dev/null || true)
  ipv4=$(printf '%s' "$body" | jq -r '.load_balancer.ipv4 // empty' 2>/dev/null || true)
  if [ -n "$ipv4" ]; then
    POLL_DETAIL="ipv4=$ipv4"
    return 0
  fi
  POLL_STATUS=no_ipv4
  return 1
}

rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "ERROR: load balancer $LB_ID has no IPv4. The resource is tainted and will be replaced on the next apply." >&2
fi
exit "$rc"
