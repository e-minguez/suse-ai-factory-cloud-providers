#!/usr/bin/env bash
# Fetch the RKE2 admin kubeconfig from the init node. Never run automatically.
#
# Usage: kubeconfig.sh [-C DIR] [--known-hosts FILE] [-u USER] [-o FILE] [--force]
#
# Run from a cluster directory (examples/<provider> or clusters/<name>), or pass
# -C DIR from anywhere. deploy.sh prints the full command.
#
# Default output is stdout. -o FILE creates FILE with mode 600 and refuses to
# overwrite without --force. The file is an admin credential: store it carefully.
# Reads /etc/rancher/rke2/rke2.yaml as the init node ssh_user (-u overrides;
# group-readable, no root needed) and rewrites server: to https://<api_host>:6443.
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

out=""
force=0
while [ $# -gt 0 ]; do
  ssh_parse_common "$@"
  if [ "$SSH_SHIFT" -gt 0 ]; then
    shift "$SSH_SHIFT"
    continue
  fi
  case "$1" in
    -o)
      [ $# -ge 2 ] || ssh_die "-o needs a file"
      out=$2
      shift 2
      ;;
    --force) force=1 && shift ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) ssh_die "unknown argument: $1" ;;
  esac
done

if [ -n "$out" ] && [ "$force" = 0 ] && { [ -e "$out" ] || [ -L "$out" ]; }; then
  ssh_die "$out exists; use --force to overwrite"
fi

ssh_setup

api_host=$(jq -r '.api_host.value // empty' <<<"$TF_JSON")
init_node=$(jq -r '[(.nodes.value // {}) | to_entries[] | select(.value.init == true) | .key] | first // empty' <<<"$TF_JSON")
[ -n "$api_host" ] || ssh_die "output api_host missing"
[ -n "$init_node" ] || ssh_die "no init node in output nodes"
case "$api_host" in
  *[!A-Za-z0-9._:-]*) ssh_die "unsafe api_host: $api_host" ;;
esac

raw=$(ssh_run "$init_node" cat /etc/rancher/rke2/rke2.yaml) || ssh_die "cannot read rke2.yaml on $init_node"
[ -n "$raw" ] || ssh_die "rke2.yaml is empty on $init_node"

# shellcheck disable=SC2001 # anchored regex, not a plain substitution
kubeconfig=$(sed "s|^\([[:space:]]*server:\).*|\1 https://${api_host}:6443|" <<<"$raw")

if [ -z "$out" ]; then
  printf '%s\n' "$kubeconfig"
  exit 0
fi

# Temp file in the target dir (mktemp is mode 600), then move into place.
umask 077
tmp=$(mktemp "${out}.XXXXXX") || ssh_die "cannot create file next to $out"
printf '%s\n' "$kubeconfig" >"$tmp"
chmod 600 "$tmp"
if [ "$force" = 1 ]; then
  mv -f "$tmp" "$out"
else
  if ! ln "$tmp" "$out" 2>/dev/null; then
    rm -f "$tmp"
    ssh_die "$out exists; use --force to overwrite"
  fi
  rm -f "$tmp"
fi
echo "wrote $out (mode 600)" >&2
