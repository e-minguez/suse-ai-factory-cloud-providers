#!/usr/bin/env bash
# Two-pass deploy: the control plane pool bootstraps with one init member,
# then switches to the join configuration and scales up. See
# docs/providers/exoscale.md#passes and docs/decisions/008-exoscale-module.md.
#   deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <tf args>]
set -euo pipefail

# Real path of this script, so it also works from a symlink in tools/multicluster.
src=${BASH_SOURCE[0]}
while [ -L "$src" ]; do
  d=$(cd -P "$(dirname "$src")" && pwd)
  src=$(readlink "$src")
  case "$src" in /*) ;; *) src=$d/$src ;; esac
done
LIB=$(cd -P "$(dirname "$src")/../../scripts/lib" && pwd)
cd "$(dirname "${BASH_SOURCE[0]}")"

DEPLOY_PROVIDER=exoscale
DEPLOY_PASS_TOTAL=2
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$LIB/deploy-common.sh"

PASS2_FILE=pass2.auto.tfvars.json
POOL=module.ai_factory.exoscale_instance_pool.control_plane
TEMPLATE="module.ai_factory.exoscale_template.ai_factory[0]"

# exo_pin <cp_initialized> <image_import_port_open>
exo_pin() {
  jq -n --argjson cp "$1" --argjson port "$2" '{cp_initialized: $cp, image_import_port_open: $port}' \
    >"$PASS2_FILE.tmp" && mv "$PASS2_FILE.tmp" "$PASS2_FILE"
}

exo_pinned() { jq -r --arg k "$1" 'if has($k) then .[$k] else empty end' "$PASS2_FILE" 2>/dev/null || true; }

# Bootstrapped: the pool is in state and pass 1 finished (the pin is written
# false before it and true after it). A stale pin file never makes a new
# cluster skip init, and a failed pass 1 is rerun with the init configuration.
# The list is read in full first: `| grep -q` exits on the first match, and
# with pipefail the SIGPIPE it gives terraform would read as "not in state".
exo_bootstrapped() {
  local list
  list=$(terraform state list 2>/dev/null) || return 1
  grep -qxF "${POOL}[0]" <<<"$list" && [ "$(exo_pinned cp_initialized)" != false ]
}

# Plan hook. Aborts when an initialized pool would be created or replaced (a
# pool with the join configuration and no member to join), or when a plan
# would shrink the pool to one member (members removed, init configuration
# back); reopens port 80 and has the plan redone when the plan registers a
# new template.
exo_plan_hook() {
  if [ "$(exo_pinned cp_initialized)" = true ] &&
    jq -e --arg a "${POOL}[0]" '[.resource_changes[]? | select(.address == $a and (.change.actions | index("create")))] | length > 0' "$1" >/dev/null; then
    deploy_die "the plan creates or replaces the control plane pool of an initialized cluster; its members would have no cluster to join. Check the change (for example the zone), or destroy and deploy again."
  fi
  if jq -e --arg a "${POOL}[0]" '[.resource_changes[]? | select(.address == $a
      and ((.change.before.size // 0) > 1) and (.change.after.size == 1))] | length > 0' "$1" >/dev/null; then
    deploy_die "the plan shrinks the control plane pool to one member, which removes members and brings back the init configuration. Nothing was applied. Check $PASS2_FILE (cp_initialized must be true on a running cluster) and report this."
  fi
  # An apply interrupted after the serve path rotated and before the template
  # was replaced leaves replace_triggered_by nothing to trigger on.
  if jq -e --arg a "$TEMPLATE" '[.resource_changes[]? | select(.address == $a and .change.actions == ["update"]
      and .change.before.name != .change.after.name)] | length > 0' "$1" >/dev/null; then
    deploy_die "the plan renames the template without importing the new image (an earlier apply stopped mid-rebuild). Nothing was applied. Run ./deploy.sh --rebuild."
  fi
  [ "$(exo_pinned image_import_port_open)" != true ] || return 0
  jq -e '[.resource_changes[]? | select(.type == "exoscale_template" and (.change.actions | index("create")))] | length == 0' "$1" >/dev/null && return 0
  echo "    a new template is registered: opening port 80 on the jumphost for the import; re-planning..."
  exo_pin true true
  return 1
}

deploy_passes() {
  if exo_bootstrapped; then
    # Keeps an open import port from an interrupted run; closes it below.
    exo_pin true "$([ "$(exo_pinned image_import_port_open)" = true ] && echo true || echo false)"
    # shellcheck disable=SC2034 # read by tf_pass
    DEPLOY_PASS_TOTAL=1
    TF_PLAN_HOOK=exo_plan_hook tf_pass "Apply"
    if [ "$(exo_pinned image_import_port_open)" = true ]; then
      exo_pin true false
      # shellcheck disable=SC2034 # read by tf_pass
      DEPLOY_PASS_TOTAL=2
      tf_pass "Close image import port"
    fi
    return 0
  fi

  exo_pin false true
  TF_PLAN_HOOK=exo_plan_hook tf_pass "Bootstrap control plane"
  exo_pin true false
  TF_PLAN_HOOK=exo_plan_hook tf_pass "Scale control plane"
}

# The pins describe this cluster only; a new deploy starts from pass 1.
# The leftover tool defaults to the module's zone when region is not set.
deploy_after_destroy() {
  local zone
  local -a args
  rm -f "$PASS2_FILE"
  zone=$(deploy_var_string region)
  args=("$(deploy_cluster_name)")
  [ -z "$zone" ] || args+=(--region "$zone")
  deploy_suggest_leftovers "EXOSCALE_API_KEY=... EXOSCALE_API_SECRET=..." exoscale "${args[@]}"
}

deploy_main "$@"
