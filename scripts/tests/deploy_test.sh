#!/usr/bin/env bash
# Tests for scripts/lib/{deploy-common,tf}.sh with a fake terraform replaying fixtures.
# Usage: scripts/tests/deploy_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(dirname "$T")/lib"
W=$(mktemp -d "${TMPDIR:-/tmp}/deploy-test.XXXXXX")
mkdir -p "$W/tmp" && export TMPDIR="$W/tmp"
trap 'rm -rf "$W"' EXIT

EX="$W/repo/examples/p"
mkdir -p "$W/bin" "$W/state" "$EX"
cp "$T/fake-terraform-deploy.sh" "$W/bin/terraform"
chmod +x "$W/bin/terraform"
export PATH="$W/bin:$PATH"
export FAKE_TF_DIR="$T/fixtures" FAKE_TF_STATE="$W/state" TF_RETRY_SLEEP=0
unset CI DEPLOY_TTY FAKE_TF_IMAGE FAKE_TF_PLAN FAKE_TF_PLAN_FAIL FAKE_TF_PLAN_WARN FAKE_TF_APPLY_SEQ

cat >"$EX/deploy.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"
DEPLOY_PROVIDER=p
DEPLOY_PASS_TOTAL=2
. "$LIB/deploy-common.sh"
[ -z "\${TEST_RETRY:-}" ] || tf_retry_on 'API error \(409\)' 3 "load-balancer conflict"
deploy_passes() {
  tf_pass "Build image" -target=module.ai_factory.module.image -var=deploy_nodes=false
  tf_pass "Create nodes"
}
deploy_main "\$@"
SH

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2'"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
calls() { grep -c "^$1" "$W/state/calls.log" || true; }
reset() {
  rm -rf "$EX/.deploy" "$EX/.terraform" "$EX/rebuild.auto.tfvars.json" "$W/state"/* "$W"/repo/*.tfvars "$W"/repo/examples/*.tfvars "$EX"/*.tfvars
  : >"$W/state/calls.log"
  unset TEST_RETRY FAKE_TF_PLAN FAKE_TF_PLAN_FAIL FAKE_TF_PLAN_WARN FAKE_TF_APPLY_SEQ DEPLOY_TTY
}
# run_deploy [--in TEXT] args...: sets OUT and RC, keeps the raw output in $W/out.
run_deploy() {
  local input=""
  if [ "${1:-}" = --in ]; then
    input=$2
    shift 2
  fi
  RC=0
  (cd "$EX" && printf '%s' "$input" | bash ./deploy.sh "$@") >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
}

# --- happy path, --yes, non-TTY
reset
touch "$W/repo/common-all.tfvars" "$W/repo/examples/common-all.tfvars" "$W/repo/examples/common-p.tfvars" "$EX/terraform.tfvars"
run_deploy --yes -- -var=x=1 -auto-approve
[ "$RC" -eq 0 ] || fail "happy path rc=$RC"
[ "$(calls plan)" -eq 2 ] || fail "expected 2 plans"
[ "$(calls apply)" -eq 2 ] || fail "expected 2 applies"
p1=$(grep '^plan ' "$W/state/calls.log" | head -n1)
has "$p1" "-var-file=../../common-all.tfvars"
has "$p1" "-var-file=terraform.tfvars"
has "$p1" "-target=module.ai_factory.module.image"
has "$p1" "-var=x=1"
hasnt "$p1" "-auto-approve"
has "$OUT" "apply:"
[ -d "$EX/.deploy/logs" ] || fail "no log dir"

# --- declined and EOF confirmation
reset
run_deploy --in n
[ "$RC" -eq 1 ] || fail "declined rc=$RC"
[ "$(calls apply)" -eq 0 ] || fail "applied after decline"
run_deploy
[ "$RC" -eq 1 ] || fail "EOF should decline"

# --- no changes
reset
FAKE_TF_PLAN=plan-noop.json run_deploy --yes
[ "$RC" -eq 0 ] || fail "noop rc"
has "$OUT" "plan: no changes"
[ "$(calls apply)" -eq 0 ] || fail "noop applied"

# --- import-only plan still applies; plan warnings shown before the confirmation
reset
FAKE_TF_PLAN=plan-import.json FAKE_TF_PLAN_WARN=1 run_deploy --yes
[ "$RC" -eq 0 ] || fail "import rc"
has "$OUT" "1 to import"
has "$OUT" "Warning: Check block assertion failed"
hasnt "$OUT" "Saved the plan"
[ "$(calls apply)" -eq 2 ] || fail "import-only plan not applied"

# --- plan failure and apply failure
reset
FAKE_TF_PLAN_FAIL=1 run_deploy --yes
[ "$RC" -ne 0 ] || fail "plan failure accepted"
has "$OUT" "==> FAILED"
reset
FAKE_TF_APPLY_SEQ="apply-fail.jsonl:1" run_deploy --yes
[ "$RC" -ne 0 ] || fail "apply failure accepted"
has "$OUT" "==> FAILED"

# --- retry on pattern
reset
TEST_RETRY=1 FAKE_TF_APPLY_SEQ="apply-409.jsonl:1 apply-ok.jsonl:0" run_deploy --yes
[ "$RC" -eq 0 ] || fail "retry rc=$RC"
reset
TEST_RETRY=1 FAKE_TF_APPLY_SEQ="apply-409.jsonl:1" run_deploy --yes
[ "$RC" -ne 0 ] || fail "retry exhaustion accepted"
has "$OUT" "still failing after 3 attempts"
reset
FAKE_TF_APPLY_SEQ="apply-409.jsonl:1" run_deploy --yes
[ "$(calls apply)" -eq 1 ] || fail "retried without registered pattern"

# --- destroy
reset
run_deploy --yes --destroy
[ "$RC" -eq 0 ] || fail "destroy rc"
has "$(grep '^plan ' "$W/state/calls.log")" "-destroy"
[ "$(calls apply)" -eq 1 ] || fail "destroy applies"

# --- rebuild bumps the persisted counter; no -replace anywhere
reset
run_deploy --rebuild --yes
[ "$RC" -eq 0 ] || fail "rebuild rc=$RC"
[ "$(jq .image_rebuild "$EX/rebuild.auto.tfvars.json")" = 1 ] || fail "first rebuild should write 1"
hasnt "$(grep '^plan ' "$W/state/calls.log")" "-replace"
run_deploy --rebuild --yes
[ "$(jq .image_rebuild "$EX/rebuild.auto.tfvars.json")" = 2 ] || fail "second rebuild should write 2"
# state (image.rebuild) ahead of the file wins
FAKE_TF_IMAGE='{"build_id":"x","rebuild":7,"ids":{}}' run_deploy --rebuild --yes
[ "$(jq .image_rebuild "$EX/rebuild.auto.tfvars.json")" = 8 ] || fail "state counter not honoured"
# a plain run neither creates nor changes the file
rm -f "$EX/rebuild.auto.tfvars.json"
run_deploy --yes
[ ! -e "$EX/rebuild.auto.tfvars.json" ] || fail "plain run wrote the counter"
# ...unless state is ahead (lost file): it is restored, not reset to 0
FAKE_TF_IMAGE='{"build_id":"x","rebuild":7,"ids":{}}' run_deploy --yes
[ "$(jq .image_rebuild "$EX/rebuild.auto.tfvars.json")" = 7 ] || fail "plain run did not restore the counter from state"
rm -f "$EX/rebuild.auto.tfvars.json"
# a provider/common var file must not set it either
echo 'image_rebuild = 3' >"$W/repo/examples/common-p.tfvars"
run_deploy --rebuild --yes
[ "$RC" -ne 0 ] || fail "image_rebuild in common-p.tfvars accepted"
has "$OUT" "image_rebuild is set in ../common-p.tfvars"
rm -f "$W/repo/examples/common-p.tfvars"
# terraform.tfvars must not set it (it would override the auto file)
echo 'image_rebuild = 3' >"$EX/terraform.tfvars"
run_deploy --rebuild --yes
[ "$RC" -ne 0 ] || fail "image_rebuild in terraform.tfvars accepted"
has "$OUT" "image_rebuild is set in terraform.tfvars"

# --- argument errors and help
reset
run_deploy --bogus
[ "$RC" -ne 0 ] || fail "unknown arg accepted"
has "$OUT" "unknown argument: --bogus"
run_deploy --help
[ "$RC" -eq 0 ] || fail "--help rc"
has "$OUT" "Usage: deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform args>]"
[ "$(calls plan)" -eq 0 ] || fail "--help ran terraform"

# --- missing dependency
reset
mkdir "$W/nojq"
for c in bash env cat date mkdir chmod rm tr sed grep tail dirname ls printf; do
  p=$(command -v "$c" || true)
  [ -z "$p" ] || ln -sf "$p" "$W/nojq/$c"
done
ln -sf "$W/bin/terraform" "$W/nojq/terraform"
RC=0
(cd "$EX" && PATH="$W/nojq" bash ./deploy.sh --yes) >"$W/out" 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail "missing jq accepted"
has "$(cat "$W/out")" "missing required tools: jq ssh"

# --- examples/aws/deploy.sh: single pass, also via a symlinked cluster dir
reset
R="$W/awsrepo"
mkdir -p "$R/examples" "$R/clusters/c1"
cp -R "$(dirname "$T")/../examples/aws" "$R/examples/aws"
ln -sfn "$(dirname "$T")" "$R/scripts"
ln -sf ../../examples/aws/deploy.sh "$R/clusters/c1/deploy.sh"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/aws"
chmod +x "$W/bin/aws"
# fake leftover tool: logs its args; deploy.sh must only print its command
mkdir -p "$R/tools/leftovers"
cat >"$R/tools/leftovers/aws.sh" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_TF_STATE/lo.log"
exit 0
SH
chmod +x "$R/tools/leftovers/aws.sh"
for d in "$R/examples/aws" "$R/clusters/c1"; do
  : >"$W/state/calls.log"
  rm -rf "$d/.deploy" "$d/.terraform" "$d/rebuild.auto.tfvars.json" "$W/state/n"
  RC=0
  (cd "$d" && bash ./deploy.sh --rebuild --yes -- -var=x=1) >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
  [ "$RC" -eq 0 ] || fail "aws deploy rc=$RC in $d"
  [ "$(calls plan)" -eq 1 ] || fail "aws: expected one plan"
  [ "$(calls apply)" -eq 1 ] || fail "aws: expected one apply"
  hasnt "$(grep '^plan ' "$W/state/calls.log")" "-replace"
  [ "$(jq .image_rebuild "$d/rebuild.auto.tfvars.json")" = 1 ] || fail "aws: counter not written in $d"
  has "$(grep '^plan ' "$W/state/calls.log")" "-var=x=1"
  hasnt "$(grep '^plan ' "$W/state/calls.log")" "-target"
  has "$OUT" "==> Deploy"
done
# invoked by a relative path from another directory
RC=0
(cd "$R" && bash clusters/c1/deploy.sh --help) >"$W/out" 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "aws deploy.sh by relative path rc=$RC"
# IAM probe: allowed (validation error) proceeds, denied stops before plan
d="$R/examples/aws"
printf 'cluster_name = "c-one"\n' >"$d/terraform.tfvars"
cat >"$W/bin/aws" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_TF_STATE/aws.log"
[ "$2" = create-role ] || exit 0
echo "An error occurred ($FAKE_AWS_CREATE_ROLE) when calling the CreateRole operation" >&2
exit 254
SH
for err in MalformedPolicyDocument AccessDenied; do
  : >"$W/state/calls.log"
  : >"$W/state/aws.log"
  rm -rf "$d/.deploy" "$d/.terraform" "$d/rebuild.auto.tfvars.json"
  RC=0
  (cd "$d" && FAKE_AWS_CREATE_ROLE=$err bash ./deploy.sh --yes) >"$W/out" 2>&1 || RC=$?
  has "$(cat "$W/state/aws.log")" "iam create-role --role-name c-one-jumphost"
  if [ "$err" = AccessDenied ]; then
    [ "$RC" -ne 0 ] || fail "aws: denied iam:CreateRole accepted"
    [ "$(calls plan)" -eq 0 ] || fail "aws: planned despite denied iam:CreateRole"
    has "$(cat "$W/out")" "cannot create IAM role c-one-jumphost"
  else
    [ "$RC" -eq 0 ] || fail "aws: allowed iam:CreateRole rejected rc=$RC"
  fi
done
# no probe on destroy
: >"$W/state/aws.log"
(cd "$d" && FAKE_AWS_CREATE_ROLE=AccessDenied bash ./deploy.sh --destroy --yes) >"$W/out" 2>&1 || fail "aws: destroy blocked by IAM probe"
hasnt "$(cat "$W/state/aws.log")" "create-role"
has "$(cat "$W/out")" "Check for leftovers"
has "$(cat "$W/out")" "tools/leftovers/aws.sh c-one --region <region>"
[ ! -s "$W/state/lo.log" ] || fail "aws: leftover tool ran on destroy"
printf 'cluster_name = "c-one"\nregion = "eu-west-1"\n' >"$d/terraform.tfvars"
(cd "$d" && bash ./deploy.sh --destroy --yes) >"$W/out" 2>&1 || fail "aws: destroy failed"
has "$(cat "$W/out")" "/tools/leftovers/aws.sh c-one --region eu-west-1"
[ ! -s "$W/state/lo.log" ] || fail "aws: leftover tool ran on destroy"
: >"$W/state/lo.log"
(cd "$d" && bash ./deploy.sh --yes) >"$W/out" 2>&1 || fail "aws: deploy failed"
hasnt "$(cat "$W/out")" "leftover"
[ ! -s "$W/state/lo.log" ] || fail "aws: leftover tool ran on deploy"
printf 'cluster_name = "c-one"\n' >"$d/terraform.tfvars"
# pre-created IAM: both names set skip the probe; one alone does not
for case in both one; do
  printf 'cluster_name = "c-one"\nvmimport_role_name = "r"\n' >"$d/terraform.tfvars"
  [ "$case" = one ] || printf 'jumphost_instance_profile_name = "p"\n' >>"$d/terraform.tfvars"
  : >"$W/state/calls.log"
  : >"$W/state/aws.log"
  rm -rf "$d/.deploy" "$d/.terraform" "$d/rebuild.auto.tfvars.json"
  RC=0
  (cd "$d" && FAKE_AWS_CREATE_ROLE=AccessDenied bash ./deploy.sh --yes) >"$W/out" 2>&1 || RC=$?
  if [ "$case" = both ]; then
    [ "$RC" -eq 0 ] || fail "aws: pre-created IAM run rc=$RC"
    hasnt "$(cat "$W/state/aws.log")" "create-role"
  else
    [ "$RC" -ne 0 ] || fail "aws: probe skipped with one IAM name set"
    has "$(cat "$W/state/aws.log")" "iam create-role"
  fi
done
# names and cluster_name from TF_VAR_* and -var in the tf args, as Terraform reads them
printf 'cluster_name = "c-one"\n' >"$d/terraform.tfvars"
for case in env args; do
  : >"$W/state/aws.log"
  rm -rf "$d/.deploy" "$d/.terraform" "$d/rebuild.auto.tfvars.json"
  RC=0
  if [ "$case" = env ]; then
    (cd "$d" && FAKE_AWS_CREATE_ROLE=AccessDenied TF_VAR_vmimport_role_name=r TF_VAR_jumphost_instance_profile_name=p \
      bash ./deploy.sh --yes) >"$W/out" 2>&1 || RC=$?
  else
    (cd "$d" && FAKE_AWS_CREATE_ROLE=AccessDenied bash ./deploy.sh --yes -- \
      -var vmimport_role_name=r -var=jumphost_instance_profile_name=p) >"$W/out" 2>&1 || RC=$?
  fi
  [ "$RC" -eq 0 ] || fail "aws: pre-created IAM via $case rc=$RC"
  hasnt "$(cat "$W/state/aws.log")" "create-role"
done
: >"$W/state/aws.log"
rm -rf "$d/.deploy" "$d/.terraform" "$d/rebuild.auto.tfvars.json"
(cd "$d" && FAKE_AWS_CREATE_ROLE=MalformedPolicyDocument bash ./deploy.sh --yes -- -var cluster_name=c-two) >"$W/out" 2>&1 ||
  fail "aws: -var cluster_name run failed"
has "$(cat "$W/state/aws.log")" "iam create-role --role-name c-two-jumphost"
rm -f "$W/bin/aws" "$d/terraform.tfvars"

# --- event protocol (DEPLOY_EVENTS_FD / DEPLOY_CONFIRM_FD)
# run_events [--answer TEXT] args...: events in $W/events, rc in RC.
run_events() {
  local answer=""
  if [ "${1:-}" = --answer ]; then
    answer=$2
    shift 2
  fi
  printf '%s' "$answer" >"$W/answer"
  : >"$W/events"
  RC=0
  if [ -n "$answer" ]; then
    (cd "$EX" && DEPLOY_EVENTS_FD=3 DEPLOY_CONFIRM_FD=4 bash ./deploy.sh "$@" </dev/null 3>"$W/events" 4<"$W/answer") >"$W/out" 2>&1 || RC=$?
  else
    (cd "$EX" && DEPLOY_EVENTS_FD=3 bash ./deploy.sh "$@" </dev/null 3>"$W/events") >"$W/out" 2>&1 || RC=$?
  fi
  OUT=$(cat "$W/out")
}
ev_types() { jq -r .type "$W/events" | paste -sd, -; }
ev_count() { jq -r "select($1) | 1" "$W/events" | wc -l | tr -d ' '; }

reset
run_events --yes
[ "$RC" -eq 0 ] || fail "events: rc=$RC"
jq -e . "$W/events" >/dev/null || fail "events: invalid JSON"
[ "$(jq -s 'all(.[]; has("type") and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")))' "$W/events")" = true ] || fail "events: type/ts"
t=$(ev_types)
case "$t" in start,pass_start,plan_summary,*pass_done,pass_start,plan_summary,*pass_done,done) ;; *) fail "events: order: $t" ;; esac
[ "$(ev_count '.type == "start" and .provider == "p" and .action == "deploy" and .pass_total == 2')" -eq 1 ] || fail "events: start"
[ "$(ev_count '.type == "pass_start" and .total == 2 and .title == "Build image" and .index == 1')" -eq 1 ] || fail "events: pass_start"
[ "$(ev_count '.type == "resource" and .address == "aws_vpc.main" and .status == "complete"')" -ge 1 ] || fail "events: resource"
[ "$(ev_count '.type == "plan_summary" and .no_changes == false and (.replace | type) == "array"')" -eq 2 ] || fail "events: plan_summary"
[ "$(ev_count '.type == "pass_done" and .status == "ok"')" -eq 2 ] || fail "events: pass_done"
[ "$(ev_count '.type == "confirm_request"')" -eq 0 ] || fail "events: --yes must not ask"
[ "$(ev_count '.type == "diagnostic" and .severity == "warning" and .summary == "Deprecated argument"')" -ge 1 ] || fail "events: diagnostic"
[ "$(jq -r 'select(.type == "done") | "\(.status) \(.exit_code)"' "$W/events")" = "ok 0" ] || fail "events: done"
ls "$TMPDIR"/tf-events.* >/dev/null 2>&1 && fail "events: fifo left behind"
# rendered output is the same with and without events
run_deploy --yes
plain=$OUT
reset
run_events --yes
[ "$(sed 's/in [0-9]*s/in Ns/; s/([0-9]*:[0-9]*)/(T)/; s/Logs .*//' <<<"$plain")" = "$(sed 's/in [0-9]*s/in Ns/; s/([0-9]*:[0-9]*)/(T)/; s/Logs .*//' <<<"$OUT")" ] ||
  fail "events: rendering differs"

# confirmation via the fd, no TTY
reset
run_events --answer $'yes\nyes\n'
[ "$RC" -eq 0 ] || fail "confirm yes: rc=$RC"
[ "$(ev_count '.type == "confirm_request"')" -eq 2 ] || fail "confirm yes: request"
[ "$(ev_count '.type == "confirm_response" and .answer == "yes" and .index == 1')" -eq 1 ] || fail "confirm yes: response"
[ "$(calls apply)" -eq 2 ] || fail "confirm yes: applies"
reset
run_events --answer $'no\n'
[ "$RC" -eq 1 ] || fail "confirm no: rc=$RC"
[ "$(calls apply)" -eq 0 ] || fail "confirm no: applied"
[ "$(ev_count '.type == "confirm_response" and .answer == "no"')" -eq 1 ] || fail "confirm no: response"
t=$(ev_types)
case "$t" in *confirm_response,pass_done,done) ;; *) fail "confirm no: tail: $t" ;; esac
[ "$(jq -r 'select(.type == "done") | "\(.status) \(.exit_code)"' "$W/events")" = "aborted 1" ] || fail "confirm no: done"
[ "$(jq -r 'select(.type == "pass_done") | .status' "$W/events")" = failed ] || fail "confirm no: pass_done"

