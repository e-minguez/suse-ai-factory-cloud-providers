#!/usr/bin/env bash
# Deploys the evroc cluster in passes: image, then nodes, then build-disk reclaim.
# Usage: deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform plan args>]
# Also works through a symlink from a clusters/<name>/ directory.
set -euo pipefail

# Real path of this script (macOS has no readlink -f), to find the repo root.
DEPLOY_SELF="${BASH_SOURCE[0]}"
while [ -L "$DEPLOY_SELF" ]; do
  DEPLOY_LINK_DIR="$(cd "$(dirname "$DEPLOY_SELF")" && pwd)"
  DEPLOY_SELF="$(readlink "$DEPLOY_SELF")"
  case "$DEPLOY_SELF" in /*) ;; *) DEPLOY_SELF="$DEPLOY_LINK_DIR/$DEPLOY_SELF" ;; esac
done
DEPLOY_ROOT="$(cd "$(dirname "$DEPLOY_SELF")/../.." && pwd)"

# The libs work on $PWD: stay in the directory the script was invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"
DEPLOY_PROVIDER=evroc
DEPLOY_PASS_TOTAL=3
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$DEPLOY_ROOT/scripts/lib/deploy-common.sh"

# TEMPORARY (docs/workarounds.md): load-balancer writes can return 409; retry the pass.
tf_retry_on 'API error \(409\)' 3 "load-balancer conflict (409)"

# TEMPORARY (docs/workarounds.md, Terraform 1.16.4 crash): with EVROC_ADOPT_ON_CRASH=1, adopt
# objects a crashed apply left out of state; otherwise print how to find them.
deploy_on_crash() {
  local pass=$1 ready=true a
  local -a args=()
  [ "$pass" != "Build image" ] || ready=false
  if [ "${EVROC_ADOPT_ON_CRASH:-0}" != 1 ]; then
    echo "       List them: $DEPLOY_ROOT/tools/orphans/evroc -- -var=image_ready=$ready"
    echo "       Review orphan-imports.tf.proposed, rename it to imports.tf, re-run deploy.sh and"
    echo "       delete imports.tf afterwards. EVROC_ADOPT_ON_CRASH=1 does this on a crash unattended."
    return 1
  fi
  for a in ${DEPLOY_TF_ARGS[@]+"${DEPLOY_TF_ARGS[@]}"}; do
    [ "$a" = -auto-approve ] || args+=("$a")
  done
  "$DEPLOY_ROOT/tools/orphans/evroc" --adopt -- -var=image_ready=$ready ${args[@]+"${args[@]}"}
}

deploy_precheck() {
  [ -f "$HOME/.evroc/config.yaml" ] || deploy_die "$HOME/.evroc/config.yaml not found; run: evroc login"
}

# Suggests the leftover check after destroy. Region and project not in the var files come from the evroc login.
deploy_after_destroy() {
  local region project
  local -a args
  region=$(deploy_var_string region)
  project=$(deploy_var_string project)
  args=("$(deploy_cluster_name)")
  [ -z "$region" ] || args+=(--region "$region")
  [ -z "$project" ] || args+=(--project "$project")
  deploy_suggest_leftovers evroc "${args[@]}"
}

# True when state already holds a snapshot: the image handoff is done.
deploy_image_handed_off() {
  terraform output -json image 2>/dev/null |
    jq -e '[(.ids // {}) | to_entries[] | select(.value != null)] | length > 0' >/dev/null 2>&1
}

# Keeps a later bare `terraform apply` from reverting image_ready and replacing the nodes.
deploy_pin_image_ready() {
  printf '{\n  "image_ready": true\n}\n' >pass2.auto.tfvars.json
}

deploy_passes() {
  if deploy_image_handed_off; then
    if [ "$DEPLOY_REBUILD" = 1 ]; then
      tf__say "note: --rebuild builds a new image (image_ready=false destroys the snapshots; the nodes are replaced)."
    else
      # image_ready must stay true: going back through pass 1 would destroy the snapshots.
      # shellcheck disable=SC2034 # read by tf_pass
      DEPLOY_PASS_TOTAL=1
      tf__say "note: snapshots are in state; applying once with image_ready=true (--rebuild builds a new image)."
      tf_pass "Apply" -var=image_ready=true
      deploy_pin_image_ready
      return 0
    fi
  fi

  rm -f pass2.auto.tfvars.json
  tf_pass "Build image" -var=image_ready=false
  # keep_build_artifacts=true: the disks are the snapshot sources and are not deleted in the same apply.
  tf_pass "Create nodes" -var=image_ready=true -var=keep_build_artifacts=true
  deploy_pin_image_ready
  # Deletes the image-target disks unless keep_build_artifacts = true is set in terraform.tfvars.
  tf_pass "Reclaim build disks" -var=image_ready=true
}

deploy_main "$@"
