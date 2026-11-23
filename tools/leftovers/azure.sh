#!/usr/bin/env bash
# Read-only check: Azure resources tagged elemental-cluster=<name> (whole subscription), the
# resource group <name> and everything in it (catches untagged leftovers such as NICs, disks and
# public IPs that outlive a VM). Deletes nothing.
LO_USAGE="azure.sh <cluster_name> [--project SUBSCRIPTION] [--all]   (subscription falls back to the az default)"
LO_FLAGS="project"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/leftovers.sh"
lo_init "$@"
lo_need az jq

CLUSTER=$LO_CLUSTER
TMP=$LO_TMP
case "$LO_PROJECT" in *[!A-Za-z0-9._-]*) lo_usage_error "invalid subscription: $LO_PROJECT" ;; esac
SUB_ARGS=()
LO_SCOPE="default subscription"
if [ -n "$LO_PROJECT" ]; then
  SUB_ARGS=(--subscription "$LO_PROJECT")
  LO_SCOPE="subscription $LO_PROJECT"
fi

# az_cli <args>: the CLI with the subscription and JSON output; stderr in $TMP/err.
az_cli() { az "$@" "${SUB_ARGS[@]+"${SUB_ARGS[@]}"}" -o json 2>"$TMP/err" </dev/null; }
az_err() { grep -m 1 -E 'ERROR|Error|error' "$TMP/err" || grep -m 1 . "$TMP/err" || true; }

# id, type, name, created (elemental-created tag, else the API timestamp)
ROWS_JQ='.[] | [.id, (.type // "unknown"), (.name // "-"),
  ((.tags // {})["elemental-created"] // .createdTime // "-")]
  | map(tostring | gsub("[\t\n]"; " ")) | @tsv'

: >"$TMP/seen"
add_rows() { # <json file> <state>
  jq -r "$ROWS_JQ" "$1" >"$TMP/found" 2>"$TMP/err" || lo_inconclusive "output unreadable: $(az_err)"
  while IFS="$(printf '\t')" read -r id type name created; do
    [ -n "$id" ] || continue
    grep -qxF "$id" "$TMP/seen" && continue
    printf '%s\n' "$id" >>"$TMP/seen"
    lo_row "$2" "azure:$type" "$id" "$name" "$created"
  done <"$TMP/found"
}

# Tagged resources, any resource group (covers a user-supplied resource_group_name).
az_cli resource list --tag "elemental-cluster=$CLUSTER" >"$TMP/tagged.json" ||
  lo_inconclusive "resource list failed: $(az_err)"
add_rows "$TMP/tagged.json" LIVE

# The resource group named like the cluster and what is in it. Without the tag it may be
# unrelated: group and contents are UNKNOWN.
if az_cli group show --name "$CLUSTER" >"$TMP/rg.json"; then
  RG_ID=$(jq -r '.id' "$TMP/rg.json")
  RG_STATE=UNKNOWN
  jq -e --arg c "$CLUSTER" '(.tags // {})["elemental-cluster"] == $c' "$TMP/rg.json" >/dev/null && RG_STATE=LIVE
  if ! grep -qxF "$RG_ID" "$TMP/seen"; then
    printf '%s\n' "$RG_ID" >>"$TMP/seen"
    lo_row "$RG_STATE" azure:resourceGroup "$RG_ID" "$CLUSTER" \
      "$(jq -r '(.tags // {})["elemental-created"] // "-"' "$TMP/rg.json")"
  fi
  if az_cli resource list --resource-group "$CLUSTER" >"$TMP/inrg.json"; then
    add_rows "$TMP/inrg.json" "$RG_STATE"
  else
    lo_row UNKNOWN azure:resource "$CLUSTER/*" "list failed" -
  fi
elif grep -qE 'ResourceGroupNotFound|could not be found' "$TMP/err"; then
  :
else
  lo_inconclusive "group show failed: $(az_err)"
fi

lo_finish
