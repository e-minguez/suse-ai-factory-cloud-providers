#!/usr/bin/env bash
# List GPU passthrough plans in stock across every Vultr region, and flag where
# the plan catalogue disagrees with that stock.
#
# "Passthrough" here means a whole GPU handed to the instance, which is what a
# host without the vGPU guest driver stack needs:
#   - cloud plans whose own `type` is "vdm" (DEDICATEDMETAL), whatever their
#     id says -- vcg-a16-6c-* is vdm while vcg-a16-12c-* is fractional "vcg";
#   - "vcg" (CLOUDGPU) plans on a GPU Vultr documents as passthrough: only the
#     L40S, per the Implementation column of
#     https://docs.vultr.com/products/compute/instances/cloud-gpu/explore-gpu-variants
#     (A16, A40 and A100 are listed as vGPU there). So `vcg` does not mean vGPU;
#     it is the GPU model that decides.
#   - bare metal plans with a GPU (gpu_brand set and not "none").
#
# Stock comes from GET /v2/regions/{id}/availability WITHOUT ?type=, which
# returns every family at once. The catalogue's own `locations` is not used
# for stock; the script reports where it disagrees instead.
#
# Usage: VULTR_API_KEY=... ./passthrough-stock.sh [region ...]
# Needs curl and jq. The key must be sent: unauthenticated, the availability
# endpoint answers HTTP 200 with an empty list rather than a 401.
set -euo pipefail

: "${VULTR_API_KEY:?set VULTR_API_KEY}"
API=https://api.vultr.com/v2

# GET with retry on 429 (the API rate-limits a region sweep) and 5xx. Any other
# non-200 is fatal: silently treating it as "no stock" is the failure this
# script exists to avoid.
get() {
  local url=$1 body code attempt
  for attempt in 1 2 3 4 5; do
    # The key goes in on stdin (curl config), not in argv, so it stays out of `ps`.
    body=$(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY" |
      curl -sS -K - --max-time 60 -w '\n%{http_code}' "$url")
    code=${body##*$'\n'}
    body=${body%$'\n'*}
    case $code in
      200) printf '%s' "$body"; return 0 ;;
      429 | 5??) sleep $((attempt * 2)) ;;
      *) echo "HTTP $code from $url: $body" >&2; return 1 ;;
    esac
  done
  echo "giving up on $url after $attempt attempts (last HTTP $code)" >&2
  return 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The API's latency swings from 0.3s to 8s per call, run to run, so everything
# is fetched concurrently: the plan catalogue downloads in the background while
# the regions are queried 16 at a time -- under Vultr's documented 30 req/s.
# Even all 33 at once has not drawn a 429; get() retries if it ever does.
get "$API/plans?per_page=500" >"$tmp/plans.json" &
p1=$!
get "$API/plans-metal?per_page=500" >"$tmp/metal.json" &
p2=$!
get "$API/regions?per_page=500" >"$tmp/regions.json" &
p3=$!
wait $p3

# id -> "City, CC", read even when regions are given, for the output
region_names=$(jq -c '.regions | map({(.id): "\(.city), \(.country)"}) | add' "$tmp/regions.json")

if [ $# -gt 0 ]; then
  regions=("$@")
else
  regions=()
  while read -r r; do regions+=("$r"); done < <(jq -r '.regions[].id' "$tmp/regions.json")
fi

export -f get
export API VULTR_API_KEY tmp
# shellcheck disable=SC2016 # expanded by the inner bash, not here
printf '%s\n' "${regions[@]}" | xargs -P 16 -I{} bash -c \
  'get "$API/regions/$1/availability" >"$tmp/$1.avail" || touch "$tmp/$1.failed"' _ {}
wait $p1 && wait $p2
failed=()
for f in "$tmp"/*.failed; do [ -e "$f" ] && failed+=("$(basename "$f" .failed)"); done
if [ ${#failed[@]} -gt 0 ]; then
  echo "error: could not fetch availability for: ${failed[*]}" >&2
  exit 1
fi

# id, family, gpu as the catalogue reports it, on-demand, $/mo, catalogue locations
catalogue=$(
  {
    jq -c '.plans[]
      | select(.type == "vdm" or (.type == "vcg" and .gpu_type == "NVIDIA_L40S")) | {
      id, family: "cloud (\(.type))",
      gpu: (if .gpu_type then "\(.gpu_count // "?")x \(.gpu_type)" else "null" end),
      ondemand: .deploy_ondemand, cost: .monthly_cost, locations}' "$tmp/plans.json"
    jq -c '.plans_metal[]
      | select(.gpu_brand != null and .gpu_brand != "none") | {
      id, family: "bare metal",
      gpu: "\(.gpu_count // "?")x \(.gpu_type)",
      ondemand: .deploy_ondemand, cost: .monthly_cost, locations}' "$tmp/metal.json"
  } | jq -s 'map({(.id): .}) | add'
)

echo "Passthrough stock, $(date -u +%Y-%m-%dT%H:%MZ), ${#regions[@]} regions, $(jq length <<<"$catalogue") candidate plans"
echo

# region<TAB>plan for every candidate plan actually in stock
ids=$(jq -r 'keys[]' <<<"$catalogue")
stock=""
for r in "${regions[@]}"; do
  avail=$(jq -r '.available_plans[]' "$tmp/$r.avail")
  if [ -z "$avail" ]; then
    echo "warning: $r returned no available plans at all -- region down, or a key problem" >&2
  fi
  stock+=$(grep -xFf <(printf '%s\n' "$ids") <<<"$avail" | awk -v r="$r" '{print r "\t" $0}' || true)$'\n'
done
stock=$(grep . <<<"$stock" || true)

if [ -z "$stock" ]; then
  echo "No passthrough plan is in stock in any region checked."
else
  {
    printf 'REGION\tLOCATION\tPLAN\tFAMILY\tGPU (catalogue)\tON-DEMAND\t$/MO\n'
    while IFS=$'\t' read -r r p; do
      jq -r --arg r "$r" --arg p "$p" --argjson c "$catalogue" --argjson n "$region_names" \
        '$c[$p] | [$r, ($n[$r] // "?"), $p, .family, .gpu, .ondemand, .cost] | @tsv' <<<null
    done <<<"$stock"
  } | column -t -s $'\t'
fi

# Catalogue vs. reality. Stock drains and refills, so a stocked plan missing
# from `locations` is the meaningful direction; the reverse is just no stock.
echo
echo "Catalogue discrepancies:"
found=0
while IFS=$'\t' read -r r p; do
  [ -n "$p" ] || continue
  if ! jq -e --arg r "$r" --arg p "$p" --argjson c "$catalogue" '$c[$p].locations | index($r)' <<<null >/dev/null; then
    echo "  $p is in stock in $r ($(jq -r --arg r "$r" '.[$r] // "?"' <<<"$region_names")), but its catalogue locations are $(jq -c --arg p "$p" --argjson c "$catalogue" '$c[$p].locations' <<<null)"
    found=1
  fi
done <<<"$stock"
nulls=$(jq -r 'to_entries[] | select(.value.gpu == "null") | .key' <<<"$catalogue")
if [ -n "$nulls" ]; then
  echo "  These plans report gpu_type/gpu_vram_gb null in GET /v2/plans, so GPU filters miss them:"
  while read -r p; do echo "    $p"; done <<<"$nulls"
  found=1
fi
[ $found = 1 ] || echo "  none"
