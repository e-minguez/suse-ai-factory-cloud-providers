#!/usr/bin/env bash
# Adds a local route for each address given (load balancers that deliver
# packets with their own address as destination). Control planes only.
# Usage: local-routes.sh [--after-server] <ipv4>...
set -euo pipefail

log() { echo "[local-routes] $*"; }

wait_server=false
if [ "${1:-}" = "--after-server" ]; then
  wait_server=true
  shift
fi

# Agents run the same image: do nothing there.
NODETYPE=""
# shellcheck disable=SC1091
[ -r /var/lib/elemental/runtime.env ] && . /var/lib/elemental/runtime.env
if [ "$NODETYPE" != "server" ]; then
  log "not a control plane, nothing to do"
  exit 0
fi

# Every 2 s, without limit: rke2-server restarts until it joins, and a control
# plane without the route gets no load balancer traffic (it fails the health check).
if $wait_server; then
  n=0
  until systemctl is-active --quiet rke2-server.service; do
    n=$((n + 1))
    [ $((n % 150)) -ne 0 ] || log "waiting for rke2-server to be active"
    sleep 2
  done
fi

# Interface holding the default route, up to 2 minutes.
dev=""
for _ in $(seq 60); do
  dev=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  [ -n "$dev" ] && break
  sleep 2
done
[ -n "$dev" ] || { log "no default route"; exit 1; }

for ip in "$@"; do
  ip route replace to local "$ip" dev "$dev" proto 66
  log "local route $ip dev $dev"
done
