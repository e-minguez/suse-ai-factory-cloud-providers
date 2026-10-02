#!/usr/bin/env bash
# Two-pass deploy: the load balancer backends depend on nodes built from an
# image that needs the load balancer's IP. See docs/providers/vultr.md.
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

DEPLOY_PROVIDER=vultr
DEPLOY_PASS_TOTAL=2
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$LIB/deploy-common.sh"

PASS2_FILE=pass2.auto.tfvars.json
PASS2_RESET='{"lb_backend_instance_ids":[],"lb_supervisor_extra_cidrs":[],"agent_cloud_extra_cidrs":[]}'

# Pass 1 plan hook: keeps the pinned pass 2 values unless the plan deletes a
# node or the NAT gateway (stale IDs), creates the snapshot (needs port 80) or
# a load balancer (stale file); then resets them and has the plan redone.
vultr_pass1_hook() {
  [ "$(jq -c . "$PASS2_FILE" 2>/dev/null)" != "$PASS2_RESET" ] || return 0
  jq -e '[.resource_changes[]? | .type as $t | .change.actions as $a
    | select(($t | IN("vultr_instance", "vultr_bare_metal_server", "vultr_nat_gateway")) and ($a | index("delete"))
      or ($t | IN("vultr_snapshot_from_url", "vultr_load_balancer")) and ($a | index("create")))]
    | length == 0' "$1" >/dev/null && return 0
  echo "    nodes, NAT gateway, image or load balancers change: load balancer backends detached until pass 2; re-planning..."
  printf '%s\n' "$PASS2_RESET" >"$PASS2_FILE"
  return 1
}

# Writes the pass 2 values from the provider_details output; fails when the
# output is missing (fresh root). --if-nodes: also fails with no control plane.
vultr_pin_from_state() {
  local details
  details=$(terraform output -json provider_details 2>/dev/null) || return 1
  [ "${1:-}" != --if-nodes ] || jq -e '(.control_plane_ids // []) != []' <<<"$details" >/dev/null || return 1
  jq '{
    lb_backend_instance_ids: .control_plane_ids,
    lb_supervisor_extra_cidrs: .agent_node_cidrs,
    agent_cloud_extra_cidrs: .nat_gateway_public_cidrs,
    image_import_port_open: false
  }' <<<"$details" >"$PASS2_FILE.tmp" && mv "$PASS2_FILE.tmp" "$PASS2_FILE"
}

# Backend lists as plain variables, pinned in an auto-loaded file so a later
# plain `terraform apply` keeps them. A missing or reset file is rebuilt from
# state; pass 1 keeps the values unless vultr_pass1_hook resets them, so a
# rerun without changes plans nothing.
deploy_passes() {
  if [ "$(jq -c . "$PASS2_FILE" 2>/dev/null)" = "$PASS2_RESET" ] || [ ! -f "$PASS2_FILE" ]; then
    vultr_pin_from_state --if-nodes || printf '%s\n' "$PASS2_RESET" >"$PASS2_FILE"
  fi

  TF_PLAN_HOOK=vultr_pass1_hook tf_pass "Create infrastructure"

  vultr_pin_from_state || deploy_die "cannot write $PASS2_FILE from output provider_details"

  tf_pass "Attach load balancer backends"
}

# Suggests the leftover check after destroy; the user supplies the API key.
deploy_after_destroy() {
  deploy_suggest_leftovers "VULTR_API_KEY=..." vultr "$(deploy_cluster_name)"
}

deploy_main "$@"
