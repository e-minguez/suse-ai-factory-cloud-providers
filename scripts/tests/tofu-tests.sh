#!/usr/bin/env bash
# Generates and checks the OpenTofu variants (tests/*.tofutest.hcl) of the Terraform test suites
# (modules/*/tests, tools/*/*/tests, examples/*/tests).
# Usage: scripts/tests/tofu-tests.sh --write|--check [<module dir>...]   (default: every directory with tests/)
#
# The suites are written for Terraform. OpenTofu rejects function calls and override_during in
# override values and only allows run.<name> in a run's variables, so a suite that needs it gets a
# committed .tofutest.hcl next to it, which `tofu test` reads instead of the .tftest.hcl and
# `terraform test` ignores. The variants are generated from the Terraform suites in a temporary copy:
#   - override_during lines are dropped;
#   - file(...) and jsonencode(...) calls are replaced with their value (tofu-tests.awk);
#   - run.<name>.<output> references are replaced with the value a probe run printed
#     (tofu-probe.awk, tofu-refs.awk).
# --write updates the variants, --check fails when one is missing or out of date (CI).
# Needs tofu (TF_BIN overrides), jq and gawk (macOS: brew install gawk); runs with bash 3.2.
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$T")")"
TOFU="${TF_BIN:-tofu}"
export LC_ALL=C

case "${1:-}" in
  --write) MODE="write" ;;
  --check) MODE="check" ;;
  *) echo "usage: $0 --write|--check [<module dir>...]" >&2; exit 2 ;;
esac
shift

for c in "$TOFU" jq gawk; do
  command -v "$c" >/dev/null 2>&1 || { echo "tofu-tests: $c not found" >&2; exit 1; }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/tofu-tests.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir "$W/scratch" "$W/empty"
cp -a "$ROOT/modules" "$ROOT/tools" "$ROOT/examples" "$W/"
# A local terraform.tfvars, auto.tfvars, state or logs in an example must not leak into the probes.
find "$W/examples" -mindepth 2 -maxdepth 2 \( -name "terraform.tfvars*" -o -name "*.auto.tfvars*" -o -name "terraform.tfstate*" -o -name ".deploy" \) -prune -exec rm -rf {} +
find "$W" \( -name .terraform -o -name .terraform.lock.hcl \) -prune -exec rm -rf {} +

