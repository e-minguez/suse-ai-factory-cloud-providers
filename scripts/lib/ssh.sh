#!/usr/bin/env bash
# Sourced by scripts/{ssh,kubeconfig,build-logs}.sh. Builds a throwaway
# ssh_config + known_hosts from `terraform output -json`.
# Nodes without a private_ip (no VPC address exposed) are reached on public_ip.
# Login user: nodes[*].ssh_user, overridden by -u or NODE_USERNAME. build_status.hosts
# entries that are not nodes get a Host entry behind the jumphost.
#
#   ssh_parse_common <opt> [arg]   handle -C/--known-hosts/-u; sets SSH_SHIFT (0 = not ours)
#   ssh_setup                      after parsing: fills SSH_TMP SSH_CONFIG SSH_KNOWN_HOSTS TF_JSON
#   ssh_run <host> [cmd...]        ssh with the generated config
#
# Before ssh_setup: SSH_STATE_FALLBACK=build also reads state when build_status is
# null; SSH_EXTRA_HOST adds one address behind the jumphost.
#
# Sets an EXIT trap that removes the temp dir. Needs jq and terraform.

SSH_DIR="${SSH_DIR:-.}"
SSH_KNOWN_HOSTS_OPT=""
SSH_NODE_USER="${NODE_USERNAME:-}"
SSH_STATE_FALLBACK="${SSH_STATE_FALLBACK:-}"
SSH_EXTRA_HOST="${SSH_EXTRA_HOST:-}"
SSH_TMP=""
SSH_CONFIG=""
SSH_KNOWN_HOSTS=""
TF_JSON=""

ssh_die() {
  echo "error: $*" >&2
  exit 1
}

ssh_cleanup() {
  [ -n "$SSH_TMP" ] && rm -rf "$SSH_TMP"
  return 0
}

# Common options: -C DIR, --known-hosts FILE, -u USER. Sets SSH_SHIFT to the
# number of args consumed (0 when $1 is not a common option).
ssh_parse_common() {
  SSH_SHIFT=0
  case "${1:-}" in
    -C | --known-hosts | -u)
      [ $# -ge 2 ] || ssh_die "$1 needs an argument"
      case "$1" in
        -C) SSH_DIR=$2 ;;
        --known-hosts) SSH_KNOWN_HOSTS_OPT=$2 ;;
        -u) SSH_NODE_USER=$2 ;;
      esac
      # shellcheck disable=SC2034 # read by the calling script
      SSH_SHIFT=2
      ;;
  esac
}

ssh_setup() {
  command -v jq >/dev/null 2>&1 || ssh_die "jq not found"
  command -v terraform >/dev/null 2>&1 || ssh_die "terraform not found"
  [ -d "$SSH_DIR" ] || ssh_die "not a directory: $SSH_DIR"
  case "$SSH_NODE_USER" in
    *[!A-Za-z0-9._-]*) ssh_die "invalid node username: $SSH_NODE_USER" ;;
  esac

  local abs
  abs=$(cd "$SSH_DIR" && pwd)
  TF_JSON=$(cd "$SSH_DIR" && terraform output -json) || ssh_die "terraform output failed in $abs (apply first?)"
  ssh__state_fallback "$abs"
  if [ "$(jq length <<<"$TF_JSON")" = 0 ]; then
    ssh_die "no terraform outputs in $abs. Run from a cluster directory (examples/<provider> or clusters/<name>), or pass -C DIR."
  fi

  SSH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ssh-cfg.XXXXXX") || ssh_die "mktemp failed"
  trap ssh_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ -n "$SSH_KNOWN_HOSTS_OPT" ]; then
    SSH_KNOWN_HOSTS=$SSH_KNOWN_HOSTS_OPT
    (umask 077 && touch "$SSH_KNOWN_HOSTS") || ssh_die "cannot create $SSH_KNOWN_HOSTS"
  else
    SSH_KNOWN_HOSTS="$SSH_TMP/known_hosts"
    (umask 077 && : >"$SSH_KNOWN_HOSTS")
  fi
  SSH_CONFIG="$SSH_TMP/ssh_config"

  # Values land in an ssh_config: allow only host-like characters.
  jq -r --arg user "$SSH_NODE_USER" --arg kh "$SSH_KNOWN_HOSTS" --arg extra "$SSH_EXTRA_HOST" '
    def ok: if type == "string" and test("^[A-Za-z0-9._:-]+$") then . else error("unsafe or missing value: \(tojson)") end;
    (.jumphost.value // error("output jumphost missing")) as $j
    | (.nodes.value // {}) as $nodes
    | "Host jumphost\n  HostName \($j.public_ip | ok)\n  User \($j.ssh_user | ok)\n",
      ($nodes | to_entries[]
        | (if $user != "" then $user else (.value.ssh_user | ok) end) as $u
        | if .value.private_ip != null
          then "Host \(.key | ok)\n  HostName \(.value.private_ip | ok)\n  User \($u)\n  ProxyJump jumphost\n"
          else "Host \(.key | ok)\n  HostName \(.value.public_ip | ok)\n  User \($u)\n" end),
      (((.build_status.value.hosts // []) + (if $extra != "" then [$extra] else [] end) | unique[]) as $h
        | select($h != "jumphost" and $h != $j.public_ip and $h != $j.private_ip and ($nodes | has($h) | not))
        | "Host \($h | ok)\n  HostName \($h)\n  User \(if $user != "" then $user else $j.ssh_user end)\n  ProxyJump jumphost\n"),
      "Host *\n  UserKnownHostsFile \"\($kh)\"\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking accept-new\n  UpdateHostKeys no\n  ConnectTimeout 15"
  ' <<<"$TF_JSON" >"$SSH_CONFIG" || ssh_die "cannot build ssh_config from terraform outputs"
}

# Outputs reach the state file only when a later resource completes, so during
# an apply they can be missing or left from the previous build. A module's
# terraform_data.build_access holds the current jumphost and build hosts: use it
# when the outputs lack the jumphost or carry another build_id.
ssh__state_fallback() {
  local need state access merged
  need=$(jq -r --arg mode "$SSH_STATE_FALLBACK" '(.jumphost.value.public_ip // null) == null
    or ($mode == "build" and (.build_status.value // null) == null)' <<<"$TF_JSON")
  [ "$need" = true ] || return 0
  state=$(cd "$1" && terraform show -json 2>/dev/null) || return 0
  access=$(jq -c 'first(.. | objects | select(.mode? == "managed" and .type? == "terraform_data"
    and .name? == "build_access") | .values.input) // empty' <<<"$state")
  [ -n "$access" ] || return 0
  merged=$(jq --argjson a "$access" '((.image.value.build_id // null) != $a.build_id) as $stale
    | if $stale or (.jumphost.value.public_ip // null) == null then .jumphost = {value: $a.jumphost} else . end
    | if $stale then .build_status = {value: $a.build_status} else . end' <<<"$TF_JSON")
  [ "$(jq -S . <<<"$merged")" != "$(jq -S . <<<"$TF_JSON")" ] || return 0
  TF_JSON=$merged
  echo "note: outputs incomplete or stale (apply running?); using terraform_data.build_access from state" >&2
}

ssh_run() {
  ssh -F "$SSH_CONFIG" "$@"
}
