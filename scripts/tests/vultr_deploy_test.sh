#!/usr/bin/env bash
# Smoke test: examples/vultr/deploy.sh --yes with a fake terraform, direct and via a symlinked dir.
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$T")")"
W=$(mktemp -d "${TMPDIR:-/tmp}/vultr-deploy-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state"
cp "$T/fake-terraform-deploy.sh" "$W/bin/terraform"
chmod +x "$W/bin/terraform"
export PATH="$W/bin:$PATH"
export FAKE_TF_DIR="$T/fixtures" FAKE_TF_STATE="$W/state" TF_RETRY_SLEEP=0 VULTR_API_KEY=test
unset CI DEPLOY_TTY FAKE_TF_PLAN FAKE_TF_PLAN_FAIL FAKE_TF_VERSION FAKE_TF_APPLY_SEQ

fail() { echo "FAIL: $*" >&2; cat "$W/out" >&2 || true; exit 1; }

# run <dir> args...: runs the vultr deploy.sh from <dir>, copies of the example in $W.
run() {
  local dir=$1
  shift
  : >"$W/state/calls.log"
  rm -rf "$W/state/n" "$dir/.deploy" "$dir/.terraform" "$dir/pass2.auto.tfvars.json" "$dir/rebuild.auto.tfvars.json"
  (cd "$dir" && bash ./deploy.sh "$@") >"$W/out" 2>&1 </dev/null || fail "rc $? in $dir"
}

check() {
  local plans
  plans=$(grep '^plan ' "$W/state/calls.log")
  [ "$(wc -l <<<"$plans")" -eq 2 ] || fail "expected 2 plans"
  ! grep -qF -- "-replace" <<<"$plans" || fail "-replace used"
  [ "$(jq .image_rebuild "$1/rebuild.auto.tfvars.json")" = 1 ] || fail "rebuild counter not written"
  [ "$(grep -c '^apply ' "$W/state/calls.log")" -eq 2 ] || fail "expected 2 applies"
  grep -qF "==> [1/2] Create infrastructure" "$W/out" || fail "pass 1 header"
  grep -qF "==> [2/2] Attach load balancer backends" "$W/out" || fail "pass 2 header"
  check_pass2 "$1"
}

check_pass2() {
  [ "$(jq -c '.lb_backend_instance_ids' "$1/pass2.auto.tfvars.json")" = '["i-1","i-2"]' ] || fail "backend ids"
  [ "$(jq -c '.lb_supervisor_extra_cidrs' "$1/pass2.auto.tfvars.json")" = '["10.0.0.5/32"]' ] || fail "supervisor cidrs"
  [ "$(jq -c '.agent_cloud_extra_cidrs' "$1/pass2.auto.tfvars.json")" = '["203.0.113.7/32"]' ] || fail "agent cidrs"
  [ "$(jq '.image_import_port_open' "$1/pass2.auto.tfvars.json")" = false ] || fail "port 80 not closed"
}

# Direct: a copy of the tree layout so the repo stays clean.
mkdir -p "$W/repo/examples/vultr" "$W/repo/scripts"
cp "$ROOT/examples/vultr/deploy.sh" "$W/repo/examples/vultr/deploy.sh"
cp -R "$ROOT/scripts/lib" "$W/repo/scripts/lib"
EX="$W/repo/examples/vultr"
run "$EX" --rebuild --yes
check "$EX"

# Symlinked deploy.sh in a cluster directory two levels below the tools dir.
CL="$W/repo/tools/multicluster/clusters/c1"
mkdir -p "$CL"
ln -s ../../../../examples/vultr/deploy.sh "$CL/deploy.sh"
run "$CL" --rebuild --yes
check "$CL"

# --- rerun: pinned pass 2 values survive pass 1 unless a node is replaced
PINNED='{"lb_backend_instance_ids":["i-1","i-2"],"lb_supervisor_extra_cidrs":["10.0.0.5/32"],"agent_cloud_extra_cidrs":["203.0.113.7/32"],"image_import_port_open":false}'
rerun() {
  : >"$W/state/calls.log"
  rm -f "$W/state/n"
  printf '%s\n' "$PINNED" >"$EX/pass2.auto.tfvars.json"
  (cd "$EX" && env "$@" bash ./deploy.sh --yes) >"$W/out" 2>&1 </dev/null || fail "rerun rc $?"
}
rerun FAKE_TF_PLAN=plan-vultr-update.json
[ "$(grep -c '^plan ' "$W/state/calls.log")" -eq 2 ] || fail "rerun: expected 2 plans"
! grep -qF "detached" "$W/out" || fail "rerun: backends reset without a node change"
grep -qF '~   module.ai_factory.vultr_instance.agent_cloud["w-0"]' "$W/out" || fail "update not listed"
grep -qF '+   module.ai_factory.vultr_firewall_rule.agent_cloud["ssh-198.51.100.1/32"]' "$W/out" || fail "create not listed"

# A file reset by an earlier run is rebuilt from state: nothing to do.
PINNED='{"lb_backend_instance_ids":[],"lb_supervisor_extra_cidrs":[],"agent_cloud_extra_cidrs":[]}' rerun FAKE_TF_PLAN=plan-noop.json
[ "$(grep -c "plan: no changes" "$W/out")" -eq 2 ] || fail "reset file: expected two empty plans"
! grep -qF "detached" "$W/out" || fail "reset file: backends reset"
check_pass2 "$EX"

rerun FAKE_TF_PLAN=plan-vultr-node-replace.json
[ "$(grep -c '^plan ' "$W/state/calls.log")" -eq 3 ] || fail "replace: expected pass 1 re-plan"
grep -qF "detached until pass 2" "$W/out" || fail "replace: no reset note"
check_pass2 "$EX"

# --- destroy: the leftover hook prints the command and never runs the tool or leaks the key
mkdir -p "$W/repo/tools/leftovers"
cat >"$W/repo/tools/leftovers/vultr.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub leftovers ran"
STUB
chmod +x "$W/repo/tools/leftovers/vultr.sh"
dest() { (cd "$EX" && env "$@" bash ./deploy.sh --destroy --yes) >"$W/out" 2>&1 </dev/null; }
has() { grep -qF -- "$1" "$W/out" || fail "missing '$1'"; }
hasnt() { ! grep -qF -- "$1" "$W/out" || fail "unexpected '$1'"; }
: >"$W/state/calls.log"
dest TF_VAR_vultr_api_key=sekret VULTR_API_KEY=envkey TF_VAR_cluster_name=prod || fail "destroy with key"
has "VULTR_API_KEY=... "
has "/tools/leftovers/vultr.sh prod"
hasnt "stub leftovers ran"
hasnt "sekret"
hasnt "envkey"

echo ok
