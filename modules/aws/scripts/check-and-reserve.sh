#!/usr/bin/env bash
# Finds NVIDIA GPU capacity in a region and holds it with an On-Demand Capacity
# Reservation (open matching: a later instance of that type in that zone uses it).
#
#   check-and-reserve.sh --region R --max-cost-per-hour USD [--zones a,b,c]
#                        [--arch A] [--count N] [--hours H] [--dry-run] [--yes]
#
# Candidates: current-generation types of --arch with whole NVIDIA GPUs (fractional
# GPU types report a GPU count of 0 and are skipped), Linux on-demand
# price (Pricing API) at most USD per instance, sorted cheapest first. Each type
# is tried in each zone that offers it until one reservation succeeds.
#   --zones   zone letters to try; default: the first three, as the module picks
#             them. Use the cluster's `zones`: a reservation elsewhere is unused.
#   --arch    CPU architecture (default x86_64, the architecture of the image).
#   --count   instances to reserve (default 1); the cost limit is per instance.
#   --hours   reservation end (default 2). The instance keeps running after it.
#   --dry-run list candidates and zones, reserve nothing.
#   --yes     do not ask before reserving.
#
# Needs aws, jq and ec2:DescribeInstanceTypes, ec2:DescribeInstanceTypeOfferings,
# ec2:DescribeAvailabilityZones, ec2:CreateCapacityReservation, pricing:GetProducts.
# Runs on the macOS system bash (3.2).
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

region=""
max=""
zones=""
arch=x86_64
count=1
hours=2
dry_run=0
yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --region | --max-cost-per-hour | --zones | --arch | --count | --hours)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --region) region=$2 ;;
        --max-cost-per-hour) max=$2 ;;
        --zones) zones=$2 ;;
        --arch) arch=$2 ;;
        --count) count=$2 ;;
        --hours) hours=$2 ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=1 && shift ;;
    --yes) yes=1 && shift ;;
    -h | --help) usage && exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$region" ] || die "--region is required"
[ -n "$max" ] || die "--max-cost-per-hour is required"
case "$max" in '' | *[!0-9.]* | *.*.*) die "--max-cost-per-hour must be a number, e.g. 4 or 2.5" ;; esac
case "$count" in '' | *[!0-9]* | 0) die "--count must be a positive integer" ;; esac
case "$hours" in '' | *[!0-9]* | 0) die "--hours must be a positive integer" ;; esac
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-and-reserve.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

aws sts get-caller-identity --output json >/dev/null 2>"$TMP/err" ||
  die "AWS credentials not usable: $(cat "$TMP/err")"

# Zones: letters, as in the module's `zones` variable.
if [ -z "$zones" ]; then
  zones=$(aws ec2 describe-availability-zones --region "$region" --output json \
    --filters Name=state,Values=available Name=opt-in-status,Values=opt-in-not-required |
    jq -r --arg r "$region" '[.AvailabilityZones[].ZoneName] | sort | .[0:3] | map(ltrimstr($r)) | join(",")')
  [ -n "$zones" ] || die "no availability zones found in $region"
  echo "zones          : $zones (first three; pass --zones to match the cluster's zones)"
else
  echo "zones          : $zones"
fi
az_list=$(tr ',' '\n' <<<"$zones" | sed "s/^/$region/")

echo "instance types : listing $arch NVIDIA GPU types in $region..."
aws ec2 describe-instance-types --region "$region" --output json \
  --filters Name=current-generation,Values=true Name=processor-info.supported-architecture,Values="$arch" |
  jq '[.InstanceTypes[] | select(any(.GpuInfo.Gpus[]?; .Manufacturer == "NVIDIA" and .Count > 0))
      | {type: .InstanceType, gpus: ([.GpuInfo.Gpus[].Count] | add),
         gpu: (.GpuInfo.Gpus[0].Name), gpu_mem_gib: ((.GpuInfo.TotalGpuMemoryInMiB // 0) / 1024 | floor),
         vcpus: .VCpuInfo.DefaultVCpus, mem_gib: (.MemoryInfo.SizeInMiB / 1024 | floor)}]' >"$TMP/types.json"
[ "$(jq length "$TMP/types.json")" -gt 0 ] || die "no $arch NVIDIA GPU instance types in $region"

# The Pricing API is served from us-east-1; regionCode selects the region.
echo "prices         : querying the Pricing API..."
aws pricing get-products --region us-east-1 --service-code AmazonEC2 --output json \
  --filters Type=TERM_MATCH,Field=regionCode,Value="$region" \
  Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
  Type=TERM_MATCH,Field=tenancy,Value=Shared \
  Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
  Type=TERM_MATCH,Field=capacitystatus,Value=Used \
  Type=TERM_MATCH,Field=licenseModel,Value="No License required" \
  >"$TMP/prices.raw" 2>"$TMP/err" || die "pricing:GetProducts failed: $(cat "$TMP/err")"
jq '[.PriceList[] | fromjson
     | {key: .product.attributes.instanceType,
        value: ([.terms.OnDemand[]?.priceDimensions[]?.pricePerUnit.USD | tonumber] | max)}
     | select(.value != null and .value > 0)] | from_entries' "$TMP/prices.raw" >"$TMP/prices.json"

