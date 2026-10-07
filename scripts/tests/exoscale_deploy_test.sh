#!/usr/bin/env bash
# Smoke test: examples/exoscale/deploy.sh --yes with a fake terraform. The pass
# choice comes from state (control plane pool present or not), never from a
# leftover pin file.
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$T")")"
W=$(mktemp -d "${TMPDIR:-/tmp}/exoscale-deploy-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state"
cp "$T/fake-terraform-deploy.sh" "$W/bin/terraform"
chmod +x "$W/bin/terraform"
export PATH="$W/bin:$PATH"
export FAKE_TF_DIR="$T/fixtures" FAKE_TF_STATE="$W/state" TF_RETRY_SLEEP=0
unset CI DEPLOY_TTY FAKE_TF_PLAN FAKE_TF_PLAN_FAIL FAKE_TF_VERSION FAKE_TF_APPLY_SEQ FAKE_TF_STATE_LIST

fail() { echo "FAIL: $*" >&2; cat "$W/out" >&2 || true; exit 1; }

mkdir -p "$W/repo/examples/exoscale" "$W/repo/scripts"
cp "$ROOT/examples/exoscale/deploy.sh" "$W/repo/examples/exoscale/deploy.sh"
cp -R "$ROOT/scripts/lib" "$W/repo/scripts/lib"
EX="$W/repo/examples/exoscale"
PINS="$EX/pass2.auto.tfvars.json"
POOL='module.ai_factory.exoscale_instance_pool.control_plane[0]'

# run [env...] -- deploy args: runs deploy.sh in $EX; rc in $RC.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$W/state/calls.log"
  rm -rf "$W/state/n" "$EX/.deploy" "$EX/rebuild.auto.tfvars.json"
  RC=0
  (cd "$EX" && env ${envs[@]+"${envs[@]}"} bash ./deploy.sh "$@") >"$W/out" 2>&1 </dev/null || RC=$?
}
pins() { jq -c '[.cp_initialized, .image_import_port_open]' "$PINS"; }
applies() { grep -c '^apply ' "$W/state/calls.log" || true; }

# --- new cluster: bootstrap then scale, pins end initialized with port 80 closed.
# A stale pin file from an earlier cluster must not skip the init pass.
printf '{"cp_initialized":true,"image_import_port_open":false}\n' >"$PINS"
run -- --yes
[ "$RC" -eq 0 ] || fail "new cluster: rc $RC"
grep -qF "==> [1/2] Bootstrap control plane" "$W/out" || fail "pass 1 header"
grep -qF "==> [2/2] Scale control plane" "$W/out" || fail "pass 2 header"
[ "$(applies)" -eq 2 ] || fail "new cluster: expected 2 applies"
[ "$(pins)" = '[true,false]' ] || fail "new cluster: pins $(pins)"

# --- pass 1 failed earlier (pool in state, pin still false): bootstrap again.
printf '{"cp_initialized":false,"image_import_port_open":true}\n' >"$PINS"
run FAKE_TF_STATE_LIST="$POOL" -- --yes
[ "$RC" -eq 0 ] || fail "failed pass 1 rerun: rc $RC"
grep -qF "==> [1/2] Bootstrap control plane" "$W/out" || fail "failed pass 1 rerun: not bootstrapping"
[ "$(pins)" = '[true,false]' ] || fail "failed pass 1 rerun: pins $(pins)"

# --- initialized cluster, no new template: one pass, pins unchanged.
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-vultr-update.json -- --yes
[ "$RC" -eq 0 ] || fail "rerun: rc $RC"
grep -qF "==> [1/1] Apply" "$W/out" || fail "rerun: single pass header"
[ "$(applies)" -eq 1 ] || fail "rerun: expected 1 apply"
[ "$(pins)" = '[true,false]' ] || fail "rerun: pins $(pins)"

# --- initialized cluster, rebuild: port 80 reopened for the import, then closed.
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-exoscale-template.json -- --yes
[ "$RC" -eq 0 ] || fail "rebuild: rc $RC"
grep -qF "opening port 80 on the jumphost" "$W/out" || fail "rebuild: port not reopened"
grep -qF "==> [2/2] Close image import port" "$W/out" || fail "rebuild: no close pass"
[ "$(applies)" -eq 2 ] || fail "rebuild: expected 2 applies"
[ "$(pins)" = '[true,false]' ] || fail "rebuild: pins $(pins)"

