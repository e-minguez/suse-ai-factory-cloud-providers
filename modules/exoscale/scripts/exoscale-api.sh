#!/usr/bin/env bash
# Signed Exoscale API reads for Terraform's external data source: stdin is the
# query (JSON object of strings), stdout a JSON object of strings. No data
# source covers these reads. Needs curl, jq, openssl.
#
# Query keys: mode, zone, api_key, api_secret, and per mode:
#   check    types (comma-separated family.size), cluster
#            -> types, quotas, existing (JSON-encoded strings)
#   members  pool_id, network_id
#            -> members (JSON-encoded list of {id, name, public_ip, private_ip})
set -euo pipefail

die() {
  echo "exoscale-api.sh: $*" >&2
  exit 1
}

query=$(cat)
q() { jq -r --arg k "$1" '.[$k] // ""' <<<"$query"; }

mode=$(q mode)
zone=$(q zone)
key=$(q api_key)
secret=$(q api_secret)
[ -n "$zone" ] || die "zone missing"
[ -n "$key" ] && [ -n "$secret" ] || die "exoscale_api_key / exoscale_api_secret missing"

# EXO2-HMAC-SHA256: "METHOD path", body, query values, header values, expiry.
api_get() {
  local path=$1 expires sig out
  expires=$(($(date +%s) + 600))
  sig=$(printf 'GET %s\n\n\n\n%s' "$path" "$expires" |
    openssl dgst -sha256 -hmac "$secret" -binary | openssl base64 -A)
  out=$(curl -sS --retry 2 -w '\n%{http_code}' "https://api-${zone}.exoscale.com${path}" \
    -H "Authorization: EXO2-HMAC-SHA256 credential=${key},expires=${expires},signature=${sig}") ||
    die "GET $path failed"
  [ "${out##*$'\n'}" = 200 ] || die "GET $path returned HTTP ${out##*$'\n'}: ${out%$'\n'*}"
  printf '%s' "${out%$'\n'*}"
}

case "$mode" in
  check)
    cluster=$(q cluster)
    types=$(q types)
    itypes=$(api_get /v2/instance-type)
    quotas=$(api_get /v2/quota)
    instances=$(api_get /v2/instance)
    nlbs=$(api_get /v2/load-balancer)
    # The signed list omits types the organization may not use.
    jq -n -c --arg types "$types" --arg cluster "$cluster" --arg zone "$zone" \
      --argjson it "$itypes" --argjson qu "$quotas" --argjson in "$instances" --argjson lb "$nlbs" '
      ($it["instance-types"] // []) as $all
      | ($all | map({key: .id, value: .}) | from_entries) as $byid
      | [($in.instances // [])[] | select((.labels // {})["elemental-cluster"] == $cluster)] as $mine
      | {
          types: ($types | split(",") | map(select(. != "")) | unique | map(
            . as $t | ($t | split(".")) as $p
            | ([$all[] | select(.family == $p[0] and .size == $p[1])][0]) as $m
            | {key: $t, value: {
                listed: ($m != null),
                in_zone: ($m != null and (($m.zones // []) | index($zone)) != null),
                gpus: ($m.gpus // 0)
              }}) | from_entries | tojson),
          quotas: (($qu.quotas // []) | map({key: .resource, value: {usage: .usage, limit: .limit}}) | from_entries | tojson),
          existing: ({
            instances: ($mine | length),
            gpus: ($mine | map($byid[.["instance-type"].id] // {}) | map(select((.gpus // 0) > 0))
                   | group_by(.family) | map({key: .[0].family, value: (map(.gpus) | add)}) | from_entries),
            nlbs: ([($lb["load-balancers"] // [])[] | select((.labels // {})["elemental-cluster"] == $cluster)] | length)
          } | tojson)
        }'
    ;;

  members)
    pool_id=$(q pool_id)
    network_id=$(q network_id)
    pool=$(api_get "/v2/instance-pool/${pool_id}")
    net=$(api_get "/v2/private-network/${network_id}")
    instances=$(api_get /v2/instance)
    jq -n -c --argjson pool "$pool" --argjson net "$net" --argjson in "$instances" '
      (($net.leases // []) | map({key: .["instance-id"], value: .ip}) | from_entries) as $lease
      | ([($pool.instances // [])[].id]) as $ids
      | {members: ([($in.instances // [])[] | select(.id as $i | $ids | index($i))
          | {id, name, public_ip: (.["public-ip"] // null), private_ip: ($lease[.id] // null)}]
          | sort_by(.name) | tojson)}'
    ;;

  *) die "unknown mode: $mode" ;;
esac
