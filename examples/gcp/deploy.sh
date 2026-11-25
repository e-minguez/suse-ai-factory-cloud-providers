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

DEPLOY_PROVIDER=gcp
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$DEPLOY_LIB/deploy-common.sh"

# Suggests the leftover check after destroy; the project comes from the var files.
deploy_after_destroy() {
  local project
  local -a args
  project=$(deploy_var_string gcp_project)
  args=("$(deploy_cluster_name)")
  [ -z "$project" ] || args+=(--project "$project")
  deploy_suggest_leftovers gcp "${args[@]}"
}

deploy_passes() {
  tf_pass "Deploy"
}

deploy_main "$@"