# done on failure (apply error): diagnostic, failed pass, done failed
reset
export FAKE_TF_APPLY_SEQ="apply-fail.jsonl:1"
run_events --yes
[ "$RC" -ne 0 ] || fail "events fail: rc=0"
[ "$(ev_count '.type == "resource" and .status == "errored" and .address == "aws_lb.api"')" -eq 1 ] || fail "events fail: errored"
[ "$(ev_count '.type == "diagnostic" and .severity == "error" and .detail == "quota exceeded"')" -eq 1 ] || fail "events fail: diagnostic"
[ "$(jq -r 'select(.type == "pass_done") | .status' "$W/events")" = failed ] || fail "events fail: pass_done"
[ "$(ev_types | sed 's/.*,//')" = "done" ] || fail "events fail: done last"
[ "$(jq -r 'select(.type == "done") | .status' "$W/events")" = failed ] || fail "events fail: done status"
# done on plan failure
reset
export FAKE_TF_PLAN_FAIL=1
run_events --yes
[ "$RC" -ne 0 ] || fail "events plan fail: rc=0"
[ "$(jq -r 'select(.type == "done") | .status' "$W/events")" = failed ] || fail "events plan fail: done"
[ "$(ev_count '.type == "done"')" -eq 1 ] || fail "events plan fail: done count"
# no changes
reset
export FAKE_TF_PLAN=plan-noop.json
run_events --yes
[ "$RC" -eq 0 ] || fail "events noop: rc=$RC"
[ "$(ev_count '.type == "plan_summary" and .no_changes == true and .create == 0')" -eq 2 ] || fail "events noop: plan_summary"
[ "$(ev_count '.type == "pass_done" and .status == "no_changes"')" -eq 2 ] || fail "events noop: pass_done"
# destroy
reset
run_events --yes --destroy
[ "$RC" -eq 0 ] || fail "events destroy: rc=$RC"
[ "$(ev_count '.type == "start" and .action == "destroy" and .pass_total == 1')" -eq 1 ] || fail "events destroy: start"
[ "$(ev_count '.type == "pass_start" and .title == "Destroy"')" -eq 1 ] || fail "events destroy: pass_start"
[ "$(ev_types | sed 's/.*,//')" = "done" ] || fail "events destroy: done"
# events reader failing early (fd not open) must not break the apply
reset
RC=0
(cd "$EX" && DEPLOY_EVENTS_FD=9 bash ./deploy.sh --yes </dev/null) >"$W/out" 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "bad events fd: rc=$RC"
[ "$(sed 's/in [0-9]*s/in Ns/; s/([0-9]*:[0-9]*)/(T)/; s/Logs .*//' <<<"$plain")" = "$(sed 's/in [0-9]*s/in Ns/; s/([0-9]*:[0-9]*)/(T)/; s/Logs .*//' "$W/out")" ] ||
  fail "bad events fd: rendering differs"
ls "$TMPDIR"/tf-events.* >/dev/null 2>&1 && fail "bad events fd: fifo left behind"
# CONFIRM_FD without events, no TTY
reset
RC=0
(cd "$EX" && DEPLOY_CONFIRM_FD=4 bash ./deploy.sh </dev/null 4<<<$'yes\nyes') >"$W/out" 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "confirm fd only: rc=$RC"
reset

echo ok
