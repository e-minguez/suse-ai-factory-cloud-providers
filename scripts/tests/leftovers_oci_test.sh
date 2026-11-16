#!/usr/bin/env bash
# Tests for tools/leftovers/oci.sh with a fake oci on PATH returning canned output.
# Usage: scripts/tests/leftovers_oci_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(dirname "$T")"
TOOL="$(dirname "$S")/tools/leftovers/oci.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-oci-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/f"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_OCI_DIR="$W/f"

# Key: search | ns | bucket | objects | pars | images; <key>.out is the canned stdout (missing =
# empty), <key>.err makes the call fail with that message.
cat >"$W/bin/oci" <<'SH'
#!/bin/sh
d=$FAKE_OCI_DIR
echo "$*" >>"$d/calls.log"
while [ "$1" = --region ]; do shift 2; done
case "$1 $2 $3" in
  "search resource structured-search")
    case " $* " in *" --all "*) echo "Error: No such option '--all'." >&2; exit 2 ;; esac
    key=search
    case " $* " in *" --page "*) key=search-page2 ;; esac ;;
  "os ns get"*) key=ns ;;
  "os bucket get") key=bucket ;;
  "os object list") key=objects ;;
  "os preauth-request list") key=pars ;;
  "compute image list") key=images ;;
  "compute image get") key=image-get ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; exit 1; fi
