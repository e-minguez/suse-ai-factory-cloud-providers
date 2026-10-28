#!/usr/bin/env bash
# Tests for tools/leftovers/evroc.sh with a fake evroc CLI on PATH returning canned JSON.
# Usage: scripts/tests/leftovers_evroc_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(dirname "$(dirname "$T")")"
TOOL="$R/tools/leftovers/evroc.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-evroc-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/f" "$W/home"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export HOME="$W/home"
export FAKE_EVROC_DIR="$W/f"
unset EVROC_CONFIG_FILE EVROC_TOKEN EVROC_REFRESH_TOKEN EVROC_SERVICE_ACCOUNT_SECRET EVROC_PASSWORD EVROC_REGION EVROC_PROJECT
mkdir "$W/home/.evroc"
: >"$W/home/.evroc/config.yaml"

# `evroc <group> <resource> list ...`: canned output from $FAKE_EVROC_DIR/<resource>.json
# (missing = empty list), <resource>.err makes the call fail. Ignores the label selector, so
# near-miss clusters come back and the tool's own filter is exercised.
cat >"$W/bin/evroc" <<'SH'
#!/bin/sh
d=$FAKE_EVROC_DIR
echo "REGION=${EVROC_REGION:-} PROJECT=${EVROC_PROJECT:-} $*" >>"$d/calls.log"
while [ "$1" = --config ]; do shift 2; done
res=$2
if [ -f "$d/$res.err" ]; then cat "$d/$res.err" >&2; exit 1; fi
if [ -f "$d/$res.json" ]; then cat "$d/$res.json"; else echo '{"items":[]}'; fi
SH
chmod +x "$W/bin/evroc"

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2'"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }
reset() { rm -f "$W"/f/*; }
run() {
  RC=0
  "$BASH" "$TOOL" "$@" >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
}
# item <id> <zone> <cluster> [created]
item() {
  printf '{"metadata":{"id":"%s","userLabels":{"elemental-cluster":"%s","elemental-created":"%s"}},"spec":{"placement":{"zone":"%s"}}}' \
    "$1" "$3" "${4:-20260101-101010}" "$2"
}

# --- matches in two zones; near-miss cluster not matched
reset
echo "{\"items\":[$(item prod-cp-a a prod),$(item prod-cp-b b prod),$(item prod-2-cp-a a prod-2)]}" >"$W/f/virtualmachine.json"
echo "[$(item prod-disk-a a prod 20260202-020202),$(item prod-2-disk a prod-2)]" >"$W/f/disk.json"
echo "{\"items\":[{\"metadata\":{\"id\":\"prod-lb\",\"userLabels\":{\"elemental-cluster\":\"prod\"}},\"spec\":{}}]}" >"$W/f/loadbalancer.json"
run prod
[ "$RC" -eq 1 ] || fail "found: rc $RC"
has "$OUT" "LIVE     evroc_virtual_machine"
has "$OUT" "prod-cp-a"
has "$OUT" "prod-cp-b"
has "$OUT" "zone=b"
has "$OUT" "prod-disk-a"
has "$OUT" "20260202-020202"
has "$OUT" "prod-lb"
hasnt "$OUT" "prod-2"
has "$OUT" "4 live, 0 record, 0 unknown, 0 gone"
has "$(cat "$W/f/calls.log")" "compute virtualmachine list -l elemental-cluster=prod -o json"
has "$(cat "$W/f/calls.log")" "networking virtualprivatecloud list"
has "$(cat "$W/f/calls.log")" "loadbalancer l4route list"
noleftover

# --- region flag reaches the CLI
reset
run prod --region se-sto
[ "$RC" -eq 0 ] || fail "region: rc $RC"
has "$(head -n 1 "$W/f/calls.log")" "REGION=se-sto "
has "$OUT" "region se-sto"
has "$OUT" "project from login"

# --- project flag reaches the CLI and the report header
reset
run prod --project p-1 --region se-sto
[ "$RC" -eq 0 ] || fail "project: rc $RC"
has "$(head -n 1 "$W/f/calls.log")" "REGION=se-sto PROJECT=p-1 "
has "$OUT" "== prod (project p-1, region se-sto)"

# --- labels at another path: inconclusive, not silently dropped
reset
echo "{\"items\":[{\"metadata\":{\"id\":\"prod-cp-a\",\"labels\":{\"elemental-cluster\":\"prod\"}},\"spec\":{}}]}" >"$W/f/virtualmachine.json"
run prod
[ "$RC" -eq 3 ] || fail "label path: rc $RC"
has "$OUT" "label path unverified (evroc_virtual_machine)"
hasnt "$OUT" "live,"
noleftover

# --- missing CLI is inconclusive, no usage line
reset
RC=0
OUT=$(PATH="/usr/bin:/bin" "$BASH" "$TOOL" prod 2>&1) || RC=$?
[ "$RC" -eq 3 ] || fail "no CLI: rc $RC"
has "$OUT" "evroc not installed"
hasnt "$OUT" "usage:"

# --- invalid cluster name
run Prod_1
[ "$RC" -eq 2 ] || fail "invalid name: rc $RC"
has "$OUT" "invalid cluster name"
run -prod
[ "$RC" -eq 2 ] || fail "leading dash: rc $RC"

# --- nothing found
reset
run prod
[ "$RC" -eq 0 ] || fail "none: rc $RC"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"
noleftover

# --- credentials missing
reset
mv "$W/home/.evroc/config.yaml" "$W/home/.evroc/config.yaml.off"
run prod
mv "$W/home/.evroc/config.yaml.off" "$W/home/.evroc/config.yaml"
[ "$RC" -eq 3 ] || fail "auth: rc $RC"
has "$OUT" "no evroc credentials"
[ ! -s "$W/f/calls.log" ] || fail "auth: CLI called without credentials"
EVROC_TOKEN=x
export EVROC_TOKEN
mv "$W/home/.evroc/config.yaml" "$W/home/.evroc/config.yaml.off"
run prod
mv "$W/home/.evroc/config.yaml.off" "$W/home/.evroc/config.yaml"
unset EVROC_TOKEN
[ "$RC" -eq 0 ] || fail "token env: rc $RC"
noleftover

# --- list failure (also an expired login) is inconclusive, never "nothing left"
reset
echo "error: token refresh failed" >"$W/f/snapshot.err"
echo "{\"items\":[$(item prod-cp-a a prod)]}" >"$W/f/virtualmachine.json"
run prod
[ "$RC" -eq 3 ] || fail "list failure: rc $RC"
has "$OUT" "inconclusive: evroc compute snapshot list failed"
has "$OUT" "token refresh failed"
hasnt "$OUT" "live,"
noleftover

# --- unreadable output is inconclusive
reset
echo "not json" >"$W/f/disk.json"
run prod
[ "$RC" -eq 3 ] || fail "bad json: rc $RC"

# --- usage errors
for args in "" "--zone a prod" "prod --bogus" "prod other" "prod --region"; do
  # shellcheck disable=SC2086  # word splitting of the case args is intended
  run $args
  [ "$RC" -eq 2 ] || fail "usage '$args': rc $RC"
  has "$OUT" "usage:"
done
run --help
[ "$RC" -eq 0 ] || fail "help rc $RC"

# --- the tool's type table matches the module
declared=$(grep -hEo '^resource "evroc_[a-z0-9_]+"' "$R"/modules/evroc/*.tf | cut -d'"' -f2 | sort -u)
listed=$("$TOOL" --list-types | sort -u)
for t in $listed; do
  grep -qx "$t" <<<"$declared" || fail "table type $t is not declared in modules/evroc"
done
for t in $declared; do
  # unlabelled: attachments carry no user_labels
  [ "$t" = evroc_hotswap_disk_attachment ] && continue
  grep -qx "$t" <<<"$listed" || fail "module declares $t but tools/leftovers/evroc.sh does not list it"
done

echo "leftovers evroc tests passed"
