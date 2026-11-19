#!/usr/bin/env bash
# Tests for tools/leftovers/harvester.sh with a fake kubectl on PATH returning canned output.
# Usage: scripts/tests/leftovers_harvester_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(dirname "$(dirname "$T")")/tools/leftovers/harvester.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-harvester-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/f"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_KC_DIR="$W/f"
: >"$W/kubeconfig"

# Key = resource name; <key>.out is the canned stdout (missing = empty list), <key>.err fails the call.
cat >"$W/bin/kubectl" <<'SH'
#!/bin/sh
d=$FAKE_KC_DIR
echo "$*" >>"$d/calls.log"
key=""
for a in "$@"; do case "$a" in get) ;; virtualmachines.kubevirt.io | persistentvolumeclaims | virtualmachineimages.harvesterhci.io | secrets) key=$a ;; esac; done
[ -n "$key" ] || { echo "unexpected: $*" >&2; exit 9; }
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; exit 1; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; else echo '{"items":[]}'; fi
SH
chmod +x "$W/bin/kubectl"

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
A=(--namespace ns1 --kubeconfig "$W/kubeconfig")

# --- nothing found
reset
run c1 "${A[@]}"
[ "$RC" -eq 0 ] || fail "empty rc=$RC"
has "$OUT" "== c1 (namespace ns1)"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"
has "$(cat "$W/f/calls.log")" "-n ns1 -l elemental-cluster=c1"
has "$(cat "$W/f/calls.log")" "--kubeconfig $W/kubeconfig"
hasnt "$(cat "$W/f/calls.log")" "--context"
noleftover

# --- live objects of every type
reset
echo '{"items":[{"metadata":{"uid":"u-vm","name":"c1-cp-1","creationTimestamp":"2026-01-02T00:00:00Z","labels":{"elemental-created":"20260101-101010"}}}]}' >"$W/f/virtualmachines.kubevirt.io.out"
echo '{"items":[{"metadata":{"uid":"u-pvc","name":"c1-cp-1-root","creationTimestamp":"2026-01-02T00:00:00Z"}}]}' >"$W/f/persistentvolumeclaims.out"
echo '{"items":[{"metadata":{"uid":"u-img","name":"c1-abc"}}]}' >"$W/f/virtualmachineimages.harvesterhci.io.out"
echo '{"items":[{"metadata":{"uid":"u-sec","name":"c1-cp-1-userdata"}}]}' >"$W/f/secrets.out"
run c1 "${A[@]}" --kubecontext harv
[ "$RC" -eq 1 ] || fail "live rc=$RC"
has "$OUT" "LIVE     harvester_virtualmachine"
has "$OUT" "20260101-101010"
has "$OUT" "LIVE     harvester_volume"
has "$OUT" "2026-01-02T00:00:00Z"
has "$OUT" "LIVE     harvester_image"
has "$OUT" "LIVE     harvester_cloudinit_secret"
has "$OUT" "4 live, 0 record, 0 unknown, 0 gone"
has "$(cat "$W/f/calls.log")" "--context harv"
noleftover

# --- kubectl failure and bad JSON are inconclusive
reset
echo 'Unable to connect to the server' >"$W/f/secrets.err"
run c1 "${A[@]}"
[ "$RC" -eq 3 ] || fail "kubectl failure rc=$RC"
has "$OUT" "inconclusive: kubectl get secrets failed"
reset
echo 'not json' >"$W/f/persistentvolumeclaims.out"
run c1 "${A[@]}"
[ "$RC" -eq 3 ] || fail "bad json rc=$RC"
noleftover

# --- unreadable kubeconfig
reset
run c1 --namespace ns1 --kubeconfig "$W/missing"
[ "$RC" -eq 3 ] || fail "missing kubeconfig rc=$RC"
[ ! -e "$W/f/calls.log" ] || fail "kubectl called without kubeconfig"

# --- missing CLI is inconclusive, no usage line. PATH holds only the basic tools the
# script runs before its CLI check: CI runners ship kubectl in /usr/bin.
mkdir -p "$W/nocli"
for c in dirname mktemp rm; do ln -sf "$(command -v "$c")" "$W/nocli/$c"; done
RC=0
PATH="$W/nocli" "$BASH" "$TOOL" c1 "${A[@]}" >"$W/out" 2>&1 || RC=$?
OUT=$(cat "$W/out")
[ "$RC" -eq 3 ] || fail "no CLI rc=$RC"
has "$OUT" "kubectl not installed"
hasnt "$OUT" "usage:"

# --- usage errors
reset
run Bad_Name "${A[@]}"
[ "$RC" -eq 2 ] || fail "invalid name rc=$RC"
run c1 --kubeconfig "$W/kubeconfig"
[ "$RC" -eq 2 ] || fail "missing namespace rc=$RC"
has "$OUT" "--namespace is required"
# no --kubeconfig: kubectl falls back to KUBECONFIG / ~/.kube/config
reset
run c1 --namespace ns1
[ "$RC" -eq 0 ] || fail "no --kubeconfig rc=$RC"
hasnt "$(cat "$W/f/calls.log")" "--kubeconfig"
reset
run c1 "${A[@]}" --region r
[ "$RC" -eq 2 ] || fail "--region rc=$RC"
has "$OUT" "unknown flag: --region"
run c1 --namespace
[ "$RC" -eq 2 ] || fail "--namespace without value rc=$RC"
run -h
[ "$RC" -eq 0 ] || fail "-h rc=$RC"
has "$OUT" "usage:"
[ ! -e "$W/f/calls.log" ] || fail "kubectl called on usage error"

echo "leftovers_harvester_test: ok"
