#!/usr/bin/env bash
# Follow /var/log/elemental-factory.log on the image build host(s).
#
# Usage: build-logs.sh [-C DIR] [--known-hosts FILE] [-u USER] [--host NAME] [--no-follow]
#
# Run from a cluster directory (examples/<provider> or clusters/<name>), or pass
# -C DIR from anywhere. deploy.sh prints the full command.
#
# Uses output build_status; when it is null no build is running. During an apply
# the outputs may be missing or stale; then terraform_data.build_access in state
# is used. Default: every entry of build_status.hosts (prefixed when several).
# --host picks one host name or address from that list, a node name from
# `terraform output nodes`, or any IPv4 address reached through the jumphost.
set -euo pipefail

# Real path (macOS has no readlink -f). Through a clusters/<name>/ symlink, -C defaults to that directory.
HERE="${BASH_SOURCE[0]}"
while [ -L "$HERE" ]; do
  [ -n "${SSH_DIR:-}" ] || SSH_DIR="$(cd "$(dirname "$HERE")" && pwd)"
  link=$(readlink "$HERE")
  case "$link" in /*) HERE=$link ;; *) HERE="$(dirname "$HERE")/$link" ;; esac
done
HERE="$(cd "$(dirname "$HERE")" && pwd)"
# shellcheck source=lib/ssh.sh
. "$HERE/lib/ssh.sh"

host=""
follow=1
while [ $# -gt 0 ]; do
  ssh_parse_common "$@"
  if [ "$SSH_SHIFT" -gt 0 ]; then
    shift "$SSH_SHIFT"
    continue
  fi
  case "$1" in
    --host)
      [ $# -ge 2 ] || ssh_die "--host needs a name"
      host=$2
      shift 2
      ;;
    --no-follow) follow=0 && shift ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) ssh_die "unknown argument: $1" ;;
  esac
done

# A raw IPv4 --host outside the outputs is reached through the jumphost.
case "$host" in
  *[!0-9.]* | "") ;;
  *) SSH_EXTRA_HOST=$host ;;
esac
SSH_STATE_FALLBACK=build
ssh_setup

if [ "$(jq -r '.build_status.value == null' <<<"$TF_JSON")" = true ]; then
  if [ -z "$host" ]; then
    echo "no build running (build_status is null): image exists or nodes are not deployed" >&2
    exit 0
  fi
else
  jq -r '.build_status.value | "build: method=\(.method) \(.url_or_key)"' <<<"$TF_JSON" >&2
fi

# Build hosts as ssh_config aliases: the jumphost's own addresses map to "jumphost".
hosts=$(jq -r --arg host "$host" '.jumphost.value as $j
  | (if $host != "" then [$host] else (.build_status.value.hosts // []) end)[]
  | if . == $j.public_ip or . == $j.private_ip then "jumphost" else . end' <<<"$TF_JSON" | awk '!seen[$0]++')
[ -n "$hosts" ] || ssh_die "build_status.hosts is empty"

for h in $hosts; do
  grep -qxF "Host $h" "$SSH_CONFIG" || ssh_die "unknown host '$h'"
done

if [ "$follow" = 1 ]; then
  tail_args="-n +1 -F"
else
  tail_args="-n +1"
fi

# shellcheck disable=SC2086 # tail_args is a fixed word list
if [ "$(wc -w <<<"$hosts")" -eq 1 ]; then
  rc=0
  ssh_run "$hosts" tail $tail_args /var/log/elemental-factory.log || rc=$?
  exit "$rc"
fi

pids=()
for h in $hosts; do
  # shellcheck disable=SC2086
  { ssh_run "$h" tail $tail_args /var/log/elemental-factory.log 2>&1 | sed "s|^|[$h] |"; } &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=$?; done
exit "$rc"
