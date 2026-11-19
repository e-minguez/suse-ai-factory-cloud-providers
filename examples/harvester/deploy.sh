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

DEPLOY_PROVIDER=harvester
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$DEPLOY_LIB/deploy-common.sh"

# Suggests the leftover check after destroy; namespace and kubeconfig come from the var files.
deploy_after_destroy() {
  local namespace kubeconfig context
  local -a args
  namespace=$(deploy_var_string harvester_namespace)
  kubeconfig=$(deploy_var_string harvester_kubeconfig_path)
  context=$(deploy_var_string harvester_kubecontext)
  args=("$(deploy_cluster_name)")
  [ -z "$namespace" ] || args+=(--namespace "$namespace")
  [ -z "$kubeconfig" ] || args+=(--kubeconfig "$kubeconfig")
  [ -z "$context" ] || args+=(--kubecontext "$context")
  deploy_suggest_leftovers harvester "${args[@]}"
}

deploy_passes() {
  tf_pass "Deploy"
}

deploy_main "$@"
