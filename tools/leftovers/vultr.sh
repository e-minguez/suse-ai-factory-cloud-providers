#!/usr/bin/env bash
# Read-only leftover check for one cluster on Vultr. Needs curl, jq and VULTR_API_KEY.
# shellcheck disable=SC2016  # jq programs sit in single quotes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$ROOT/scripts/lib/leftovers.sh"

# Name suffixes of the objects without tags; each must appear in
# modules/vultr/*.tf (loadbalancer, network, firewall; checked by the test).
LB_SUFFIXES="-api-lb -ingress-lb"
VPC_SUFFIX="-vpc"
NAT_SUFFIX="-nat"
FIREWALL_SUFFIXES="-jumphost -control-plane -agent-cloud"
# Snapshot description is <cluster>-<build_id>, build_id = 12 hex characters
# (modules/vultr/image.tf, set by wait-for-snapshot.sh).
SNAPSHOT_ID_REGEX='^[0-9a-f]{12}$'

API_BASE="${VULTR_API_BASE:-https://api.vultr.com/v2}"
LO_USAGE="tools/leftovers/vultr.sh <cluster_name> [--all] [-h]  (VULTR_API_KEY in the environment)"
LO_FLAGS=""
lo_init "$@"
lo_need curl jq
[ -n "${VULTR_API_KEY:-}" ] || lo_usage_error "VULTR_API_KEY is not set"

# api_get <path> <outfile> [curl args...]: prints the HTTP code (000 if curl failed; its stderr
# is in $LO_TMP/curl.err). The key goes to curl on stdin so it never shows in `ps`.
api_get() {
  local path=$1 out=$2
  shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY" |
    curl -sS -K - -o "$out" -w '%{http_code}' --max-time 60 "$@" "$API_BASE$path" 2>"$LO_TMP/curl.err" || true
}

# http_fail <what> <code>: inconclusive, with curl's error if there was one.
http_fail() {
  lo_inconclusive "$1 returned HTTP ${2:-000}${3:+: $3}"
}

code=$(api_get /account "$LO_TMP/account")
[ "$code" = 200 ] || http_fail "credential check GET /account" "$code" "$(head -n 1 "$LO_TMP/curl.err")"

# list_all <path> <jq-expr-yielding-items> <outfile>: follows meta.links.next.
list_all() {
  local path=$1 expr=$2 out=$3 cursor="" page=0 code next
  local -a args
  : >"$out"
  while :; do
    args=(-G --data-urlencode per_page=500)
    [ -z "$cursor" ] || args+=(--data-urlencode "cursor=$cursor")
    code=$(api_get "$path" "$LO_TMP/page" "${args[@]}")
    [ "$code" = 200 ] || http_fail "GET $path" "$code" "$(head -n 1 "$LO_TMP/curl.err")"
    jq -c "$expr" "$LO_TMP/page" >>"$out" 2>/dev/null || lo_inconclusive "GET $path returned unexpected JSON"
    next=$(jq -r '.meta.links.next // ""' "$LO_TMP/page" 2>/dev/null) || lo_inconclusive "GET $path returned unexpected JSON"
    [ -n "$next" ] || break
    page=$((page + 1))
    [ "$page" -lt 1000 ] || lo_inconclusive "GET $path: pagination does not end"
    cursor=$next
  done
}

# names <suffix...>: JSON array of "<cluster><suffix>".
names() {
  local s args=()
  for s in "$@"; do args+=("$LO_CLUSTER$s"); done
  jq -nc '$ARGS.positional' --args "${args[@]}"
}

# emit <type> <names-json> <jq-filter>: the filter selects from $LO_TMP/items
# (has $cluster and $names) and yields {id, name, created}. Appends to $LO_TMP/found.
emit() {
  local type=$1 nm=$2 filter=$3 id name created
  jq -r --arg cluster "$LO_CLUSTER" --argjson names "$nm" \
    "$filter | [(.id // \"-\"), ((.name // \"\") | if . == \"\" then \"-\" else . end), ((.created // \"\") | if . == \"\" then \"-\" else . end)] | @tsv" \
    "$LO_TMP/items" >"$LO_TMP/emitted" 2>"$LO_TMP/jq.err" ||
    lo_inconclusive "unexpected JSON in the $type list: $(head -n 1 "$LO_TMP/jq.err")"
  while IFS=$'\t' read -r id name created; do
    printf '%s\t%s\t%s\t%s\n' "$type" "$id" "$name" "$created"
  done <"$LO_TMP/emitted" >>"$LO_TMP/found"
}

: >"$LO_TMP/found"

# By tag: instances, bare metals.
TAGGED='select((.tags // []) | index("elemental-cluster=" + $cluster))
  | {id: .id, name: .label,
     created: (((.tags // []) | map(select(startswith("elemental-created="))) | first // "") | ltrimstr("elemental-created="))}'
list_all /instances '(.instances // []) | .[]' "$LO_TMP/items"
emit vultr_instance '[]' "$TAGGED"
list_all /bare-metals '(.bare_metals // []) | .[]' "$LO_TMP/items"
emit vultr_bare_metal_server '[]' "$TAGGED"

# By exact name.
# shellcheck disable=SC2086  # word splitting of the suffix lists is intended
{
  list_all /load-balancers '(.load_balancers // []) | .[]' "$LO_TMP/items"
  emit vultr_load_balancer "$(names $LB_SUFFIXES)" 'select(.label as $l | $names | index($l)) | {id: .id, name: .label}'

  list_all /firewalls '(.firewall_groups // []) | .[]' "$LO_TMP/items"
  emit vultr_firewall_group "$(names $FIREWALL_SUFFIXES)" 'select(.description as $d | $names | index($d)) | {id: .id, name: .description}'

  list_all /vpcs '(.vpcs // []) | .[]' "$LO_TMP/items"
  emit vultr_vpc "$(names $VPC_SUFFIX)" 'select(.description as $d | $names | index($d)) | {id: .id, name: .description}'
}

list_all /snapshots '(.snapshots // []) | .[]' "$LO_TMP/items"
emit vultr_snapshot "$(jq -nc --arg p "$LO_CLUSTER-" --arg re "$SNAPSHOT_ID_REGEX" '[$p, $re]')" \
  'select((.description // "") as $d | $names[0] as $p
      | ($d | startswith($p)) and ($d | ltrimstr($p) | test($names[1])))
    | {id: .id, name: .description}'

# NAT gateways live under a VPC (GET /vpcs/{id}/nat-gateway): look in the VPCs matched above.
vpcs=$(awk -F'\t' '$1 == "vultr_vpc" { print $2 }' "$LO_TMP/found")
nat_names=$(names "$NAT_SUFFIX")
for vpc in $vpcs; do
  list_all "/vpcs/$vpc/nat-gateway" '(.nat_gateways // (if .nat_gateway then [.nat_gateway] else [] end)) | .[]' "$LO_TMP/items"
  emit vultr_nat_gateway "$nat_names" 'select((.tag == ("elemental-cluster=" + $cluster))
      or ((.tags // []) | index("elemental-cluster=" + $cluster))
      or (.label as $l | $names | index($l)))
    | {id: .id, name: .label}'
done

# Every row comes from a live list call, so it exists. Status stays LIVE while a
# snapshot is not complete or an object is being deleted (still billed).
while IFS=$'\t' read -r type id name created; do
  [ "$created" = "-" ] && created=""
  lo_row LIVE "$type" "$id" "$name" "$created"
done <"$LO_TMP/found"

lo_finish
