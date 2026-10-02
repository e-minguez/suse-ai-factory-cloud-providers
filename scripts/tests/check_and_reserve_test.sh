#!/usr/bin/env bash
# Tests for modules/aws/scripts/check-and-reserve.sh with a fake aws CLI on PATH.
# Usage: scripts/tests/check_and_reserve_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$T/../../modules/aws/scripts/check-and-reserve.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/car-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir "$W/bin"
export FAKE_AWS_LOG="$W/aws.log"

# Fake aws: g6.xlarge $0.80, g5.xlarge $1.00, p5.48xlarge $98 (over any test limit),
# g5g is arm64 (filtered by the API, so absent here). Capacity: FAKE_CAPACITY lists
# "type az" pairs that succeed; FAKE_CREATE_ERR overrides the failure message.
cat >"$W/bin/aws" <<'A'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_AWS_LOG"
price() { jq -cn --arg t "$1" --arg p "$2" '{product: {attributes: {instanceType: $t}}, terms: {OnDemand: {x: {priceDimensions: {y: {pricePerUnit: {USD: $p}}}}}}} | tojson'; }
case "$1 $2" in
  "sts get-caller-identity") echo '{}' ;;
  "ec2 describe-availability-zones") echo '{"AvailabilityZones":[{"ZoneName":"r-1c"},{"ZoneName":"r-1a"},{"ZoneName":"r-1b"},{"ZoneName":"r-1d"}]}' ;;
  "ec2 describe-instance-types") cat <<'J'
{"InstanceTypes":[
 {"InstanceType":"g5.xlarge","GpuInfo":{"Gpus":[{"Name":"A10G","Manufacturer":"NVIDIA","Count":1}],"TotalGpuMemoryInMiB":24576},"VCpuInfo":{"DefaultVCpus":4},"MemoryInfo":{"SizeInMiB":16384}},
 {"InstanceType":"g6.xlarge","GpuInfo":{"Gpus":[{"Name":"L4","Manufacturer":"NVIDIA","Count":1}],"TotalGpuMemoryInMiB":23040},"VCpuInfo":{"DefaultVCpus":4},"MemoryInfo":{"SizeInMiB":16384}},
 {"InstanceType":"g6f.large","GpuInfo":{"Gpus":[{"Name":"L4","Manufacturer":"NVIDIA","Count":0}],"TotalGpuMemoryInMiB":2861},"VCpuInfo":{"DefaultVCpus":2},"MemoryInfo":{"SizeInMiB":8192}},
 {"InstanceType":"g4ad.xlarge","GpuInfo":{"Gpus":[{"Name":"Radeon","Manufacturer":"AMD","Count":1}],"TotalGpuMemoryInMiB":8192},"VCpuInfo":{"DefaultVCpus":4},"MemoryInfo":{"SizeInMiB":16384}},
 {"InstanceType":"p5.48xlarge","GpuInfo":{"Gpus":[{"Name":"H100","Manufacturer":"NVIDIA","Count":8}],"TotalGpuMemoryInMiB":655360},"VCpuInfo":{"DefaultVCpus":192},"MemoryInfo":{"SizeInMiB":2097152}},
 {"InstanceType":"m5.large","VCpuInfo":{"DefaultVCpus":2},"MemoryInfo":{"SizeInMiB":8192}}]}
J
    ;;
  "pricing get-products") printf '{"PriceList":[%s,%s,%s,%s,%s]}\n' "$(price g6.xlarge 0.8048)" "$(price g5.xlarge 1.006)" "$(price p5.48xlarge 98.32)" "$(price g4ad.xlarge 0.3785)" "$(price g6f.large 0.2020000000)" ;;
  "ec2 describe-instance-type-offerings") echo '{"InstanceTypeOfferings":[
    {"InstanceType":"g6.xlarge","Location":"r-1a"},{"InstanceType":"g6.xlarge","Location":"r-1b"},
    {"InstanceType":"g5.xlarge","Location":"r-1b"},{"InstanceType":"g5.xlarge","Location":"r-1d"},
    {"InstanceType":"g6f.large","Location":"r-1a"},{"InstanceType":"p5.48xlarge","Location":"r-1a"}]}' ;;
  "ec2 create-capacity-reservation")
    t=$(sed -n 's/.*--instance-type \([^ ]*\).*/\1/p' <<<"$*"); z=$(sed -n 's/.*--availability-zone \([^ ]*\).*/\1/p' <<<"$*")
    if grep -qxF "$t $z" <<<"${FAKE_CAPACITY:-}"; then echo "cr-0123"; exit 0; fi
    echo "${FAKE_CREATE_ERR:-An error occurred (InsufficientInstanceCapacity) when calling the CreateCapacityReservation operation: no capacity}" >&2
    exit 254 ;;
  *) echo "fake aws: unsupported: $*" >&2; exit 1 ;;
