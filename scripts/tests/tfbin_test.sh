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

# tf_warn_old_tofu: warns for an OpenTofu older than the tested one, stays quiet otherwise.
mkdir "$W/v"
stub() { printf '#!%s\necho "%s"\necho\n' "$BASH" "$2" >"$W/v/$1" && chmod +x "$W/v/$1"; }
warn() { env -i PATH="$W/v" TF_BIN="$1" "$BASH" -c ". '$LIB/tfbin.sh'; tf_warn_old_tofu" 2>&1; }
stub tofu-old "OpenTofu v1.9.3"
stub tofu-new "OpenTofu v1.13.1"
stub tofu-major "OpenTofu v2.0.0"
stub terraform-old "Terraform v1.2.0"
case "$(warn tofu-old)" in *"older than 1.13"*) ;; *) fail "old tofu must warn" ;; esac
[ -z "$(warn tofu-new)" ] || fail "tested tofu must not warn"
[ -z "$(warn tofu-major)" ] || fail "newer major must not warn"
[ -z "$(warn terraform-old)" ] || fail "terraform is never warned about here"


# No script may call terraform or tofu by name: a bare call ignores TF_BIN and mixes both tools in one deploy.
ROOT="$(dirname "$(dirname "$T")")"
pat='(^|\$\(|\(|\||&&|;|!|then|do|if) *(terraform|tofu) +(-[a-z]+(=[^ ]*)? +)*(init|plan|apply|show|output|state|console|fmt|validate|test)( |$)'
bare=$(find "$ROOT" -name '*.sh' -not -path '*/tests/*' -not -path '*/.git/*' -not -path '*/.terraform/*' -print0 |
  xargs -0 grep -nE "$pat" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[ -z "$bare" ] || fail "scripts must call \"\$TF_BIN\", not terraform or tofu by name:
$bare"

echo "tfbin_test: ok"
