#!/usr/bin/env bash
# Smoke tests for examples/evroc/deploy.sh (fake terraform) and tools/orphans/evroc.
# Usage: scripts/tests/evroc_deploy_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(dirname "$(dirname "$T")")"
W=$(mktemp -d "${TMPDIR:-/tmp}/evroc-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

# Repo copy, so the script resolves its root the way it does in a checkout.
REPO="$W/repo"
mkdir -p "$REPO/examples/evroc" "$REPO/tools/orphans" "$REPO/tools/multicluster/clusters/a" \
  "$W/bin" "$W/state" "$W/home/.evroc"
cp -R "$R/scripts" "$REPO/scripts"
cp "$R/examples/evroc/deploy.sh" "$REPO/examples/evroc/deploy.sh"
cp "$R/tools/orphans/evroc" "$REPO/tools/orphans/evroc"
ln -s ../../../../examples/evroc/deploy.sh "$REPO/tools/multicluster/clusters/a/deploy.sh"
: >"$W/home/.evroc/config.yaml"

# Wrapper: answers `output -json image` from FAKE_HANDOFF, everything else goes to the fake.
cp "$T/fake-terraform-deploy.sh" "$W/bin/terraform-fake"
cat >"$W/bin/terraform" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = output ] && [ "\${2:-}" = -json ] && [ "\${3:-}" = image ]; then
  echo "output \$*" >>"\$FAKE_TF_STATE/calls.log"
  [ -n "\${FAKE_HANDOFF:-}" ] || exit 1
  echo '{"rebuild":'"\${FAKE_REBUILD:-0}"',"ids":{"a":"snap-a","b":null}}'
  exit 0
