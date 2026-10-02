#!/usr/bin/env bash
# Read-only check: lists evroc objects labelled elemental-cluster=<cluster_name> through the evroc CLI.
#   tools/leftovers/evroc.sh <cluster_name> [--region R] [--project P] [--all]
# Credentials: evroc login, EVROC_CONFIG_FILE or EVROC_*. Exit: 0 nothing live, 1 found, 2 usage,
# 3 inconclusive. Rationale: docs/providers/evroc.md#leftover-check.
set -euo pipefail

# "<module resource type>|<evroc CLI words>". evroc_hotswap_disk_attachment has no labels, so it is not listed.
EVROC_TYPES='evroc_virtual_machine|compute virtualmachine
evroc_disk|compute disk
evroc_snapshot|compute snapshot
evroc_placement_group|compute placementgroup
evroc_public_ip|networking publicip
evroc_security_group|networking securitygroup
evroc_subnet|networking subnet
evroc_vpc|networking virtualprivatecloud
evroc_loadbalancer|loadbalancer loadbalancer
evroc_lb_backend_pool|loadbalancer backendpool
evroc_lb_backend_service|loadbalancer backendservice
evroc_lb_l4_route|loadbalancer l4route'

# shellcheck source=../../scripts/lib/leftovers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/leftovers.sh"
LO_USAGE="tools/leftovers/evroc.sh <cluster_name> [--region R] [--project P] [--all]"
LO_FLAGS="region project"

# Type list for the tests.
if [ "${1:-}" = --list-types ]; then
  printf '%s\n' "$EVROC_TYPES" | cut -d'|' -f1
  exit 0
fi

lo_init "$@"
lo_need evroc jq

cfg_args=()
[ -z "${EVROC_CONFIG_FILE:-}" ] || cfg_args=(--config "$EVROC_CONFIG_FILE")
if [ -z "${EVROC_CONFIG_FILE:-}" ] && [ ! -f "$HOME/.evroc/config.yaml" ] &&
  [ -z "${EVROC_TOKEN:-}${EVROC_REFRESH_TOKEN:-}${EVROC_SERVICE_ACCOUNT_SECRET:-}${EVROC_PASSWORD:-}" ]; then
  lo_inconclusive "no evroc credentials: run 'evroc login' or set EVROC_* (see docs/providers/evroc.md)"
fi
[ -z "$LO_REGION" ] || export EVROC_REGION="$LO_REGION"
[ -z "$LO_PROJECT" ] || export EVROC_PROJECT="$LO_PROJECT"
LO_SCOPE="project ${EVROC_PROJECT:-from login}, region ${EVROC_REGION:-from login}"

# Items of a response: {"items":[...]}, an array, or concatenated objects.
ITEMS='[.[] | if type == "array" then .[]
         elif type == "object" and has("items") then (.items // [])[] else . end]'

tab=$(printf '\t')
while IFS='|' read -r type words; do
  # shellcheck disable=SC2086  # words is a fixed, space-separated command path
  if ! evroc ${cfg_args[@]+"${cfg_args[@]}"} $words list -l "elemental-cluster=$LO_CLUSTER" -o json \
    </dev/null >"$LO_TMP/out" 2>"$LO_TMP/err"; then
    lo_inconclusive "evroc $words list failed: $(head -n 3 "$LO_TMP/err" | tr '\n' ' ')"
  fi
  # The CLI already applied the selector. Items without the label at the expected path mean the
  # path is wrong, not that they are unrelated; items with another cluster's label are dropped.
  unlabelled=$(jq -rs "$ITEMS | map(select(((.metadata.userLabels // {})[\"elemental-cluster\"]) == null)) | length" \
    "$LO_TMP/out" 2>"$LO_TMP/err") || lo_inconclusive "evroc $words list: unreadable JSON"
  [ "$unlabelled" -eq 0 ] ||
    lo_inconclusive "evroc $words list returned $unlabelled item(s) without .metadata.userLabels[\"elemental-cluster\"]; label path unverified ($type)"
  if ! jq -rs --arg c "$LO_CLUSTER" "$ITEMS"'
      | .[] | select(.metadata.userLabels["elemental-cluster"] == $c)
      | [.metadata.id // .metadata.name,
         (.spec.placement.zone // .spec.zone // "-"),
         (.metadata.userLabels["elemental-created"] // "-")] | @tsv' \
    "$LO_TMP/out" >"$LO_TMP/found" 2>"$LO_TMP/err"; then
    lo_inconclusive "evroc $words list: unreadable JSON"
  fi
  # Objects being deleted stay listed until gone and are still billed: always LIVE.
  while IFS="$tab" read -r id zone created; do
    [ -n "$id" ] || continue
    lo_row LIVE "$type" "$id" "zone=$zone" "$created"
  done <"$LO_TMP/found"
done <<EOF
$EVROC_TYPES
EOF

lo_finish