[ ! -f "$d/$key.out" ] || cat "$d/$key.out"
exit 0
SH
chmod +x "$W/bin/oci"

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2'"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }
reset() { rm -f "$W"/f/*; echo ns1 >"$W/f/ns.out"; echo 'BucketNotFound: not found' >"$W/f/bucket.err"; }
run() {
  RC=0
  "$BASH" "$TOOL" "$@" >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
}

CMP=ocid1.compartment.oc1..aaaa

# --- mix: live, gone, tag-based created stamp
reset
cat >"$W/f/search.out" <<'JSON'
{"data":{"items":[
 {"identifier":"ocid1.instance.oc1.eu.live","resource-type":"Instance","display-name":"c1-cp-1","lifecycle-state":"RUNNING","time-created":"2026-01-02T00:00:00+00:00","freeform-tags":{"elemental-created":"20260101-101010"}},
 {"identifier":"ocid1.instance.oc1.eu.dead","resource-type":"Instance","display-name":"c1-cp-2","lifecycle-state":"TERMINATED","freeform-tags":{}},
 {"identifier":"ocid1.vcn.oc1.eu.v1","resource-type":"Vcn","display-name":"c1-vcn","lifecycle-state":"AVAILABLE","time-created":"2026-01-02T00:00:00+00:00"},
 {"identifier":"ocid1.image.oc1.eu.gone","resource-type":"Image","display-name":"c1-abc","lifecycle-state":"DELETED"}
]}}
JSON
run c1 --region eu-frankfurt-1
[ "$RC" -eq 1 ] || fail "mix rc=$RC"
has "$OUT" "LIVE     oci:Instance"
has "$OUT" "ocid1.instance.oc1.eu.live"
has "$OUT" "20260101-101010"
has "$OUT" "oci:Vcn"
has "$OUT" "2026-01-02T00:00:00+00:00"
hasnt "$OUT" "ocid1.instance.oc1.eu.dead"
hasnt "$OUT" "ocid1.image.oc1.eu.gone"
has "$OUT" "== c1 (region eu-frankfurt-1)"
has "$OUT" "2 live, 0 record, 0 unknown, 2 gone"
has "$(cat "$W/f/calls.log")" "--region eu-frankfurt-1"
has "$(cat "$W/f/calls.log")" "freeformTags.key = 'elemental-cluster' && freeformTags.value = 'c1')"
noleftover
run c1 --region eu-frankfurt-1 --all
has "$OUT" "gone     oci:Instance"
has "$OUT" "ocid1.instance.oc1.eu.dead"

# --- a Search image row is checked against Compute (the index lags)
reset
echo '{"data":{"items":[{"identifier":"ocid1.image.oc1.eu.stale","resource-type":"Image","display-name":"c1-abc","lifecycle-state":"AVAILABLE"}]}}' >"$W/f/search.out"
echo DELETED >"$W/f/image-get.out"
run c1
[ "$RC" -eq 0 ] || fail "stale image rc=$RC"
has "$OUT" "0 live, 0 record, 0 unknown, 1 gone"
echo AVAILABLE >"$W/f/image-get.out"
run c1
[ "$RC" -eq 1 ] || fail "live image rc=$RC"
has "$OUT" "LIVE     oci:Image"
rm "$W/f/image-get.out"; echo 'ServiceError: {"code": "NotAuthorizedOrNotFound"}' >"$W/f/image-get.err"
run c1
has "$OUT" "0 live, 0 record, 0 unknown, 1 gone"
echo 'ServiceError: {"code": "TooManyRequests"}' >"$W/f/image-get.err"
run c1
has "$OUT" "UNKNOWN  oci:Image"

# --- search paging: opc-next-page is followed and the pages merged
reset
cat >"$W/f/search.out" <<'JSON'
{"data":{"items":[{"identifier":"ocid1.vcn.oc1.eu.p1","resource-type":"Vcn","display-name":"c1-vcn","lifecycle-state":"AVAILABLE"}]},"opc-next-page":"tok2"}
JSON
cat >"$W/f/search-page2.out" <<'JSON'
{"data":{"items":[{"identifier":"ocid1.subnet.oc1.eu.p2","resource-type":"Subnet","display-name":"c1-private","lifecycle-state":"AVAILABLE"}]}}
JSON
run c1
[ "$RC" -eq 1 ] || fail "paging rc=$RC"
has "$OUT" "ocid1.vcn.oc1.eu.p1"
has "$OUT" "ocid1.subnet.oc1.eu.p2"
has "$(cat "$W/f/calls.log")" "--page tok2"
noleftover

# --- the CLI error line is reported, not a leading blank line
reset
printf '\nUsage: oci search resource structured-search [OPTIONS]\n\nError: boom\n' >"$W/f/search.err"
run c1
[ "$RC" -eq 3 ] || fail "search error rc=$RC"
has "$OUT" "search failed: Error: boom"

# --- compartment filter in the query; image by name, deduplicated against search
reset
cat >"$W/f/search.out" <<'JSON'
{"data":{"items":[{"identifier":"ocid1.image.oc1.eu.i1","resource-type":"Image","display-name":"c1-abc","lifecycle-state":"AVAILABLE"}]}}
JSON
cat >"$W/f/images.out" <<'JSON'
{"data":[
 {"id":"ocid1.image.oc1.eu.i1","display-name":"c1-0123456789ab","lifecycle-state":"AVAILABLE"},
 {"id":"ocid1.image.oc1.eu.i2","display-name":"c1-abcdef012345","lifecycle-state":"AVAILABLE","time-created":"2026-02-02T00:00:00+00:00"},
 {"id":"ocid1.image.oc1.eu.i3","display-name":"c1-fedcba987654","lifecycle-state":"DELETED"},
 {"id":"ocid1.image.oc1.eu.i4","display-name":"c1-gpu-0123456789ab","lifecycle-state":"AVAILABLE"}
]}
JSON
run c1 --compartment "$CMP"
[ "$RC" -eq 1 ] || fail "compartment rc=$RC"
has "$(cat "$W/f/calls.log")" "compartmentId = '$CMP'"
has "$OUT" "oci:image"
has "$OUT" "ocid1.image.oc1.eu.i2"
hasnt "$OUT" "ocid1.image.oc1.eu.i4"
has "$OUT" "2 live, 0 record, 0 unknown, 1 gone"
has "$OUT" "== c1 (default region, compartment $CMP)"
hasnt "$(cat "$W/f/calls.log")" "--region"

# --- build bucket with objects and PARs; search row for the bucket is not duplicated
reset
rm "$W/f/bucket.err"
echo '{"data":{"name":"c1-build","time-created":"2026-01-01T00:00:00+00:00"}}' >"$W/f/bucket.out"
echo '{"data":[{"name":"images/c1-abc.qcow2"}]}' >"$W/f/objects.out"
echo '{"data":[{"id":"par1","name":"c1-write-qcow"}]}' >"$W/f/pars.out"
echo '{"data":{"items":[{"identifier":"ocid1.bucket.x","resource-type":"Bucket","display-name":"c1-build","lifecycle-state":"ACTIVE"}]}}' >"$W/f/search.out"
run c1
[ "$RC" -eq 1 ] || fail "bucket rc=$RC"
has "$OUT" "oci:bucket"
has "$OUT" "oci:object"
has "$OUT" "c1-build/images/c1-abc.qcow2"
has "$OUT" "oci:par"
hasnt "$OUT" "oci:Bucket"
has "$OUT" "3 live, 0 record, 0 unknown, 0 gone"

# --- bucket check failing for another reason is UNKNOWN; list failures too
reset
echo "NotAuthorizedOrNotFound" >"$W/f/bucket.err"
run c1
[ "$RC" -eq 1 ] || fail "bucket unknown rc=$RC"
has "$OUT" "UNKNOWN  oci:bucket"
reset
rm "$W/f/bucket.err"
echo '{"data":{"name":"c1-build"}}' >"$W/f/bucket.out"
echo "ServiceError" >"$W/f/objects.err"
run c1
has "$OUT" "UNKNOWN  oci:object"
has "$OUT" "1 live, 0 record, 1 unknown, 0 gone"

# --- clean: empty search, empty or missing output
reset
run c1
[ "$RC" -eq 0 ] || fail "empty rc=$RC"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"
echo '{"data":{"items":[]}}' >"$W/f/search.out"
run c1
[ "$RC" -eq 0 ] || fail "empty items rc=$RC"

# --- search failure, namespace failure, bad JSON are inconclusive
reset
echo "NotAuthenticated" >"$W/f/search.err"
run c1
[ "$RC" -eq 3 ] || fail "search failure rc=$RC"
has "$OUT" "inconclusive"
noleftover
reset
echo "config error" >"$W/f/ns.err"
run c1
[ "$RC" -eq 3 ] || fail "ns failure rc=$RC"
reset
echo 'not json' >"$W/f/search.out"
run c1
[ "$RC" -eq 3 ] || fail "bad json rc=$RC"

# --- missing CLI is inconclusive, no usage line
reset
RC=0
OUT=$(PATH="/usr/bin:/bin" "$BASH" "$TOOL" c1 2>&1) || RC=$?
[ "$RC" -eq 3 ] || fail "no CLI rc=$RC"
has "$OUT" "oci not installed"
hasnt "$OUT" "usage:"

# --- usage errors
reset
rm -f "$W/f/calls.log"
run Bad_Name
[ "$RC" -eq 2 ] || fail "invalid name rc=$RC"
run
[ "$RC" -eq 2 ] || fail "missing cluster rc=$RC"
has "$OUT" "cluster name missing"
run c1 --project p
[ "$RC" -eq 2 ] || fail "--project rc=$RC"
has "$OUT" "unknown flag: --project"
run c1 --compartment "x' || true"
[ "$RC" -eq 2 ] || fail "bad compartment rc=$RC"
run c1 --region
[ "$RC" -eq 2 ] || fail "--region without value rc=$RC"
run -h
[ "$RC" -eq 0 ] || fail "-h rc=$RC"
has "$OUT" "usage:"
[ ! -e "$W/f/calls.log" ] || fail "oci called on usage error"

echo "leftovers_oci_test: ok"
