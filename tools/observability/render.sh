#!/usr/bin/env bash
# Render an optional observability manifest of this directory to stdout.
#
# Usage: render.sh <cluster-dir> <manifest> [KEY=VALUE...]
#
# Reads `terraform -chdir=<cluster-dir> output -json` (cluster_name, optional) and replaces
# every <PLACEHOLDER> in the manifest. Other values come from KEY=VALUE
# arguments, then from the environment:
#   SUSE_AI_NAMESPACE              default suse-private-ai
#   APPCO_DOCKERCONFIGJSON_BASE64  or APPCO_USERNAME + APPCO_PASSWORD
#                                  (+ APPCO_REGISTRY, default dp.apps.rancher.io)
# Fails when a placeholder is left. The output can hold credentials: pipe it to
# kubectl, never to a file. Needs terraform, jq, base64 and sed.
set -euo pipefail

die() { echo "render.sh: $*" >&2; exit 1; }

case "${1:-}" in
  -h | --help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
    ;;
esac
[ $# -ge 2 ] || die "usage: render.sh <cluster-dir> <manifest> [KEY=VALUE...]"
dir=$1
manifest=$2
shift 2
[ -d "$dir" ] || die "no such directory: $dir"
[ -f "$manifest" ] || die "no such manifest: $manifest"

declare -A vals=()
for kv in "$@"; do
  case "$kv" in
    [A-Z]*=*) vals[${kv%%=*}]=${kv#*=} ;;
    *) die "expected KEY=VALUE, got: ${kv%%=*}" ;;
  esac
done

# Value of KEY: argument, then environment, then empty.
val() {
  if [ -n "${vals[$1]+x}" ]; then
    printf '%s' "${vals[$1]}"
  else
    printf '%s' "${!1:-}"
  fi
}

tf_json=$(terraform -chdir="$dir" output -json) || die "terraform output failed in $dir"
cluster_name=$(jq -r '.cluster_name.value // empty' <<<"$tf_json")

# Escape a value for the replacement part of a sed s||| expression.
esc() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

docker_b64=$(val APPCO_DOCKERCONFIGJSON_BASE64)
user=$(val APPCO_USERNAME)
pass=$(val APPCO_PASSWORD)
if [ -z "$docker_b64" ] && [ -n "$user" ] && [ -n "$pass" ]; then
  registry=$(val APPCO_REGISTRY)
  docker_b64=$(jq -nc --arg r "${registry:-dp.apps.rancher.io}" --arg u "$user" --arg p "$pass" \
    '{auths: {($r): {username: $u, password: $p, auth: ("\($u):\($p)" | @base64)}}}' | base64 | tr -d '\n')
fi
ns=$(val SUSE_AI_NAMESPACE)

args=(-e "s|<SUSE_AI_NAMESPACE>|$(esc "${ns:-suse-private-ai}")|g")
[ -z "$cluster_name" ] || args+=(-e "s|<CLUSTER_NAME>|$(esc "$cluster_name")|g")
[ -z "$docker_b64" ] || args+=(-e "s|<APPCO_DOCKERCONFIGJSON_BASE64>|$(esc "$docker_b64")|g")
# Any other placeholder present in the manifest can be given as KEY=VALUE.
for k in "${!vals[@]}"; do
  args+=(-e "s|<$k>|$(esc "${vals[$k]}")|g")
done

out=$(sed "${args[@]}" "$manifest")
left=$(grep -oE '<[A-Z][A-Z0-9_]*>' <<<"$out" | sort -u | tr '\n' ' ' || true)
[ -z "$left" ] || die "unresolved placeholders: $left"
printf '%s\n' "$out"
