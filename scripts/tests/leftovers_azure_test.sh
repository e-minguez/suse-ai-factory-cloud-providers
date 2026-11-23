#!/usr/bin/env bash
# Tests for tools/leftovers/azure.sh with a fake az on PATH returning canned output.
# Usage: scripts/tests/leftovers_azure_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(dirname "$T")"
TOOL="$(dirname "$S")/tools/leftovers/azure.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-azure-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/f"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_AZ_DIR="$W/f"

# Key: tagged | rg | inrg; <key>.out is the canned stdout (missing = []), <key>.err makes the
# call fail with that message.
cat >"$W/bin/az" <<'SH'
#!/bin/sh
d=$FAKE_AZ_DIR
echo "$*" >>"$d/calls.log"
case "$1 $2" in
  "resource list")
    key=tagged
    case " $* " in *" --resource-group "*) key=inrg ;; esac ;;
  "group show") key=rg ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; exit 1; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; else echo '[]'; fi
exit 0
SH
chmod +x "$W/bin/az"

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2'"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }
reset() { rm -f "$W"/f/*; echo 'ERROR: (ResourceGroupNotFound) Resource group could not be found.' >"$W/f/rg.err"; }
run() {
  RC=0
  "$BASH" "$TOOL" "$@" >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
}

SUB=00000000-0000-0000-0000-000000000000
RGID=/subscriptions/$SUB/resourceGroups/c1

# --- clean
reset
run c1
[ "$RC" -eq 0 ] || fail "clean rc=$RC"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"
has "$OUT" "== c1 (default subscription)"
has "$(cat "$W/f/calls.log")" "resource list --tag elemental-cluster=c1"
hasnt "$(cat "$W/f/calls.log")" "--subscription"
noleftover

# --- module-created tagged group: in-group rows deduplicated
reset
rm "$W/f/rg.err"
echo '{"id":"'"$RGID"'","name":"c1","tags":{"elemental-cluster":"c1","elemental-created":"20260101-101010"}}' >"$W/f/rg.out"
cat >"$W/f/tagged.out" <<JSON
[{"id":"$RGID/providers/Microsoft.Compute/virtualMachines/c1-cp-1","type":"Microsoft.Compute/virtualMachines","name":"c1-cp-1","tags":{"elemental-created":"20260101-101010"}}]
JSON
cat >"$W/f/inrg.out" <<JSON
[{"id":"$RGID/providers/Microsoft.Compute/virtualMachines/c1-cp-1","type":"Microsoft.Compute/virtualMachines","name":"c1-cp-1"},
 {"id":"$RGID/providers/Microsoft.Network/networkInterfaces/c1-nic","type":"Microsoft.Network/networkInterfaces","name":"c1-nic","createdTime":"2026-01-02T00:00:00Z"}]
JSON
run c1 --project "$SUB"
[ "$RC" -eq 1 ] || fail "group rc=$RC"
has "$OUT" "== c1 (subscription $SUB)"
has "$OUT" "azure:resourceGroup"
has "$OUT" "azure:Microsoft.Compute/virtualMachines"
has "$OUT" "azure:Microsoft.Network/networkInterfaces"
has "$OUT" "2026-01-02T00:00:00Z"
has "$OUT" "3 live, 0 record, 0 unknown, 0 gone"
hasnt "$OUT" "az group delete"
hasnt "$OUT" "az resource delete"
hasnt "$OUT" "Suggested cleanup"
has "$(cat "$W/f/calls.log")" "--subscription $SUB"
[ "$(grep -c 'virtualMachines/c1-cp-1' <<<"$OUT")" -eq 1 ] || fail "VM listed twice"
noleftover

# --- untagged group: group and contents are UNKNOWN, never LIVE
reset
rm "$W/f/rg.err"
echo '{"id":"'"$RGID"'","name":"c1","tags":null}' >"$W/f/rg.out"
echo '[{"id":"'"$RGID"'/providers/Microsoft.Compute/disks/c1-disk","type":"Microsoft.Compute/disks","name":"c1-disk"}]' >"$W/f/inrg.out"
run c1
[ "$RC" -eq 1 ] || fail "untagged group rc=$RC"
has "$OUT" "0 live, 0 record, 2 unknown, 0 gone"
hasnt "$OUT" "LIVE"
hasnt "$OUT" "az group delete"
hasnt "$OUT" "az resource delete"

# --- resources in a user-supplied group (tag only, no group c1)
reset
echo '[{"id":"/subscriptions/'"$SUB"'/resourceGroups/shared/providers/Microsoft.Network/publicIPAddresses/c1-ip","type":"Microsoft.Network/publicIPAddresses","name":"c1-ip"}]' >"$W/f/tagged.out"
run c1
[ "$RC" -eq 1 ] || fail "shared rc=$RC"
has "$OUT" "1 live, 0 record, 0 unknown, 0 gone"
hasnt "$OUT" "az group delete"
hasnt "$OUT" "az resource delete"

# --- group exists but listing it fails: UNKNOWN
reset
rm "$W/f/rg.err"
echo '{"id":"'"$RGID"'","name":"c1"}' >"$W/f/rg.out"
echo "ERROR: boom" >"$W/f/inrg.err"
run c1
[ "$RC" -eq 1 ] || fail "inrg failure rc=$RC"
has "$OUT" "UNKNOWN"

# --- failures are inconclusive
reset
echo "ERROR: Please run 'az login'" >"$W/f/tagged.err"
run c1
[ "$RC" -eq 3 ] || fail "list failure rc=$RC"
has "$OUT" "inconclusive: resource list failed: ERROR: Please run 'az login'"
noleftover
reset
echo "ERROR: (AuthorizationFailed) denied" >"$W/f/rg.err"
run c1
[ "$RC" -eq 3 ] || fail "group failure rc=$RC"
reset
echo 'not json' >"$W/f/tagged.out"
run c1
[ "$RC" -eq 3 ] || fail "bad json rc=$RC"

# --- missing CLI is inconclusive, no usage line
reset
RC=0
OUT=$(PATH="/usr/bin:/bin" "$BASH" "$TOOL" c1 2>&1) || RC=$?
[ "$RC" -eq 3 ] || fail "no CLI rc=$RC"
has "$OUT" "az not installed"
hasnt "$OUT" "usage:"

# --- usage errors
reset
rm -f "$W/f/calls.log"
run Bad_Name
[ "$RC" -eq 2 ] || fail "invalid name rc=$RC"
run
[ "$RC" -eq 2 ] || fail "missing cluster rc=$RC"
run c1 --region eu
[ "$RC" -eq 2 ] || fail "--region rc=$RC"
has "$OUT" "unknown flag: --region"
run c1 --project "x' || true"
[ "$RC" -eq 2 ] || fail "bad subscription rc=$RC"
run -h
[ "$RC" -eq 0 ] || fail "-h rc=$RC"
has "$OUT" "usage:"
[ ! -e "$W/f/calls.log" ] || fail "az called on usage error"

echo "leftovers_azure_test: ok"
