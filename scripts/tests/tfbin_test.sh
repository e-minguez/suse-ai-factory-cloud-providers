#!/usr/bin/env bash
# Tests for scripts/lib/tfbin.sh: which binary TF_BIN resolves to.
# Usage: scripts/tests/tfbin_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(dirname "$T")/lib"
W=$(mktemp -d "${TMPDIR:-/tmp}/tfbin-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# PATH dirs holding stubs; the inner shell has no other tools, so only builtins run there.
mkdir "$W/both" "$W/tf" "$W/tofu" "$W/none"
for d in both tf; do printf '#!/bin/sh\n' >"$W/$d/terraform" && chmod +x "$W/$d/terraform"; done
for d in both tofu; do printf '#!/bin/sh\n' >"$W/$d/tofu" && chmod +x "$W/$d/tofu"; done

# resolve <bindir> [TF_BIN value]: prints the resolved TF_BIN in a clean environment.
resolve() {
  env -i PATH="$1" ${2:+TF_BIN="$2"} "$BASH" -c ". '$LIB/tfbin.sh'; printf '%s' \"\$TF_BIN\""
}

[ "$(resolve "$W/both")" = terraform ] || fail "terraform must win when both are installed"
[ "$(resolve "$W/tf")" = terraform ] || fail "terraform only"
[ "$(resolve "$W/tofu")" = tofu ] || fail "tofu only"
[ "$(resolve "$W/none")" = terraform ] || fail "neither installed: expected terraform so the dependency check names it"
[ "$(resolve "$W/both" tofu)" = tofu ] || fail "TF_BIN=tofu must win over terraform"
[ "$(resolve "$W/tf" /opt/custom/tofu)" = /opt/custom/tofu ] || fail "TF_BIN path must be kept"

# Exported, so deploy.sh passes the choice on to the scripts it starts.
out=$(env -i PATH="$W/tofu" "$BASH" -c ". '$LIB/tfbin.sh'; declare -p TF_BIN")
[ "$out" = 'declare -x TF_BIN="tofu"' ] || fail "TF_BIN not exported: $out"

echo "tfbin_test: ok"
