#!/usr/bin/env bash
# Tests for the awk helpers behind scripts/tests/tofu-tests.sh (no tofu needed).
# Usage: scripts/tests/tofu_tests_test.sh
# shellcheck disable=SC2016 # the HCL fixtures contain literal ${...}
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in gawk jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "tofu_tests_test: $c not found, skipping"; exit 0; }
done
W=$(mktemp -d "${TMPDIR:-/tmp}/tofu-tests-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir "$W/mod" "$W/empty"
printf 'line one\n"quoted" ${x}\n' >"$W/mod/payload.txt"
cat >"$W/in.tftest.hcl" <<'HCL'
override_resource {
  target          = a.b
  override_during = plan
  values          = { id = "x", body = file("payload.txt") }
}

run "first" {
  command = apply

  assert {
    condition     = output.a == "one"
    error_message = "first"
  }
}

run "second" {
  command = plan

  assert {
    condition     = output.b == run.first.a
    error_message = "second"
  }
}
HCL

# tofu-tests.awk: drops override_during, inlines file() as an escaped literal.
gawk -v moddir="$W/mod" -v tofu=false -v exprfile="$W/expr" -v empty="$W/empty" \
  -f "$T/tofu-tests.awk" "$W/in.tftest.hcl" >"$W/out.tftest.hcl"
grep -q override_during "$W/out.tftest.hcl" && fail "override_during must be dropped"
grep -q 'file(' "$W/out.tftest.hcl" && fail "file() must be inlined"
grep -qF 'body = "line one\n\"quoted\" $${x}\n"' "$W/out.tftest.hcl" || fail "file() literal wrong: $(grep body "$W/out.tftest.hcl")"
grep -q 'target          = a.b' "$W/out.tftest.hcl" || fail "other lines must stay"

# tofu-probe.awk: keeps the file level blocks and one run, without its asserts, plus the probe assert.
gawk -v name=first -v path=a -f "$T/tofu-probe.awk" "$W/in.tftest.hcl" >"$W/probe.tftest.hcl"
grep -q 'override_resource' "$W/probe.tftest.hcl" || fail "probe must keep file level blocks"
grep -q 'run "first"' "$W/probe.tftest.hcl" || fail "probe must keep the run"
grep -q 'run "second"' "$W/probe.tftest.hcl" && fail "probe must drop other runs"
grep -q 'output.a == "one"' "$W/probe.tftest.hcl" && fail "probe must drop the run's asserts"
grep -q 'PROBE=' "$W/probe.tftest.hcl" || fail "probe assert missing"

# tofu-refs.awk: replaces run.<name>.<output>, longest reference first, and escapes interpolation.
printf 'run.first.a.b\t{"k":"${v}"}\nrun.first.a\t"one"\n' >"$W/map"
out=$(gawk -v map="$W/map" -f "$T/tofu-refs.awk" "$W/in.tftest.hcl")
grep -q 'run\.first' <<<"$out" && fail "references must be replaced"
grep -qF 'output.b == "one"' <<<"$out" || fail "reference not replaced by its literal"
printf 'x = run.first.a.b\n' | gawk -v map="$W/map" -f "$T/tofu-refs.awk" | grep -qF 'x = {"k":"$${v}"}' || fail "longest reference must win and interpolation be escaped"

echo "tofu_tests_test: ok"