esac
A
chmod +x "$W/bin/aws"
export PATH="$W/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }

# --- argument checks
rc=0; "$SCRIPT" --max-cost-per-hour 4 >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || fail "missing --region accepted"
rc=0; "$SCRIPT" --region r-1 --max-cost-per-hour abc >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || fail "bad cost accepted"

# --- dry run: NVIDIA only, under the limit, cheapest first, default zones a,b,c
: >"$FAKE_AWS_LOG"
out=$("$SCRIPT" --region r-1 --max-cost-per-hour 4 --dry-run 2>&1)
has "$out" "zones          : a,b,c"
has "$out" "g6.xlarge"
hasnt "$out" "g4ad"
hasnt "$out" "g6f.large"
hasnt "$out" "p5.48xlarge"
hasnt "$out" "m5.large"
[ "$(grep -n 'g6.xlarge' <<<"$out" | cut -d: -f1)" -lt "$(grep -n 'g5.xlarge' <<<"$out" | cut -d: -f1)" ] || fail "not sorted by price"
g5=$(grep 'g5.xlarge' <<<"$out")
has "$g5" "1.006 "
has "$g5" " b"
hasnt "$g5" "r-1"
hasnt "$g5" " d"
hasnt "$(cat "$FAKE_AWS_LOG")" "create-capacity-reservation"

# --- no tty and no --yes: refuses
rc=0; "$SCRIPT" --region r-1 --max-cost-per-hour 4 </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "reserved without --yes"

# --- tries in price order, stops at the first success
: >"$FAKE_AWS_LOG"
out=$(FAKE_CAPACITY="g5.xlarge r-1b" "$SCRIPT" --region r-1 --max-cost-per-hour 4 --yes 2>&1)
has "$out" "reservation : cr-0123 (1 x g5.xlarge in r-1b"
has "$out" 'instance_type = "g5.xlarge", zone = "b"'
has "$out" "cancel-capacity-reservation --region r-1 --capacity-reservation-id cr-0123"
creates=$(grep 'create-capacity-reservation' "$FAKE_AWS_LOG")
[ "$(wc -l <<<"$creates" | tr -d ' ')" -eq 3 ] || fail "expected 3 attempts (g6 a, g6 b, g5 b): $creates"
has "$creates" "--instance-match-criteria open"
has "$creates" "--end-date-type limited"

# --- --zones restricts; nothing left fails clearly
rc=0; out=$("$SCRIPT" --region r-1 --max-cost-per-hour 4 --zones c --dry-run 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "empty candidate list accepted"
has "$out" "no NVIDIA GPU type"

# --- no capacity anywhere
rc=0; out=$("$SCRIPT" --region r-1 --max-cost-per-hour 4 --yes 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "success without capacity"
has "$out" "no capacity for any candidate"

# --- quota error skips the rest of that type; access denied aborts
: >"$FAKE_AWS_LOG"
FAKE_CREATE_ERR="An error occurred (InstanceLimitExceeded): quota" "$SCRIPT" --region r-1 --max-cost-per-hour 4 --yes >/dev/null 2>&1 || true
[ "$(grep -c 'instance-type g6.xlarge' "$FAKE_AWS_LOG")" -eq 1 ] || fail "quota error did not skip the type's other zones"
: >"$FAKE_AWS_LOG"
rc=0; out=$(FAKE_CREATE_ERR="An error occurred (UnauthorizedOperation): denied" "$SCRIPT" --region r-1 --max-cost-per-hour 4 --yes 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "access denied accepted"
has "$out" "UnauthorizedOperation"
[ "$(grep -c 'create-capacity-reservation' "$FAKE_AWS_LOG")" -eq 1 ] || fail "continued after access denied"

# --- --arch is passed to describe-instance-types
: >"$FAKE_AWS_LOG"
"$SCRIPT" --region r-1 --max-cost-per-hour 4 --dry-run >/dev/null 2>&1
has "$(cat "$FAKE_AWS_LOG")" "supported-architecture,Values=x86_64"
: >"$FAKE_AWS_LOG"
"$SCRIPT" --region r-1 --max-cost-per-hour 4 --arch arm64 --dry-run >/dev/null 2>&1
has "$(cat "$FAKE_AWS_LOG")" "supported-architecture,Values=arm64"

echo ok
