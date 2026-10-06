#!/usr/bin/env bash
# Read-only leftover check for one cluster in one Exoscale zone. Needs curl, jq,
# openssl and EXOSCALE_API_KEY / EXOSCALE_API_SECRET.
# shellcheck disable=SC2016  # jq programs sit in single quotes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$ROOT/scripts/lib/leftovers.sh"

# Name suffixes of the objects without labels (security groups and
# anti-affinity groups are global); each must appear in modules/exoscale/*.tf
# (checked by the test).
SG_SUFFIXES="-jumphost -control-plane -agent"
AAG_SUFFIX="-control-plane"
# Template name is <cluster>-<build_id>, build_id = 12 hex characters
# (modules/exoscale/image.tf).
TEMPLATE_ID_REGEX='^[0-9a-f]{12}$'

LO_USAGE="tools/leftovers/exoscale.sh <cluster_name> [--region <zone>] [--all] [-h]  (EXOSCALE_API_KEY and EXOSCALE_API_SECRET in the environment; zone defaults to de-fra-1)"
LO_FLAGS="region"
lo_init "$@"
lo_need curl jq openssl
[ -n "${EXOSCALE_API_KEY:-}" ] || lo_usage_error "EXOSCALE_API_KEY is not set"
[ -n "${EXOSCALE_API_SECRET:-}" ] || lo_usage_error "EXOSCALE_API_SECRET is not set"
ZONE=${LO_REGION:-de-fra-1}
LO_SCOPE=$ZONE
API_BASE="${EXOSCALE_API_BASE:-https://api-$ZONE.exoscale.com}"

# api_get <path>[?k=v&...] <outfile>: prints the HTTP code (000 if curl failed;
# its stderr is in $LO_TMP/curl.err). EXO2-HMAC-SHA256: "GET path", body, query
# values sorted by name, header values, expiry. The signature goes to curl on
# stdin so it never shows in `ps`.
api_get() {
  local url=$1 out=$2 path query="" names="" values="" k v expires sig pragma=""
  path=${url%%\?*}
  [ "$path" = "$url" ] || query=${url#*\?}
  if [ -n "$query" ]; then
    while IFS='=' read -r k v; do
      names="${names:+$names;}$k" values="$values$v"
    done < <(tr '&' '\n' <<<"$query" | sort)
    pragma="signed-query-args=$names,"
  fi
  expires=$(($(date +%s) + 600))
  sig=$(printf 'GET %s\n\n%s\n\n%s' "$path" "$values" "$expires" |
    openssl dgst -sha256 -hmac "$EXOSCALE_API_SECRET" -binary | openssl base64 -A)
  printf 'header = "Authorization: EXO2-HMAC-SHA256 credential=%s,%sexpires=%s,signature=%s"\n' \
    "$EXOSCALE_API_KEY" "$pragma" "$expires" "$sig" |
    curl -sS -K - -o "$out" -w '%{http_code}' --max-time 60 "$API_BASE/v2$url" 2>"$LO_TMP/curl.err" || true
}

http_fail() {
  lo_inconclusive "$1 returned HTTP ${2:-000}${3:+: $3}"
}

code=$(api_get /quota "$LO_TMP/quota")
[ "$code" = 200 ] || http_fail "credential check GET /v2/quota" "$code" "$(head -n 1 "$LO_TMP/curl.err")"

# list <path> <jq-expr-yielding-items>: items into $LO_TMP/items (no pagination
# in these list calls).
list() {
  local code
  code=$(api_get "$1" "$LO_TMP/page")
  [ "$code" = 200 ] || http_fail "GET /v2$1" "$code" "$(head -n 1 "$LO_TMP/curl.err")"
  jq -c "$2" "$LO_TMP/page" >"$LO_TMP/items" 2>/dev/null || lo_inconclusive "GET /v2$1 returned unexpected JSON"
}

names() {
  local s args=()
  for s in "$@"; do args+=("$LO_CLUSTER$s"); done
  jq -nc '$ARGS.positional' --args "${args[@]}"
}

# emit <type> <names-json> <jq-filter>: the filter selects from $LO_TMP/items
# (has $cluster and $names) and yields {id, name, created}.
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

# By label: instances (pool members included), pools, NLBs, private networks.
LABELLED='select((.labels // {})["elemental-cluster"] == $cluster)
  | {id: .id, name: .name, created: ((.labels // {})["elemental-created"] // "")}'
list /instance '(.instances // []) | .[]'
emit exoscale_compute_instance '[]' "$LABELLED"
list /instance-pool '(.["instance-pools"] // []) | .[]'
emit exoscale_instance_pool '[]' "$LABELLED"
list /load-balancer '(.["load-balancers"] // []) | .[]'
emit exoscale_nlb '[]' "$LABELLED"
list /private-network '(.["private-networks"] // []) | .[]'
emit exoscale_private_network '[]' "$LABELLED"

# By exact name (no labels on these types).
# shellcheck disable=SC2086  # word splitting of the suffix list is intended
{
  list /security-group '(.["security-groups"] // []) | .[]'
  emit exoscale_security_group "$(names $SG_SUFFIXES)" 'select(.name as $n | $names | index($n)) | {id: .id, name: .name}'
}
list /anti-affinity-group '(.["anti-affinity-groups"] // []) | .[]'
emit exoscale_anti_affinity_group "$(names "$AAG_SUFFIX")" 'select(.name as $n | $names | index($n)) | {id: .id, name: .name}'

list '/template?visibility=private' '(.templates // []) | .[]'
emit exoscale_template "$(jq -nc --arg p "$LO_CLUSTER-" --arg re "$TEMPLATE_ID_REGEX" '[$p, $re]')" \
  'select((.name // "") as $n | $names[0] as $p
      | ($n | startswith($p)) and ($n | ltrimstr($p) | test($names[1])))
    | {id: .id, name: .name, created: (.["created-at"] // "")}'

# Every row comes from a live list call, so it exists.
while IFS=$'\t' read -r type id name created; do
  [ "$created" = "-" ] && created=""
  lo_row LIVE "$type" "$id" "$name" "$created"
done <"$LO_TMP/found"

lo_finish
