#!/usr/bin/env bash
# Self-test for poll.sh: bash scripts/lib/poll_test.sh
set -euo pipefail
# shellcheck source=poll.sh
. "$(dirname "$0")/poll.sh"

n=0
probe_third() { n=$((n + 1)); POLL_STATUS=building; [ "$n" -ge 3 ]; }
probe_never() { POLL_STATUS=building; return 1; }
# shellcheck disable=SC2034
probe_fatal() { POLL_STATUS=failed; POLL_DETAIL="boom"; return 2; }

fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(poll_until 10 0 probe_third) || fail "probe_third rc"
[ "$(head -n1 <<<"$out")" = "status=building elapsed=0" ] || fail "first line: $out"
[ "$(wc -l <<<"$out")" -eq 2 ] || fail "expected 2 lines (no repeat until change): $out"
[[ "$(tail -n1 <<<"$out")" == status=done\ * ]] || fail "final line: $out"

rc=0; out=$(poll_until 1 1 probe_never) || rc=$?
[ "$rc" -eq 1 ] || fail "timeout rc=$rc"
[[ "$out" == *status=timeout* ]] || fail "timeout line: $out"

rc=0; out=$(poll_until 5 0 probe_fatal) || rc=$?
[ "$rc" -eq 2 ] || fail "fatal rc=$rc"
[[ "$out" == "status=failed elapsed="*" boom" ]] || fail "fatal line: $out"
echo ok