# --- rebuild that replaces the template of a running pool: the old template
# is moved to exoscale_template.retained (Exoscale refuses to delete it while
# members run), its id pinned, then port 80 opens and closes as usual.
MV='state mv module.ai_factory.exoscale_template.ai_factory[0] module.ai_factory.exoscale_template.retained["tmpl-old"]'
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-exoscale-template-replace.json -- --yes
[ "$RC" -eq 0 ] || fail "retain: rc $RC"
grep -qxF "$MV" "$W/state/calls.log" || fail "retain: no state mv"
[ "$(grep -c '^state mv ' "$W/state/calls.log")" -eq 1 ] || fail "retain: moved more than once"
grep -qF "kept as retained (tmpl-old)" "$W/out" || fail "retain: message"
grep -qF "==> [2/2] Close image import port" "$W/out" || fail "retain: no close pass"
[ "$(pins)" = '[true,false]' ] || fail "retain: pins $(pins)"
[ "$(jq -c .retained_template_ids "$PINS")" = '["tmpl-old"]' ] || fail "retain: retained $(jq -c . "$PINS")"

# --- later runs keep the retained ids; a failed state mv aborts before apply.
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-vultr-update.json -- --yes
[ "$(jq -c .retained_template_ids "$PINS")" = '["tmpl-old"]' ] || fail "retain rerun: retained dropped"
printf '{"cp_initialized":true,"image_import_port_open":false}\n' >"$PINS"
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-exoscale-template-replace.json FAKE_TF_STATE_MV_RC=1 -- --yes
[ "$RC" -ne 0 ] || fail "retain mv failure: deploy.sh succeeded"
[ "$(applies)" -eq 0 ] || fail "retain mv failure: applied"

# --- a new cluster drops retained ids left in a stale pin file.
printf '{"cp_initialized":true,"image_import_port_open":false,"retained_template_ids":["gone"]}\n' >"$PINS"
run -- --yes
[ "$(jq -c '.retained_template_ids // []' "$PINS")" = '[]' ] || fail "new cluster: stale retained kept"

# --- a long state list with the pool near the top: `| grep -q` would exit
# early and, with pipefail, read terraform's SIGPIPE as "not in state".
{ printf '%s\n' "$POOL"; for i in $(seq 1 20000); do echo "module.ai_factory.exoscale_security_group_rule.control_plane[\"r-$i\"]"; done; } >"$W/state-list"
run FAKE_TF_STATE_LIST_FILE="$W/state-list" FAKE_TF_PLAN=plan-vultr-update.json -- --yes
[ "$RC" -eq 0 ] || fail "long state: rc $RC"
grep -qF "==> [1/1] Apply" "$W/out" || fail "long state: bootstrap path taken on a bootstrapped cluster"

# --- a plan that shrinks the pool to one member aborts, whatever the path.
printf '{"cp_initialized":false,"image_import_port_open":true}\n' >"$PINS"
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-exoscale-pool-shrink.json -- --yes
[ "$RC" -ne 0 ] || fail "pool shrink: deploy.sh succeeded"
grep -qF "shrinks the control plane pool to one member" "$W/out" || fail "pool shrink: message"
[ "$(applies)" -eq 0 ] || fail "pool shrink: applied"
printf '{"cp_initialized":true,"image_import_port_open":false}\n' >"$PINS"

# --- initialized cluster whose pool would be replaced: abort before any apply.
run FAKE_TF_STATE_LIST="$POOL" FAKE_TF_PLAN=plan-exoscale-pool-replace.json -- --yes
[ "$RC" -ne 0 ] || fail "pool replace: deploy.sh succeeded"
grep -qF "creates or replaces the control plane pool of an initialized cluster" "$W/out" || fail "pool replace: message"
[ "$(applies)" -eq 0 ] || fail "pool replace: applied"

# --- destroy drops the pins, so the next deploy bootstraps.
run FAKE_TF_STATE_LIST="$POOL" -- --destroy --yes
[ "$RC" -eq 0 ] || fail "destroy: rc $RC"
[ ! -f "$PINS" ] || fail "destroy: pin file kept"
grep -qF "tools/leftovers/exoscale.sh" "$W/out" || fail "destroy: leftover check not suggested"

echo "exoscale_deploy_test: ok"
