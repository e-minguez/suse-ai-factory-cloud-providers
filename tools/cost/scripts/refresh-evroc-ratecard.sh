#!/usr/bin/env bash
# Rebuild internal/provider/evroc/ratecard.json from evroc's public calculator.
# evroc has no pricing API: the VM page loads a webpack chunk that embeds the
# price list as JSON.parse('[{"id":...}]'). Needs bash, curl, jq and perl.
#
# Usage: refresh-evroc-ratecard.sh [-o FILE] [--as-of YYYY-MM-DD]
# Prints the rate card to stdout, or writes FILE (default: stdout).
set -euo pipefail

PAGE_URL="https://evroc.com/cloud-services/virtual-machines/"
BASE_URL="https://evroc.com"

out=""
as_of="$(date -u +%Y-%m-%d)"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:?-o needs a file}"; shift 2 ;;
    --as-of) as_of="${2:?--as-of needs a date}"; shift 2 ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for tool in curl jq perl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() { curl -fsSL --retry 2 --max-time 60 "$1"; }

fetch "$PAGE_URL" >"$tmp/page.html"

# The webpack runtime script, e.g. /webpack-runtime-0123abcd.js.
runtime="$(perl -ne 'while (/(\/webpack-runtime-[A-Za-z0-9]+\.js)/g) { print "$1\n"; exit }' "$tmp/page.html")"
[ -n "$runtime" ] || { echo "no webpack-runtime script found on $PAGE_URL" >&2; exit 1; }
fetch "$BASE_URL$runtime" >"$tmp/runtime.js"

# The runtime maps chunk id -> name ({123:"name"}) and id -> content hash
# ({123:"hash"}); a chunk file is /<name>-<hash>.js. Print "id name-hash" pairs.
perl -0ne '
  my @maps = /\{((?:\d+:"[^"]+",?)+)\}/g;
  my (%name, %hash);
  my ($names, $hashes) = @maps[0, 1];
  while ($names  =~ /(\d+):"([^"]+)"/g) { $name{$1} = $2 }
  while ($hashes =~ /(\d+):"([^"]+)"/g) { $hash{$1} = $2 }
  for my $id (sort { $a <=> $b } keys %hash) {
    print "/", ($name{$id} // $id), "-", $hash{$id}, ".js\n";
  }
' "$tmp/runtime.js" >"$tmp/chunks.txt"
[ -s "$tmp/chunks.txt" ] || { echo "could not read the chunk maps from $runtime" >&2; exit 1; }

# Find the chunk holding the price list and extract the JSON string literal.
found=""
while IFS= read -r chunk; do
  fetch "$BASE_URL$chunk" >"$tmp/chunk.js" 2>/dev/null || continue
  if grep -q "JSON.parse('\[{\"id\":" "$tmp/chunk.js"; then
    perl -ne 'if (/JSON\.parse\(\x27(\[\{"id":.*?\])\x27\)/) { print $1; exit }' "$tmp/chunk.js" |
      perl -pe 's/\\(.)/$1/g' >"$tmp/prices.json"
    if jq -e 'type == "array" and any(.[]; .sku == "network.public_ip")' "$tmp/prices.json" >/dev/null 2>&1; then
      found="$chunk"
      break
    fi
  fi
done <"$tmp/chunks.txt"
[ -n "$found" ] || { echo "no chunk with the evroc price list found; the site layout may have changed" >&2; exit 1; }

card="$(jq --arg as_of "$as_of" --arg url "$PAGE_URL" '
  def price(sku): ([.[] | select(.sku == sku) | .price_per_unit] | first) // error("missing price for " + sku);
  {
    currency: "EUR",
    as_of: $as_of,
    source_url: $url,
    instances: ([.[] | select(.unit == "compute_vm_hours") | {key: (.sku | ascii_downcase), value: .price_per_unit}]
                | sort_by(.key) | from_entries),
    storage_gb_hour: price("vm_storage.ssd"),
    public_ip_hour: price("network.public_ip")
  }' "$tmp/prices.json")"

if [ -n "$out" ]; then
  printf '%s\n' "$card" >"$out"
else
  printf '%s\n' "$card"
fi