fi
exec "$W/bin/terraform-fake" "\$@"
SH
chmod +x "$W/bin/terraform" "$W/bin/terraform-fake"
export PATH="$W/bin:$PATH" HOME="$W/home"
export FAKE_TF_DIR="$T/fixtures" FAKE_TF_STATE="$W/state" TF_RETRY_SLEEP=0
unset CI DEPLOY_TTY FAKE_TF_PLAN FAKE_TF_PLAN_FAIL FAKE_TF_VERSION FAKE_TF_APPLY_SEQ FAKE_HANDOFF

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; echo "--- calls:" >&2; cat "$W/state/calls.log" >&2; exit 1; }
plans() { grep '^plan ' "$W/state/calls.log" || true; }
plan_n() { plans | sed -n "${1}p"; }
expect() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
reject() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }
reset() {
  rm -rf "$W/state"/* "$REPO/examples/evroc/.deploy" "$REPO/examples/evroc/.terraform" \
    "$REPO/examples/evroc/rebuild.auto.tfvars.json" "$REPO"/tools/multicluster/clusters/a/rebuild.auto.tfvars.json \
    "$REPO/examples/evroc/pass2.auto.tfvars.json" "$REPO"/tools/multicluster/clusters/a/.deploy \
    "$REPO"/tools/multicluster/clusters/a/pass2.auto.tfvars.json
  : >"$W/state/calls.log"
  unset FAKE_TF_APPLY_SEQ FAKE_HANDOFF
}
run() { # run <dir> args...
  local d=$1
  shift
  RC=0
  (cd "$d" && bash ./deploy.sh "$@" </dev/null) >"$W/out" 2>&1 || RC=$?
}
EX="$REPO/examples/evroc"

# --- fresh: three passes in order with the right args
reset
run "$EX" --yes -- -var=x=1
[ "$RC" -eq 0 ] || fail "rc $RC"
[ "$(plans | wc -l | tr -d ' ')" -eq 3 ] || fail "expected 3 plans"
p1=$(plan_n 1) p2=$(plan_n 2) p3=$(plan_n 3)
expect "$p1" "-var=image_ready=false"
reject "$p1" "-replace="
expect "$p2" "-var=image_ready=true -var=keep_build_artifacts=true"
expect "$p3" "-var=image_ready=true"
reject "$p3" "keep_build_artifacts"
for p in "$p1" "$p2" "$p3"; do expect "$p" "-var=x=1"; done
grep -q '"image_ready": true' "$EX/pass2.auto.tfvars.json" || fail "pin file missing"
expect "$(cat "$W/out")" "[1/3] Build image"
expect "$(cat "$W/out")" "[3/3] Reclaim build disks"

# --- --rebuild on a fresh state: three passes, counter written, no -replace
reset
run "$EX" --yes --rebuild
[ "$RC" -eq 0 ] || fail "rebuild rc $RC"
[ "$(jq .image_rebuild "$EX/rebuild.auto.tfvars.json")" = 1 ] || fail "counter not written"
for i in 1 2 3; do reject "$(plan_n $i)" "-replace="; done

# --- --rebuild with snapshots in state: goes through pass 1, counter follows state
reset
export FAKE_HANDOFF=1 FAKE_REBUILD=4
run "$EX" --yes --rebuild
[ "$RC" -eq 0 ] || fail "handoff rebuild rc $RC"
[ "$(plans | wc -l | tr -d ' ')" -eq 3 ] || fail "rebuild must run all 3 passes"
expect "$(plan_n 1)" "-var=image_ready=false"
[ "$(jq .image_rebuild "$EX/rebuild.auto.tfvars.json")" = 5 ] || fail "counter not bumped from state"
unset FAKE_REBUILD

# --- snapshots in state: one apply, image_ready stays true
reset
export FAKE_HANDOFF=1
run "$EX" --yes
[ "$RC" -eq 0 ] || fail "handoff rc $RC"
[ "$(plans | wc -l | tr -d ' ')" -eq 1 ] || fail "expected 1 plan"
expect "$(plan_n 1)" "-var=image_ready=true"
reject "$(plan_n 1)" "image_ready=false"
expect "$(cat "$W/out")" "[1/1] Apply"

# --- 409 on the first apply is retried
reset
export FAKE_TF_APPLY_SEQ="apply-409.jsonl:1 apply-ok.jsonl:0"
run "$EX" --yes
[ "$RC" -eq 0 ] || fail "409 rc $RC"
[ "$(plans | wc -l | tr -d ' ')" -eq 4 ] || fail "expected 4 plans after one retry"
expect "$(cat "$W/out")" "load-balancer conflict (409)"

# --- through a symlink in a cluster directory
reset
CL="$REPO/tools/multicluster/clusters/a"
run "$CL" --yes
[ "$RC" -eq 0 ] || fail "symlink rc $RC"
[ "$(plans | wc -l | tr -d ' ')" -eq 3 ] || fail "symlink: expected 3 plans"
[ -f "$CL/pass2.auto.tfvars.json" ] || fail "symlink: pin file not in cluster dir"

# --- missing evroc login
reset
mv "$W/home/.evroc/config.yaml" "$W/home/.evroc/config.yaml.off"
run "$EX" --yes
mv "$W/home/.evroc/config.yaml.off" "$W/home/.evroc/config.yaml"
[ "$RC" -ne 0 ] || fail "expected failure without evroc config"
expect "$(cat "$W/out")" "evroc login"
[ "$(plans | wc -l | tr -d ' ')" -eq 0 ] || fail "no plan expected"

# --- destroy prints the leftover check command (fake tool must not run)
mkdir -p "$REPO/tools/leftovers"
cat >"$REPO/tools/leftovers/evroc.sh" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_TF_STATE/lo.log"
SH
chmod +x "$REPO/tools/leftovers/evroc.sh"
reset
run "$EX" --yes --destroy
[ "$RC" -eq 0 ] || fail "destroy rc $RC"
expect "$(cat "$W/out")" "Check for leftovers (read-only"
expect "$(cat "$W/out")" "/tools/leftovers/evroc.sh suse-ai-factory"
[ ! -s "$W/state/lo.log" ] || fail "leftover tool ran on destroy"
printf 'cluster_name = "c-one"\nregion = "se-sto"\nproject = "p1"\n' >"$EX/terraform.tfvars"
reset
run "$EX" --yes --destroy
[ "$RC" -eq 0 ] || fail "destroy with vars rc $RC"
expect "$(cat "$W/out")" "/tools/leftovers/evroc.sh c-one --region se-sto --project p1"
[ ! -s "$W/state/lo.log" ] || fail "leftover tool ran on destroy"
reset
run "$EX" --yes
[ "$RC" -eq 0 ] || fail "deploy rc $RC"
[ ! -s "$W/state/lo.log" ] || fail "leftover tool ran on deploy"
rm -f "$EX/terraform.tfvars"

# --- tools/orphans/evroc with a fake terraform
LT="$W/leftovers"
mkdir -p "$LT/.terraform/providers"
: >"$LT/.terraform.lock.hcl"
cat >"$W/schema.json" <<'JSON'
{"provider_schemas":{"registry.terraform.io/evroc-oss/evroc":{"data_source_schemas":{
  "evroc_vpc":{"block":{"attributes":{"name":{},"project":{},"region":{}}}},
  "evroc_disk":{"block":{"attributes":{"name":{},"project":{}}}}}}}}
JSON
cat >"$W/plan-lo.json" <<'JSON'
{"resource_changes":[
 {"address":"module.m.evroc_vpc.free","mode":"managed","type":"evroc_vpc","change":{"actions":["create"],"after":{"name":"free-1","project":"p","region":"r"}}},
 {"address":"module.m.evroc_disk.orphan[\"a\"]","mode":"managed","type":"evroc_disk","change":{"actions":["create"],"after":{"name":"orphan-1","project":"p"}}},
 {"address":"module.m.evroc_nodata.x","mode":"managed","type":"evroc_nodata","change":{"actions":["create"],"after":{"name":"nodata-1"}}},
 {"address":"module.m.evroc_disk.upd","mode":"managed","type":"evroc_disk","change":{"actions":["update"],"after":{"name":"upd-1"}}}]}
JSON
cat >"$W/bin/terraform-lo" <<'SH'
#!/usr/bin/env bash
case "$1" in
  plan) for a in "$@"; do case "$a" in -out=*) : >"${a#-out=}" ;; esac; done ;;
  show) cat "$FAKE_LO_PLAN" ;;
  providers) cat "$FAKE_LO_SCHEMA" ;;
  -chdir=*)
    d=${1#-chdir=}
    if [ "$2" = plan ]; then
      for n in $FAKE_LO_FREE; do
        l=$(grep -n "name = \"$n\"" "$d/main.tf" | cut -d: -f1)
        printf '{"type":"diagnostic","diagnostic":{"severity":"error","summary":"x","detail":"API error (404)","range":{"start":{"line":%s}}}}\n' "$l"
      done
      [ -z "${FAKE_LO_BROKEN:-}" ] || echo '{"type":"diagnostic","diagnostic":{"severity":"error","summary":"boom","detail":"API error (500)","range":{"start":{"line":1}}}}'
      exit 1
    fi ;;
esac
SH
chmod +x "$W/bin/terraform-lo"
lo() { # lo args...: runs the tool against the leftovers fake
  mkdir -p "$W/lo-bin"
  cp "$W/bin/terraform-lo" "$W/lo-bin/terraform"
  RC=0
  (cd "$LT" && PATH="$W/lo-bin:$PATH" FAKE_LO_PLAN="$W/plan-lo.json" FAKE_LO_SCHEMA="$W/schema.json" \
    bash "$REPO/tools/orphans/evroc" "$@") >"$W/out" 2>&1 || RC=$?
}
FAKE_LO_FREE="free-1"
export FAKE_LO_FREE
lo
[ "$RC" -eq 1 ] || fail "leftovers: expected rc 1, got $RC"
expect "$(cat "$W/out")" 'module.m.evroc_disk.orphan["a"]  orphan-1'
reject "$(cat "$W/out")" "free-1"
[ -f "$LT/orphan-imports.tf.proposed" ] || fail "proposal not written"
expect "$(cat "$LT/orphan-imports.tf.proposed")" 'to = module.m.evroc_disk.orphan["a"]'
expect "$(cat "$LT/orphan-imports.tf.proposed")" 'id = "orphan-1"'
lo --adopt
[ "$RC" -eq 0 ] || fail "leftovers adopt: rc $RC"
[ -f "$LT/imports.tf" ] || fail "imports.tf not written"
FAKE_LO_FREE="free-1 orphan-1"
lo
[ "$RC" -eq 0 ] || fail "leftovers none: rc $RC"
FAKE_LO_BROKEN=1
export FAKE_LO_BROKEN
lo
[ "$RC" -eq 3 ] || fail "leftovers broken: expected rc 3, got $RC"

echo "evroc deploy tests passed"
