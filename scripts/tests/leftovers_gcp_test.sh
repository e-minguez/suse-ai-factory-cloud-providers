#!/usr/bin/env bash
# Tests for tools/leftovers/gcp.sh with a fake gcloud on PATH returning canned JSON.
# Usage: scripts/tests/leftovers_gcp_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(dirname "$T")"
TOOL="$(dirname "$S")/tools/leftovers/gcp.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-gcp-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/f"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_GCLOUD_DIR="$W/f"

# Key = resource words joined by "-" (instances, instance-groups-managed, networks-subnets, ...);
# <key>.out is the canned stdout (missing = []), <key>.err makes the call fail.
cat >"$W/bin/gcloud" <<'SH'
#!/bin/sh
d=$FAKE_GCLOUD_DIR
echo "$*" >>"$d/calls.log"
if [ "$1 $2" = "config get-value" ]; then
  [ ! -f "$d/project" ] || cat "$d/project"
  exit 0
fi
[ "$1" = compute ] || { echo "unexpected: $*" >&2; exit 9; }
shift
key=""
while [ "$1" != list ]; do key="${key:+$key-}$1"; shift; done
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; exit 1; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; else echo '[]'; fi
SH
chmod +x "$W/bin/gcloud"

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2'"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }
reset() { rm -f "$W"/f/*; echo my-proj >"$W/f/project"; }
run() {
  RC=0
  "$BASH" "$TOOL" "$@" >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
}
# line number of the first line containing $2 in $1
lineof() { grep -nF -- "$2" <<<"$1" | head -n 1 | cut -d: -f1; }

U=https://www.googleapis.com/compute/v1/projects/my-proj

# --- nothing left
reset
run c1
[ "$RC" -eq 0 ] || fail "empty rc=$RC"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"
has "$OUT" "== c1 (project my-proj)"
hasnt "$OUT" "gcloud compute"
has "$(cat "$W/f/calls.log")" "--filter=labels.elemental-cluster=c1"
has "$(cat "$W/f/calls.log")" "--filter=name ~ ^c1(-|$)"
has "$(cat "$W/f/calls.log")" "--project my-proj"
noleftover

# --- labelled and unlabelled leftovers, flags and order
reset
echo "[{\"name\":\"c1-cp-1\",\"zone\":\"$U/zones/europe-west4-a\",\"labels\":{\"elemental-created\":\"20260101-101010\"},\"creationTimestamp\":\"2026-01-02T00:00:00.000-00:00\"}]" >"$W/f/instances.out"
echo "[{\"name\":\"c1-cp-1\",\"zone\":\"$U/zones/europe-west4-a\"}]" >"$W/f/disks.out"
echo '[{"name":"c1-snap"}]' >"$W/f/snapshots.out"
echo '[{"name":"c1-0123456789ab"}]' >"$W/f/images.out"
echo "[{\"name\":\"c1-ip\",\"region\":\"$U/regions/europe-west4\"},{\"name\":\"c1-gip\"}]" >"$W/f/addresses.out"
echo "[{\"name\":\"c1-api\",\"region\":\"$U/regions/europe-west4\"},{\"name\":\"c1-glb\"}]" >"$W/f/forwarding-rules.out"
echo "[{\"name\":\"c1-be\",\"region\":\"$U/regions/europe-west4\"}]" >"$W/f/backend-services.out"
echo '[{"name":"c1-hc"}]' >"$W/f/health-checks.out"
echo "[{\"name\":\"c1-ig\",\"zone\":\"$U/zones/europe-west4-a\"}]" >"$W/f/instance-groups-unmanaged.out"
echo "[{\"name\":\"c1-mig\",\"region\":\"$U/regions/europe-west4\"}]" >"$W/f/instance-groups-managed.out"
echo "[{\"name\":\"c1-router\",\"region\":\"$U/regions/europe-west4\"}]" >"$W/f/routers.out"
echo '[{"name":"c1-allow-api"}]' >"$W/f/firewall-rules.out"
echo "[{\"name\":\"c1-subnet\",\"region\":\"$U/regions/europe-west4\"}]" >"$W/f/networks-subnets.out"
echo '[{"name":"c1"}]' >"$W/f/networks.out"
run c1
[ "$RC" -eq 1 ] || fail "leftovers rc=$RC"
has "$OUT" "gcp:instance"
has "$OUT" "europe-west4-a/c1-cp-1"
has "$OUT" "20260101-101010"
has "$OUT" "gcp:network"
has "$OUT" "16 live, 0 record, 0 unknown, 0 gone"
has "$OUT" "europe-west4/c1-ip"
has "$OUT" "global/c1-gip"
has "$OUT" "europe-west4/c1-api"
has "$OUT" "global/c1-glb"
has "$OUT" "europe-west4/c1-be"
has "$OUT" "global/c1-hc"
has "$OUT" "europe-west4-a/c1-ig"
has "$OUT" "europe-west4/c1-mig"
has "$OUT" "europe-west4/c1-router"
has "$OUT" "europe-west4/c1-subnet"
hasnt "$OUT" "global/c1-allow-api"
hasnt "$OUT" "gcloud compute"
hasnt "$OUT" "Suggested cleanup"
noleftover

# --- only unlabelled leftover: still reported
reset
echo '[{"name":"c1-vpc","creationTimestamp":"2026-03-03T00:00:00.000-00:00"}]' >"$W/f/networks.out"
run c1 --project other
[ "$RC" -eq 1 ] || fail "network only rc=$RC"
has "$OUT" "2026-03-03T00:00:00.000-00:00"
has "$OUT" "c1-vpc"
has "$OUT" "== c1 (project other)"
has "$(cat "$W/f/calls.log")" "--project other"
hasnt "$(cat "$W/f/calls.log")" "config get-value"

# --- inconclusive: no project, list failure, bad JSON
reset
rm "$W/f/project"
run c1
[ "$RC" -eq 3 ] || fail "no project rc=$RC"
has "$OUT" "no project"
reset
echo "(unset)" >"$W/f/project"
run c1
[ "$RC" -eq 3 ] || fail "unset project rc=$RC"
reset
echo "ERROR: (gcloud) Compute Engine API has not been used" >"$W/f/disks.err"
run c1
[ "$RC" -eq 3 ] || fail "list failure rc=$RC"
has "$OUT" "disk list failed: ERROR: (gcloud) Compute Engine API"
noleftover
reset
echo 'not json' >"$W/f/instances.out"
run c1
[ "$RC" -eq 3 ] || fail "bad json rc=$RC"

# --- gcloud missing: inconclusive, no usage line
reset
# /usr/bin minus gcloud: CI runner images ship gcloud in /usr/bin.
mkdir -p "$W/nocli"
for f in /usr/bin/* /bin/*; do
  n="$W/nocli/${f##*/}"
  # -L too: dangling links exist on runner images and fail -e.
  [ "${f##*/}" = gcloud ] || [ -e "$n" ] || [ -L "$n" ] || ln -s "$f" "$n"
done
RC=0
OUT=$(PATH="$W/nocli" "$BASH" "$TOOL" c1 2>&1) || RC=$?
[ "$RC" -eq 3 ] || fail "no CLI rc=$RC"
has "$OUT" "gcloud not installed"
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
run c1 --project "x' || true"
[ "$RC" -eq 2 ] || fail "bad project rc=$RC"
run c1 --project
[ "$RC" -eq 2 ] || fail "--project without value rc=$RC"
run -h
[ "$RC" -eq 0 ] || fail "-h rc=$RC"
has "$OUT" "usage:"
[ ! -e "$W/f/calls.log" ] || fail "gcloud called on usage error"

echo "leftovers_gcp_test: ok"
