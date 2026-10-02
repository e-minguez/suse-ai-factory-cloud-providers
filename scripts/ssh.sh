#!/usr/bin/env bash
# ssh into a node or the jumphost with a throwaway ssh_config/known_hosts.
#
# Usage: ssh.sh [-C DIR] [--known-hosts FILE] [-u USER] <hostname|jumphost> [cmd...]
#        ssh.sh [-C DIR] [--known-hosts FILE] [-u USER] --config
#
# Run from a cluster directory (examples/<provider> or clusters/<name>), or pass
# -C DIR from anywhere. Node hostnames: `terraform output nodes` in that directory.
# Node login is nodes[*].ssh_user from the outputs; -u (env NODE_USERNAME) overrides it.
# --config prints the ssh_config for scp/rsync; use --known-hosts FILE to keep
# host keys, otherwise the referenced known_hosts is gone after this script exits.
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

print_config=0
while [ $# -gt 0 ]; do
  ssh_parse_common "$@"
  if [ "$SSH_SHIFT" -gt 0 ]; then
    shift "$SSH_SHIFT"
    continue
  fi
  case "$1" in
    --config) print_config=1 && shift ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) break ;;
  esac
done

ssh_setup

if [ "$print_config" = 1 ]; then
  cat "$SSH_CONFIG"
  exit 0
fi

[ $# -ge 1 ] || ssh_die "usage: ssh.sh <hostname|jumphost> [cmd...]"
target=$1
shift
grep -qxF "Host $target" "$SSH_CONFIG" || ssh_die "unknown host '$target' (see: terraform output nodes)"

rc=0
ssh_run "$target" "$@" || rc=$?
exit "$rc"
