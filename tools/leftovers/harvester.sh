#!/usr/bin/env bash
# Read-only leftover check for one cluster in one Harvester namespace. Needs kubectl and
# jq; credentials are the kubeconfig given with --kubeconfig, else KUBECONFIG or
# ~/.kube/config (kubectl defaults).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$ROOT/scripts/lib/leftovers.sh"

LO_USAGE="tools/leftovers/harvester.sh <cluster_name> --namespace <ns> [--kubeconfig <path>] [--kubecontext <ctx>] [--all] [-h]"
LO_FLAGS="namespace kubeconfig kubecontext"
lo_init "$@"
[ -n "$LO_NAMESPACE" ] || lo_usage_error "--namespace is required"
lo_need kubectl jq
[ -z "$LO_KUBECONFIG" ] || [ -r "$LO_KUBECONFIG" ] || lo_inconclusive "kubeconfig not readable: $LO_KUBECONFIG"
LO_SCOPE="namespace $LO_NAMESPACE"

kc=(kubectl)
[ -z "$LO_KUBECONFIG" ] || kc+=(--kubeconfig "$LO_KUBECONFIG")
[ -z "$LO_KUBECONTEXT" ] || kc+=(--context "$LO_KUBECONTEXT")

# list <resource> <type>: every labelled object is a live API read, so it exists.
list() {
  local res=$1 type=$2 id name created
  "${kc[@]}" get "$res" -n "$LO_NAMESPACE" -l "elemental-cluster=$LO_CLUSTER" -o json \
    >"$LO_TMP/page" 2>"$LO_TMP/err" ||
    lo_inconclusive "kubectl get $res failed: $(head -n 1 "$LO_TMP/err")"
  jq -r '.items[] | [.metadata.uid, .metadata.name,
      (.metadata.labels["elemental-created"] // .metadata.creationTimestamp // "")] | @tsv' \
    "$LO_TMP/page" >"$LO_TMP/items" 2>"$LO_TMP/err" ||
    lo_inconclusive "unexpected JSON in the $res list: $(head -n 1 "$LO_TMP/err")"
  while IFS=$'\t' read -r id name created; do
    lo_row LIVE "$type" "$id" "$name" "$created"
  done <"$LO_TMP/items"
}

list virtualmachines.kubevirt.io harvester_virtualmachine
list persistentvolumeclaims harvester_volume
list virtualmachineimages.harvesterhci.io harvester_image
list secrets harvester_cloudinit_secret

lo_finish
