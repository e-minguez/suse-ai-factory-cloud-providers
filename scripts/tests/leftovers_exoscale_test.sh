#!/usr/bin/env bash
# Tests for tools/leftovers/exoscale.sh with a fake curl on PATH.
# Usage: scripts/tests/leftovers_exoscale_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$T")")"
TOOL="$ROOT/tools/leftovers/exoscale.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-exoscale-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin" "$W/tmp" "$W/api"
export TMPDIR="$W/tmp"
export FAKE_API="$W/api" FAKE_LOG="$W/curl.log"

# Fake curl: the body is $FAKE_API/<url path+query, non-alnum as _>.json, the
# status <same>.code (default 200); a missing body answers 404. -K - reads the
# Authorization header from stdin, which is logged.
cat >"$W/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -K) cat >>"$FAKE_LOG.auth"; shift ;;
    -w | --max-time) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
path=${url#https://api-*.exoscale.com/v2}
key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9' _)
echo "GET $url" >>"$FAKE_LOG"
code=200
[ -f "$FAKE_API/$key.code" ] && code=$(cat "$FAKE_API/$key.code")
if [ -f "$FAKE_API/$key.json" ]; then cat "$FAKE_API/$key.json" >"$out"; else code=404; echo '{}' >"$out"; fi
printf '%s' "$code"
FAKE
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH"
export EXOSCALE_API_KEY=EXOtest EXOSCALE_API_SECRET=s3cret

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }
api() { printf '%s' "$2" >"$FAKE_API/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _).json"; }

empty() {
  api /quota '{"quotas":[]}'
  api /instance '{"instances":[]}'
  api /instance-pool '{"instance-pools":[]}'
  api /load-balancer '{"load-balancers":[]}'
  api /private-network '{"private-networks":[]}'
  api /security-group '{"security-groups":[{"id":"sg-default","name":"default"}]}'
  api /anti-affinity-group '{"anti-affinity-groups":[]}'
  api '/template?visibility=private' '{"templates":[]}'
}

# --- clean zone: exit 0, signed requests to the zone endpoint.
empty
out=$("$TOOL" c1 --region ch-gva-2) || fail "clean: exit $?"
has "$out" "0 live, 0 record, 0 unknown"
has "$out" "== c1 (ch-gva-2)"
grep -q 'https://api-ch-gva-2.exoscale.com/v2/quota' "$FAKE_LOG" || fail "zone endpoint not used"
grep -q 'EXO2-HMAC-SHA256 credential=EXOtest,expires=' "$FAKE_LOG.auth" || fail "request not signed"
grep -q 'credential=EXOtest,signed-query-args=visibility,expires=' "$FAKE_LOG.auth" || fail "template query not signed"

# --- leftovers: labelled objects of c1 and named objects; other clusters ignored.
api /instance '{"instances":[
  {"id":"i-1","name":"c1-cp-abcde-xyzab","labels":{"elemental-cluster":"c1","elemental-created":"20261006-101010"}},
  {"id":"i-2","name":"c10-gpu-01","labels":{"elemental-cluster":"c10"}}]}'
api /instance-pool '{"instance-pools":[{"id":"p-1","name":"c1-cp","labels":{"elemental-cluster":"c1"}}]}'
api /load-balancer '{"load-balancers":[{"id":"l-1","name":"c1-lb","labels":{"elemental-cluster":"c1"}}]}'
api /private-network '{"private-networks":[{"id":"n-1","name":"c1-net","labels":{"elemental-cluster":"c1"}}]}'
api /security-group '{"security-groups":[{"id":"sg-1","name":"c1-jumphost"},{"id":"sg-2","name":"c1-agent"},{"id":"sg-3","name":"c10-agent"}]}'
api /anti-affinity-group '{"anti-affinity-groups":[{"id":"a-1","name":"c1-control-plane"}]}'
api '/template?visibility=private' '{"templates":[
  {"id":"t-1","name":"c1-0123456789ab","created-at":"2026-10-06T10:00:00Z"},
  {"id":"t-2","name":"c1-gpu-custom"}]}'
rc=0
out=$("$TOOL" c1) || rc=$?
[ "$rc" -eq 1 ] || fail "leftovers: exit $rc"
has "$out" "== c1 (de-fra-1)"
has "$out" "8 live"
for id in i-1 p-1 l-1 n-1 sg-1 sg-2 a-1 t-1; do has "$out" "$id"; done
hasnt "$out" "i-2"
hasnt "$out" "sg-3"
hasnt "$out" "t-2"
has "$out" "20261006-101010"

# --- inconclusive: bad credentials, missing variables.
empty
echo 403 >"$FAKE_API/_quota.code"
rc=0
"$TOOL" c1 >/dev/null 2>"$W/err" || rc=$?
[ "$rc" -eq 3 ] || fail "403: exit $rc"
grep -q 'credential check GET /v2/quota returned HTTP 403' "$W/err" || fail "403 message"
rm -f "$FAKE_API/_quota.code"
rc=0
EXOSCALE_API_SECRET="" "$TOOL" c1 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "missing secret: exit $rc"

# --- the name suffixes match the module.
for s in -jumphost -control-plane -agent; do
  grep -qF "\"\${var.cluster_name}$s\"" "$ROOT"/modules/exoscale/*.tf || fail "suffix $s not in modules/exoscale"
done

echo "leftovers_exoscale_test: ok"
