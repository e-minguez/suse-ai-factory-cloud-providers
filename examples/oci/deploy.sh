#!/usr/bin/env bash
# Single-pass deploy: deploy.sh [--rebuild] [--yes] [--wait] [-v|-q] [--destroy] [-- <tf args>]
set -euo pipefail

# Resolve symlinks portably (no readlink -f on macOS) before the cd: BASH_SOURCE may be relative.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
DEPLOY_LIB="$(cd "$(dirname "$src")/../../scripts/lib" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")"

DEPLOY_PROVIDER=oci
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$DEPLOY_LIB/deploy-common.sh"

# Destroy with keep_build_artifacts = true: the qcow2 is still in the bucket and Terraform
# cannot delete the non-empty bucket. Prints how to empty it first; never runs anything.
deploy_precheck() {
  local list name
  [ "$DEPLOY_DESTROY" = 1 ] || return 0
  list=$("$TF_BIN" state list 2>/dev/null) || return 0
  grep -qF 'oci_objectstorage_bucket.build' <<<"$list" || return 0
  ! grep -qF 'oci_objectstorage_object.qcow_cleanup' <<<"$list" || return 0
  name=$(deploy_cluster_name)-build
  printf 'note: the build bucket %s may still hold the qcow2 (keep_build_artifacts = true).\n' "$name"
  printf '      Destroy fails on a non-empty bucket; delete the objects first:\n'
  printf '      oci os object bulk-delete --bucket-name %s --prefix images/ --force\n' "$name"
}

# Suggests the leftover check after destroy; region and compartment come from the var files.
deploy_after_destroy() {
  local region compartment
  local -a args
  region=$(deploy_var_string region)
  compartment=$(deploy_var_string oci_compartment_ocid)
  args=("$(deploy_cluster_name)")
  [ -z "$region" ] || args+=(--region "$region")
  [ -z "$compartment" ] || args+=(--compartment "$compartment")
  deploy_suggest_leftovers oci "${args[@]}"
}

deploy_passes() {
  tf_pass "Deploy"
}

deploy_main "$@"
