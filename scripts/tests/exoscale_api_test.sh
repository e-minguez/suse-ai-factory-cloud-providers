#!/usr/bin/env bash
# Tests for modules/exoscale/scripts/exoscale-api.sh with a fake curl on PATH.
# Usage: scripts/tests/exoscale_api_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$T")")"
API="$ROOT/modules/exoscale/scripts/exoscale-api.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/exoscale-api-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin" "$W/api"
export FAKE_API="$W/api" FAKE_LOG="$W/curl.log"

# Fake curl: the body is $FAKE_API/<url path, non-alnum as _>.json and the
# status <same>.code (default 200); a missing body answers 404. Prints the
# body, a newline and the status, as the script's -w '\n%{http_code}' expects.
cat >"$W/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) auth=$2; shift ;;
    -w | --retry) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
path=${url#https://api-*.exoscale.com}
key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9' _)
echo "GET $url $auth" >>"$FAKE_LOG"
code=200
[ -f "$FAKE_API/$key.code" ] && code=$(cat "$FAKE_API/$key.code")
if [ -f "$FAKE_API/$key.json" ]; then cat "$FAKE_API/$key.json"; else code=404; printf '{}'; fi
printf '\n%s' "$code"
FAKE
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
api() { printf '%s' "$2" >"$FAKE_API/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _).json"; }
run() { "$API" <<<"$1"; }

api /v2/instance-type '{"instance-types":[
  {"id":"t-std","family":"standard","size":"large","zones":["de-fra-1"],"gpus":0},
  {"id":"t-gpu","family":"gpu3","size":"small","zones":["de-fra-1"],"gpus":1},
  {"id":"t-vie","family":"gpua5000","size":"small","zones":["at-vie-2"],"gpus":1}]}'
api /v2/quota '{"quotas":[{"resource":"instance","usage":3,"limit":20},{"resource":"gpu3","usage":1,"limit":2}]}'
api /v2/instance '{"instances":[
  {"id":"i-1","name":"c1-cp-abcde-xyzab","labels":{"elemental-cluster":"c1"},"instance-type":{"id":"t-std"},"public-ip":"198.51.100.1"},
  {"id":"i-2","name":"c1-gpu-01","labels":{"elemental-cluster":"c1"},"instance-type":{"id":"t-gpu"},"public-ip":"198.51.100.2"},
  {"id":"i-3","name":"other","labels":{"elemental-cluster":"c2"},"instance-type":{"id":"t-gpu"},"public-ip":"198.51.100.3"},
  {"id":"i-4","name":"c1-cp-abcde-qwert","labels":{"elemental-cluster":"c1"},"instance-type":{"id":"t-std"},"public-ip":"198.51.100.4"}]}'
api /v2/load-balancer '{"load-balancers":[{"id":"l-1","labels":{"elemental-cluster":"c1"}}]}'
api /v2/instance-pool/p-1 '{"id":"p-1","instances":[{"id":"i-1"},{"id":"i-4"}]}'
api /v2/private-network/n-1 '{"id":"n-1","leases":[{"instance-id":"i-1","ip":"10.20.0.11"},{"instance-id":"i-2","ip":"10.20.0.12"}]}'

base='"zone":"de-fra-1","api_key":"EXOtest","api_secret":"s3cret"'

# check: availability per type, quotas, this cluster's existing resources.
out=$(run "{\"mode\":\"check\",$base,\"cluster\":\"c1\",\"types\":\"standard.large,gpu3.small,gpua5000.small,gpu9.huge\"}")
types=$(jq -r .types <<<"$out")
eq "$(jq -c '."standard.large"' <<<"$types")" '{"listed":true,"in_zone":true,"gpus":0}' "listed type in zone"
eq "$(jq -c '."gpua5000.small"' <<<"$types")" '{"listed":true,"in_zone":false,"gpus":1}' "type in another zone"
eq "$(jq -c '."gpu9.huge"' <<<"$types")" '{"listed":false,"in_zone":false,"gpus":0}' "unlisted type"
eq "$(jq -r .quotas <<<"$out" | jq -c .gpu3)" '{"usage":1,"limit":2}' "quota"
eq "$(jq -r .existing <<<"$out" | jq -c .)" '{"instances":3,"gpus":{"gpu3":1},"nlbs":1}' "existing resources"
grep -q 'Authorization: EXO2-HMAC-SHA256 credential=EXOtest,expires=[0-9]*,signature=' "$FAKE_LOG" || fail "request not signed"
grep -q 'https://api-de-fra-1.exoscale.com/v2/quota' "$FAKE_LOG" || fail "zone endpoint not used"

# members: pool members with their privnet lease, sorted by name.
out=$(run "{\"mode\":\"members\",$base,\"pool_id\":\"p-1\",\"network_id\":\"n-1\"}")
eq "$(jq -r .members <<<"$out" | jq -c .)" \
  '[{"id":"i-4","name":"c1-cp-abcde-qwert","public_ip":"198.51.100.4","private_ip":null},{"id":"i-1","name":"c1-cp-abcde-xyzab","public_ip":"198.51.100.1","private_ip":"10.20.0.11"}]' \
  "members"

# Errors: non-200 answers and missing credentials fail with a message.
echo 403 >"$FAKE_API/_v2_quota.code"
if err=$(run "{\"mode\":\"check\",$base,\"cluster\":\"c1\",\"types\":\"\"}" 2>&1); then fail "HTTP 403 accepted"; fi
grep -q 'GET /v2/quota returned HTTP 403' <<<"$err" || fail "403 message: $err"
if err=$(run '{"mode":"check","zone":"de-fra-1"}' 2>&1); then fail "missing credentials accepted"; fi
grep -q 'exoscale_api_key / exoscale_api_secret missing' <<<"$err" || fail "credentials message: $err"

echo "exoscale_api_test: ok"