if [ $# -gt 0 ]; then
  dirs=("$@")
else
  dirs=()
  while IFS= read -r line; do dirs+=("$line"); done < <(cd "$ROOT" && { find modules -mindepth 2 -maxdepth 2 -type d -name tests; find examples -mindepth 2 -maxdepth 2 -type d -name tests; find tools -mindepth 3 -maxdepth 3 -type d -name tests; } | xargs -n1 dirname | sort)
fi

# probe <module dir> <test file> <run> <output path>: prints the output as JSON.
probe() {
  local mod=$1 file=$2 run=$3 path=$4 raw out
  gawk -v name="$run" -v path="$path" -f "$T/tofu-probe.awk" "$file" >"$mod/tests/zz_probe.tftest.hcl"
  raw=$(cd "$mod" && "$TOFU" test -json -filter=tests/zz_probe.tftest.hcl 2>&1 || true)
  rm -f "$mod/tests/zz_probe.tftest.hcl"
  out=$(jq -r 'select(.diagnostic != null) | .diagnostic.detail // empty | select(startswith("PROBE="))' <<<"$raw" | head -1)
  if [ -z "$out" ]; then
    echo "tofu-tests: no value for run.$run.$path in $file" >&2
    jq -r 'select(.diagnostic != null) | "  \(.diagnostic.summary): \(.diagnostic.detail // "") @ \(.diagnostic.range.filename // ""):\(.diagnostic.range.start.line // 0) \(.diagnostic.snippet.code // "" | .[0:160])"' <<<"$raw" | head -5 >&2
    return 1
  fi
  printf '%s' "${out#PROBE=}"
}

# rewrite <module dir> <test file>: pass 1, needs no initialised module.
rewrite() {
  local mod=$1 file=$2
  gawk -v moddir="$mod" -v tofu="$TOFU" -v exprfile="$W/scratch/expr" -v empty="$W/empty" \
    -f "$T/tofu-tests.awk" "$file" >"$file.new"
  mv "$file.new" "$file"
}

# collect <module dir> <test file>: probes the value of every run.<name>.<output> reference into a map file.
collect() {
  local mod=$1 file=$2 ref name path refs lit
  : >"$file.map"
  refs=$(grep -ohE 'run\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+|\["[^"]*"\]|\[[0-9]+\])+' "$file" |
    sort -u | gawk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- || true)
  for ref in $refs; do
    name=${ref#run.}
    name=${name%%.*}
    path=${ref#run."$name".}
    lit=$(probe "$mod" "$file" "$name" "$path") || return 1
    # Mocked providers make some outputs differ between runs. Terraform compares against another run's
    # value; here a value that is not stable becomes a fixed marker, so the variant is reproducible.
    if [ "$lit" != "$(probe "$mod" "$file" "$name" "$path")" ]; then
      echo "  note: $ref differs between runs; using a marker" >&2
      lit="\"unstable:$ref\""
    fi
    printf '%s\t%s\n' "$ref" "$lit" >>"$file.map"
  done
}

# resolve <test file>: replaces the references with the collected values.
resolve() {
  gawk -v map="$1.map" -f "$T/tofu-refs.awk" "$1" >"$1.new"
  mv "$1.new" "$1"
  rm -f "$1.map"
}


# emit <real module dir> <test file in the temp copy>: writes (--write) or compares (--check) the
# tofu variant of one suite. A suite the conversion leaves unchanged needs none: tofu reads the
# .tftest.hcl itself, and prefers a .tofutest.hcl of the same name when there is one.
emit() {
  local real=$1 conv=$2 base variant
  base=$(basename "$conv" .tftest.hcl)
  variant="$real/tests/$base.tofutest.hcl"
  if cmp -s "$real/tests/$base.tftest.hcl" "$conv"; then
    if [ -f "$variant" ]; then
      if [ "$MODE" = write ]; then rm -f "$variant"; echo "  removed $variant"; else echo "  stale: $variant (no conversion needed)" >&2; return 1; fi
    fi
    return 0
  fi
  { printf '%s\n' "# Generated by scripts/tests/tofu-tests.sh --write from $base.tftest.hcl. Do not edit: change the" \
      "# Terraform suite and regenerate (make tofu-tests-gen). OpenTofu reads this file instead of it."; cat "$conv"; } >"$W/variant.tofutest.hcl"
  "$TOFU" fmt "$W/variant.tofutest.hcl" >/dev/null
  if [ "$MODE" = write ]; then
    cat "$W/variant.tofutest.hcl" >"$variant"
    echo "  wrote $variant"
  elif ! cmp -s "$variant" "$W/variant.tofutest.hcl"; then
    echo "  out of date or missing: $variant (run make tofu-tests-gen)" >&2
    return 1
  fi
}

status=0
for d in "${dirs[@]}"; do
  mod="$W/${d%/}"
  echo "==> tofu $MODE $d"
  rm -f "$mod"/tests/*.tofutest.hcl
  (
    cd "$mod"
    for f in tests/*.tftest.hcl; do rewrite "$mod" "$f"; done
    "$TOFU" init -backend=false -input=false >/dev/null
    for f in tests/*.tftest.hcl; do collect "$mod" "$f" || exit 1; done
    for f in tests/*.tftest.hcl; do resolve "$f"; done
    rc=0
    for f in tests/*.tftest.hcl; do emit "$ROOT/${d%/}" "$mod/$f" || rc=1; done
    exit $rc
  ) || status=1
done
exit $status
