#!/usr/bin/env bash
# Tests for tools/leftovers/aws.sh with a fake aws on PATH returning canned output.
# Usage: scripts/tests/leftovers_aws_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(dirname "$T")"
TOOL="$(dirname "$S")/tools/leftovers/aws.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/leftovers-aws-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/f"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_AWS_DIR="$W/f"
unset AWS_REGION AWS_DEFAULT_REGION

# Dispatches on the subcommand; canned output from $FAKE_AWS_DIR/<subcommand>.out (missing =
# empty), <subcommand>.err makes the call fail with that message.
cat >"$W/bin/aws" <<'SH'
#!/bin/sh
d=$FAKE_AWS_DIR
echo "$*" >>"$d/calls.log"
case "$1" in
  ec2 | elbv2 | s3api | iam) sub=$2 ;;
  *) sub=$1 ;;
esac
if [ -f "$d/$sub.err" ]; then cat "$d/$sub.err" >&2; exit 254; fi
[ ! -f "$d/$sub.out" ] || cat "$d/$sub.out"
exit 0
SH
chmod +x "$W/bin/aws"

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$W/out" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2'"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }
reset() { rm -f "$W"/f/*; }
# tab <created> <arn> <name>: one tagging API row
tab() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
# run args...: sets OUT and RC, keeps the raw output in $W/out.
run() {
  RC=0
  "$BASH" "$TOOL" "$@" >"$W/out" 2>&1 || RC=$?
  OUT=$(cat "$W/out")
}

ARN=arn:aws:ec2:eu-west-1:111122223333
ELB=arn:aws:elasticloadbalancing:eu-west-1:111122223333

# --- mix: live, gone, record, unknown type
reset
{
  tab 20260101-101010 "$ARN:instance/i-live" cp-1
  tab 20260101-101010 "$ARN:instance/i-dead" None
  tab 20260101-101010 "$ARN:volume/vol-gone" None
  tab 20260101-101010 "$ARN:import-snapshot-task/import-snap-1" None
  tab 20260101-101010 "$ARN:key-pair/key-0abc" None
  tab 20260101-101010 "$ELB:loadbalancer/net/c1-api/abc" None
  tab 20260101-101010 "arn:aws:s3:::c1-bucket" None
} >"$W/f/resourcegroupstaggingapi.out"
printf 'i-live\trunning\ni-dead\tterminated\n' >"$W/f/describe-instances.out"
echo 'LoadBalancerNotFound: not found' >"$W/f/describe-load-balancers.err"
echo 'An error occurred (404) when calling HeadBucket: Not Found' >"$W/f/head-bucket.err"
run c1 --region eu-west-1
[ "$RC" -eq 1 ] || fail "mix rc=$RC"
has "$OUT" "LIVE     ec2:instance"
has "$OUT" "i-live"
has "$OUT" "cp-1"
has "$OUT" "20260101-101010"
has "$OUT" "RECORD   ec2:import-snapshot-task"
has "$OUT" "UNKNOWN  ec2:key-pair"
hasnt "$OUT" "i-dead"
hasnt "$OUT" "vol-gone"
hasnt "$OUT" "elbv2:loadbalancer"
hasnt "$OUT" "s3:bucket"
has "$OUT" "1 live, 1 record, 1 unknown, 4 gone"
noleftover
run c1 --region eu-west-1 --all
[ "$RC" -eq 1 ] || fail "--all rc=$RC"
has "$OUT" "gone     ec2:instance"
has "$OUT" "i-dead"
has "$OUT" "gone     ec2:volume"
has "$OUT" "gone     elbv2:loadbalancer"
has "$OUT" "gone     s3:bucket"
has "$OUT" "1 live, 1 record, 1 unknown, 4 gone"
# region from the environment
AWS_REGION=eu-west-1 run c1
[ "$RC" -eq 1 ] || fail "env region rc=$RC"
has "$(cat "$W/f/calls.log")" "--region eu-west-1"

# --- nothing confirmed live (clean destroy): tagged rows must not vanish
reset
{
  tab 20260101-101010 "$ARN:key-pair/key-0abc" None
  tab 20260101-101010 "$ARN:import-snapshot-task/import-snap-1" None
  tab 20260101-101010 "$ARN:instance/i-x" None
} >"$W/f/resourcegroupstaggingapi.out"
run c1 --region eu-west-1
[ "$RC" -eq 1 ] || fail "empty live rc=$RC"
has "$OUT" "0 live, 1 record, 1 unknown, 1 gone"
has "$OUT" "== c1 (region eu-west-1)"

# --- missing CLI is inconclusive, no usage line
reset
RC=0
OUT=$(PATH="/usr/bin:/bin" "$BASH" "$TOOL" c1 --region eu-west-1 2>&1) || RC=$?
[ "$RC" -eq 3 ] || fail "no CLI rc=$RC"
has "$OUT" "aws not installed"
hasnt "$OUT" "usage:"

# --- invalid cluster name
reset
run Bad_Name --region eu-west-1
[ "$RC" -eq 2 ] || fail "invalid name rc=$RC"
has "$OUT" "invalid cluster name"

# --- live LB; failed confirm is UNKNOWN
reset
{
  tab 20260101-101010 "$ELB:loadbalancer/net/c1-api/abc" None
  tab 20260101-101010 "arn:aws:s3:::c1-bucket" None
} >"$W/f/resourcegroupstaggingapi.out"
echo active >"$W/f/describe-load-balancers.out"
echo "An error occurred (AccessDenied) when calling HeadBucket" >"$W/f/head-bucket.err"
run c1 --region eu-west-1
[ "$RC" -eq 1 ] || fail "lb rc=$RC"
has "$OUT" "LIVE     elbv2:loadbalancer"
has "$OUT" "UNKNOWN  s3:bucket"
has "$OUT" "1 live, 0 record, 1 unknown, 0 gone"

# --- all gone
reset
tab 20260101-101010 "$ARN:instance/i-dead" None >"$W/f/resourcegroupstaggingapi.out"
printf 'i-dead\tterminated\n' >"$W/f/describe-instances.out"
run c1 --region eu-west-1
[ "$RC" -eq 0 ] || fail "all gone rc=$RC"
has "$OUT" "0 live, 0 record, 0 unknown, 1 gone"
reset
run c1 --region eu-west-1
[ "$RC" -eq 0 ] || fail "empty rc=$RC"
has "$OUT" "0 live, 0 record, 0 unknown, 0 gone"

# --- IAM role and instance profile
reset
printf 'c1-vmimport\tc1-jumphost\n' >"$W/f/list-roles.out"
printf 'c1-jumphost\n' >"$W/f/list-instance-profiles.out"
run c1 --region eu-west-1
[ "$RC" -eq 1 ] || fail "iam rc=$RC"
has "$OUT" "LIVE     iam:role"
has "$OUT" "c1-vmimport"
has "$OUT" "iam:instance-profile"
has "$OUT" "3 live, 0 record, 0 unknown, 0 gone"
has "$(cat "$W/f/calls.log")" "starts_with(RoleName,'c1-')"

# --- credentials, list failure
reset
echo "The SSO session has expired" >"$W/f/sts.err"
run c1 --region eu-west-1
[ "$RC" -eq 3 ] || fail "credentials rc=$RC"
has "$OUT" "inconclusive"
hasnt "$(cat "$W/f/calls.log")" "resourcegroupstaggingapi"
reset
echo "AccessDeniedException" >"$W/f/resourcegroupstaggingapi.err"
run c1 --region eu-west-1
[ "$RC" -eq 3 ] || fail "list failure rc=$RC"
noleftover

# --- usage errors
reset
run --region eu-west-1
[ "$RC" -eq 2 ] || fail "missing cluster rc=$RC"
has "$OUT" "cluster name missing"
run c1 --zone z1 --region eu-west-1
[ "$RC" -eq 2 ] || fail "--zone rc=$RC"
has "$OUT" "unknown flag: --zone"
run c1
[ "$RC" -eq 2 ] || fail "missing region rc=$RC"
has "$OUT" "region not given"
run c1 --region
[ "$RC" -eq 2 ] || fail "--region without value rc=$RC"
run -h
[ "$RC" -eq 0 ] || fail "-h rc=$RC"
has "$OUT" "usage:"
[ ! -e "$W/f/calls.log" ] || fail "aws called on usage error"

echo "leftovers_aws_test: ok"
