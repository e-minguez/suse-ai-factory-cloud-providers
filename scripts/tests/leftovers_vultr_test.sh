#!/usr/bin/env bash
# Tests for tools/leftovers/vultr.sh and the description PUT of
# modules/vultr/scripts/wait-for-snapshot.sh, with a fake curl on PATH.
# Usage: scripts/tests/leftovers_vultr_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$T")")"
TOOL="$ROOT/tools/leftovers/vultr.sh"
WAIT="$ROOT/modules/vultr/scripts/wait-for-snapshot.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-vultr-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin" "$W/tmp" "$W/api"
export TMPDIR="$W/tmp"
export FAKE_API="$W/api" FAKE_LOG="$W/curl.log"

# Fake curl: the response body is $FAKE_API/<url path+query, non-alnum as _>.json,
# the status code <same>.code (default 200); a missing body answers 404. The URL
# is the last argument; -X PUT bodies are logged.
cat >"$W/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out="" method=GET data="" url="" query=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -X) method=$2; shift ;;
    -d) data=$2; shift ;;
    --data-urlencode) query="${query:+$query&}$2"; shift ;;
    -K) cat >>"$FAKE_LOG.auth"; shift ;;
    -w | --max-time | -H) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
path=${url#https://api.vultr.com/v2}${query:+?$query}
key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9' _)
echo "$method $path $data" >>"$FAKE_LOG"
code=200
[ -f "$FAKE_API/$key.code" ] && code=$(cat "$FAKE_API/$key.code")
# PUT answers come from $FAKE_API/put.codes (one code per call, then 200).
if [ "$method" = PUT ] && [ -s "$FAKE_API/put.codes" ]; then
  code=$(head -n 1 "$FAKE_API/put.codes")
  sed '1d' "$FAKE_API/put.codes" >"$FAKE_API/put.codes.n" && mv "$FAKE_API/put.codes.n" "$FAKE_API/put.codes"
  echo '{}' >"$out"
  printf '%s' "$code"
  exit 0
fi
if [ -f "$FAKE_API/$key.json" ]; then cat "$FAKE_API/$key.json" >"$out"; else code=404; echo '{}' >"$out"; fi
printf '%s' "$code"
FAKE
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH"
export VULTR_API_KEY=test-key

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }
# put <path-and-query> <json> [code]
put() {
  local key
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)
  printf '%s\n' "$2" >"$W/api/$key.json"
  if [ -n "${3:-}" ]; then printf '%s' "$3" >"$W/api/$key.code"; fi
}
reset() { rm -f "$W/api"/*; : >"$FAKE_LOG"; }
# run <args...>: sets OUT and RC
run() {
  RC=0
  OUT=$("$BASH" "$TOOL" "$@" 2>&1) || RC=$?
}
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }

P='?per_page=500'
empty_lists() {
  put /account '{"account":{}}'
  put "/instances$P" '{"instances":[],"meta":{"links":{"next":""}}}'
  put "/bare-metals$P" '{"bare_metals":[],"meta":{"links":{"next":""}}}'
  put "/load-balancers$P" '{"load_balancers":[],"meta":{"links":{"next":""}}}'
  put "/firewalls$P" '{"firewall_groups":[],"meta":{"links":{"next":""}}}'
  put "/vpcs$P" '{"vpcs":[],"meta":{"links":{"next":""}}}'
  put "/snapshots$P" '{"snapshots":[],"meta":{"links":{"next":""}}}'
}

# --- nothing found
reset
empty_lists
run prod
[ "$RC" -eq 0 ] || fail "empty: rc $RC: $OUT"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"
noleftover

# --- matches, near misses, pagination
reset
empty_lists
put /account '{"account":{}}'
put "/instances$P" '{"instances":[
  {"id":"i-1","label":"prod-cp-01","tags":["elemental-cluster=prod","elemental-created=20260101-101010"]},
  {"id":"i-2","label":"prod-2-cp-01","tags":["elemental-cluster=prod-2","elemental-created=20260102-101010"]}],
  "meta":{"links":{"next":"c2"}}}'
put "/instances$P&cursor=c2" '{"instances":[
  {"id":"i-3","label":"prod-jumphost","tags":["elemental-cluster=prod","role=x"]}],
  "meta":{"links":{"next":""}}}'
put "/bare-metals$P" '{"bare_metals":[
  {"id":"b-1","label":"prod-gpu-01","tags":["elemental-cluster=prod","elemental-created=20260101-101010"]},
  {"id":"b-2","label":"other","tags":[]}],"meta":{"links":{"next":""}}}'
put "/load-balancers$P" '{"load_balancers":[
  {"id":"lb-1","label":"prod-api-lb"},{"id":"lb-2","label":"prod-ingress-lb"},
  {"id":"lb-3","label":"prod-2-api-lb"},{"id":"lb-4","label":"prod-api-lb-extra"}],
  "meta":{"links":{"next":""}}}'
put "/firewalls$P" '{"firewall_groups":[
  {"id":"fw-1","description":"prod-jumphost"},{"id":"fw-2","description":"prod-control-plane"},
  {"id":"fw-3","description":"prod-agent-cloud"},{"id":"fw-4","description":"prod-2-jumphost"},
  {"id":"fw-5","description":"unrelated"}],"meta":{"links":{"next":""}}}'
put "/vpcs$P" '{"vpcs":[
  {"id":"vpc-1","description":"prod-vpc"},{"id":"vpc-2","description":"prod-2-vpc"}],
  "meta":{"links":{"next":""}}}'
put "/snapshots$P" '{"snapshots":[
  {"id":"s-1","description":"prod-0123456789ab","status":"pending"},
  {"id":"s-2","description":"prod-2-0123456789ab","status":"complete"},
  {"id":"s-3","description":"prod-0123456789abcd","status":"complete"},
  {"id":"s-4","description":"","status":"complete"}],"meta":{"links":{"next":""}}}'
put "/vpcs/vpc-1/nat-gateway$P" '{"nat_gateways":[
  {"id":"n-1","label":"prod-nat","tag":"elemental-cluster=prod"}],"meta":{"links":{"next":""}}}'
run prod
[ "$RC" -eq 1 ] || fail "matches: rc $RC: $OUT"
for id in i-1 i-3 b-1 lb-1 lb-2 fw-1 fw-2 fw-3 vpc-1 s-1 n-1; do has "$OUT" " $id "; done
for id in i-2 b-2 lb-3 lb-4 fw-4 fw-5 vpc-2 s-2 s-3 s-4; do hasnt "$OUT" " $id "; done
has "$OUT" "20260101-101010"
has "$OUT" "11 live, 0 record, 0 unknown, 0 gone"
has "$(cat "$FAKE_LOG")" "/instances?per_page=500&cursor=c2"
hasnt "$(cat "$FAKE_LOG")" "/vpcs/vpc-2/"
hasnt "$OUT" "test-key"
noleftover

# --- account 401
reset
empty_lists
put /account '{"error":"x"}' 401
run prod
[ "$RC" -eq 3 ] || fail "401: rc $RC: $OUT"
has "$OUT" "HTTP 401"
hasnt "$(cat "$FAKE_LOG")" "/instances"

# --- list failure mid-way
reset
empty_lists
put "/load-balancers$P" '{"error":"boom"}' 500
run prod
[ "$RC" -eq 3 ] || fail "list failure: rc $RC: $OUT"
has "$OUT" "/load-balancers"
noleftover

# --- NAT list failure
reset
empty_lists
put "/vpcs$P" '{"vpcs":[{"id":"vpc-1","description":"prod-vpc"}],"meta":{"links":{"next":""}}}'
run prod
[ "$RC" -eq 3 ] || fail "nat failure: rc $RC: $OUT"

# --- missing key, usage
reset
empty_lists
RC=0
OUT=$(env -u VULTR_API_KEY "$BASH" "$TOOL" prod 2>&1) || RC=$?
[ "$RC" -eq 2 ] || fail "missing key: rc $RC: $OUT"
has "$OUT" "VULTR_API_KEY"
run
[ "$RC" -eq 2 ] || fail "no cluster: rc $RC"
run prod --region x
[ "$RC" -eq 2 ] || fail "--region accepted"

# --- suffixes present in the module
suffixes=$(sed -nE 's/^(LB_SUFFIXES|FIREWALL_SUFFIXES|VPC_SUFFIX|NAT_SUFFIX)="([^"]*)"$/\2/p' "$TOOL")
[ -n "$suffixes" ] || fail "no suffixes found in tool"
for s in $suffixes; do
  grep -qF -- "\${var.cluster_name}$s\"" "$ROOT"/modules/vultr/*.tf || fail "suffix $s not in modules/vultr/*.tf"
done

# --- no key in argv: it reaches curl as a config on stdin only
[ -s "$FAKE_LOG.auth" ] || fail "curl got no config on stdin"
has "$(cat "$FAKE_LOG.auth")" 'Authorization: Bearer test-key'
hasnt "$(cat "$FAKE_LOG")" "test-key"

# --- 200 with unexpected JSON shape: inconclusive (3), not jq's exit code
reset
empty_lists
put "/instances$P" '{"instances":[{"id":"i-1","label":"x","tags":5}],"meta":{"links":{"next":""}}}'
run prod
[ "$RC" -eq 3 ] || fail "bad shape: rc $RC: $OUT"
has "$OUT" "inconclusive"
reset
empty_lists
put "/instances$P" 'not json at all'
run prod
[ "$RC" -eq 3 ] || fail "malformed: rc $RC: $OUT"
noleftover

# --- invalid cluster name, missing curl
reset
empty_lists
run Prod_X
[ "$RC" -eq 2 ] || fail "invalid name: rc $RC"
has "$OUT" "invalid cluster name"
RC=0
mkdir "$W/nocurl"; ln -s "$(command -v mktemp)" "$W/nocurl/mktemp"; ln -s "$(command -v rm)" "$W/nocurl/rm"; ln -s "$(command -v dirname)" "$W/nocurl/dirname"
OUT=$(PATH="$W/nocurl" "$BASH" "$TOOL" prod 2>&1) || RC=$?
[ "$RC" -eq 3 ] || fail "no curl: rc $RC: $OUT"
has "$OUT" "not installed"
hasnt "$OUT" "usage:"

# --- wait-for-snapshot.sh description PUT
export SNAPSHOT_ID=snap-9 SNAPSHOT_DESCRIPTION=prod-0123456789ab TIMEOUT_SECONDS=10 POLL_SECONDS=1 PUT_RETRY_SLEEP=0
puts() { grep -c '^PUT ' "$FAKE_LOG" || true; }
reset
put /snapshots/snap-9 '{"snapshot":{"id":"snap-9","status":"complete"}}'
RC=0
OUT=$("$BASH" "$WAIT" 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "put success: rc $RC: $OUT"
has "$(cat "$FAKE_LOG")" 'PUT /snapshots/snap-9 {"description":"prod-0123456789ab"}'
hasnt "$(cat "$FAKE_LOG")" "test-key"
# transient 503 and 000, then success
reset
put /snapshots/snap-9 '{"snapshot":{"id":"snap-9","status":"complete"}}'
printf '503\n000\n' >"$W/api/put.codes"
RC=0
OUT=$("$BASH" "$WAIT" 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "put transient: rc $RC: $OUT"
[ "$(puts)" -eq 3 ] || fail "put transient: expected 3 PUTs, got $(puts)"
# persistent 5xx: fails after 5 attempts
reset
put /snapshots/snap-9 '{"snapshot":{"id":"snap-9","status":"complete"}}'
printf '502\n502\n502\n502\n502\n502\n' >"$W/api/put.codes"
RC=0
OUT=$("$BASH" "$WAIT" 2>&1) || RC=$?
[ "$RC" -ne 0 ] || fail "put persistent 5xx: rc 0"
has "$OUT" "HTTP 502"
[ "$(puts)" -eq 5 ] || fail "put persistent: expected 5 PUTs, got $(puts)"
# 4xx: no retry
reset
put /snapshots/snap-9 '{"snapshot":{"id":"snap-9","status":"complete"}}'
printf '403\n' >"$W/api/put.codes"
RC=0
OUT=$("$BASH" "$WAIT" 2>&1) || RC=$?
[ "$RC" -ne 0 ] || fail "put 403: rc 0"
has "$OUT" "HTTP 403"
[ "$(puts)" -eq 1 ] || fail "put 403: expected 1 PUT, got $(puts)"

echo ok