echo "offerings      : checking which zones offer each type..."
types_csv=$(jq -r '[.[].type] | join(",")' "$TMP/types.json")
aws ec2 describe-instance-type-offerings --region "$region" --location-type availability-zone \
  --filters Name=instance-type,Values="$types_csv" --output json |
  jq '[.InstanceTypeOfferings[] | {type: .InstanceType, az: .Location}] | group_by(.type)
      | map({key: .[0].type, value: [.[].az] | sort}) | from_entries' >"$TMP/offers.json"

jq --slurpfile p "$TMP/prices.json" --slurpfile o "$TMP/offers.json" \
  --argjson max "$max" --arg azs "$az_list" '
  ($azs | split("\n") | map(select(. != ""))) as $want
  | [.[] | . + {price: $p[0][.type], azs: [($o[0][.type] // [])[] | select(. as $a | $want | index($a))]}
     | select(.price != null and .price <= $max and (.azs | length) > 0)]
  | sort_by(.price, .type)' "$TMP/types.json" >"$TMP/candidates.json"

if [ "$(jq length "$TMP/candidates.json")" -eq 0 ]; then
  die "no NVIDIA GPU type at or under \$$max/h is offered in zones $zones of $region"
fi

echo
jq -r --arg r "$region" '["TYPE", "USD/H", "GPUS", "GPU", "GPU_GIB", "VCPUS", "MEM_GIB", "ZONES"],
  (.[] | [.type, (.price * 10000 | round / 10000 | tostring), (.gpus | tostring), .gpu, (.gpu_mem_gib | tostring),
          (.vcpus | tostring), (.mem_gib | tostring), (.azs | map(ltrimstr($r)) | join(","))]) | @tsv' \
  "$TMP/candidates.json" | column -t -s "$(printf '\t')"
echo

[ "$dry_run" = 0 ] || exit 0

if [ "$yes" = 0 ]; then
  [ -t 0 ] || die "not a terminal: pass --yes to reserve"
  printf 'Reserve %s instance(s) of the first type with capacity, in this order, ending in %sh? [y/N] ' "$count" "$hours"
  read -r answer
  case "$answer" in y | Y | yes) ;; *) echo "aborted" && exit 1 ;; esac
fi

end=$(date -u -v+"${hours}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${hours} hours" +%Y-%m-%dT%H:%M:%SZ)

jq -r '.[] | .type as $t | .azs[] | "\($t) \(.)"' "$TMP/candidates.json" >"$TMP/attempts"
skip_type=""
while read -r type az; do
  [ "$type" != "$skip_type" ] || continue
  printf '  %-16s %-12s ' "$type" "$az"
  rc=0
  id=$(aws ec2 create-capacity-reservation --region "$region" --output text \
    --instance-type "$type" --instance-platform Linux/UNIX --availability-zone "$az" \
    --instance-count "$count" --instance-match-criteria open \
    --end-date-type limited --end-date "$end" \
    --tag-specifications "ResourceType=capacity-reservation,Tags=[{Key=elemental-managed-by,Value=check-and-reserve}]" \
    --query 'CapacityReservation.CapacityReservationId' </dev/null 2>"$TMP/err") || rc=$?
  if [ "$rc" -eq 0 ]; then
    price=$(jq -r --arg t "$type" '.[] | select(.type == $t) | .price' "$TMP/candidates.json")
    echo "reserved"
    echo
    echo "reservation : $id ($count x $type in $az, \$$price/h each, ends $end)"
    echo "tfvars      : instance_type = \"$type\", zone = \"${az#"$region"}\" in the GPU pool"
    echo "cancel      : aws ec2 cancel-capacity-reservation --region $region --capacity-reservation-id $id"
    echo "Billed while unused; cancel it once the node runs (the instance keeps running)."
    exit 0
  fi
  err=$(tr '\n' ' ' <"$TMP/err")
  case "$err" in
    *InsufficientInstanceCapacity* | *InsufficientCapacity*) echo "no capacity" ;;
    *LimitExceeded* | *ReservationCapacityExceeded* | *VcpuLimit*)
      # Quotas are per family and region: other zones fail the same way.
      echo "quota: $err"
      skip_type=$type
      ;;
    *UnauthorizedOperation* | *AccessDenied* | *ExpiredToken* | *InvalidClientTokenId*)
      echo "failed"
      die "$err"
      ;;
    *) echo "failed: $err" ;;
  esac
done <"$TMP/attempts"

die "no capacity for any candidate at or under \$$max/h in zones $zones; retry later or raise --max-cost-per-hour"
