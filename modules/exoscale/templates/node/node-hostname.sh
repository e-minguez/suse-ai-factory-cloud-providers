#!/usr/bin/env bash
# Sets the hostname and the RKE2 node-name from the metadata local-hostname:
# control plane pool members share one Ignition entry with a placeholder name.
# On standalone nodes the metadata name equals the Ignition hostname.
set -euo pipefail

CONFIG_DIR="/etc/rancher/rke2/config.yaml.d"
URL="http://169.254.169.254/latest/meta-data/local-hostname"

log() { echo "[node-hostname] $*"; }

name=""
for _ in $(seq 1 60); do
  name=$(curl -fsS -m 5 "$URL" 2>/dev/null || true)
  [ -n "$name" ] && break
  sleep 2
done

if [ -z "$name" ]; then
  log "ERROR: no local-hostname from $URL after 120s"
  exit 1
fi
case "$name" in
  *[!A-Za-z0-9.-]*)
    log "ERROR: unexpected local-hostname: $name"
    exit 1
    ;;
esac

hostnamectl set-hostname "$name"
mkdir -p "$CONFIG_DIR"
printf 'node-name: %s\n' "$name" >"$CONFIG_DIR/98-node-name.yaml"
log "hostname and node-name: $name"
