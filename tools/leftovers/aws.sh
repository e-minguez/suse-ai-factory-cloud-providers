#!/usr/bin/env bash
# Read-only check: AWS resources tagged elemental-cluster=<name>, each confirmed against its owning
# service, plus IAM roles and instance profiles named <name>-*. Deletes nothing.
# Status meanings and why each ARN is re-checked: docs/providers/aws.md#leftover-check.
# Lookups use temp files and awk (bash 3.2: no associative arrays).
LO_USAGE="aws.sh <cluster_name> [--region R] [--all]   (region falls back to AWS_REGION/AWS_DEFAULT_REGION)"
LO_FLAGS="region"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/leftovers.sh"
lo_init "$@"
lo_need aws

CLUSTER=$LO_CLUSTER
REGION=${LO_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}
[ -n "$REGION" ] || lo_usage_error "region not given and AWS_REGION/AWS_DEFAULT_REGION unset"
TMP=$LO_TMP
LO_SCOPE="region $REGION"

# Without this, a credential error in a per-ARN check would read as "not found".
aws sts get-caller-identity --output text --query Account >/dev/null 2>"$TMP/err" ||
  lo_inconclusive "aws credentials not usable: $(head -n 1 "$TMP/err")"

# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
TAG_QUERY='ResourceTagMappingList[].[Tags[?Key==`elemental-created`]|[0].Value,ResourceARN,Tags[?Key==`Name`]|[0].Value]'
aws resourcegroupstaggingapi get-resources \
  --region "$REGION" \
  --tag-filters "Key=elemental-cluster,Values=$CLUSTER" \
  --query "$TAG_QUERY" \
  --output text >"$TMP/tagged.raw" 2>"$TMP/err" ||
  lo_inconclusive "tagging API list failed: $(head -n 1 "$TMP/err")"
sort "$TMP/tagged.raw" >"$TMP/tagged"

# "<key>\t<state>" for everything confirmed to exist. EC2 rows are keyed by
# resource id, everything else by full ARN.
: >"$TMP/live"

# Comma-joined ids of one EC2 resource type, e.g. ids_of instance.
ids_of() {
  cut -f2 "$TMP/tagged" |
    sed -n "s#^arn:[^:]*:ec2:[^:]*:[^:]*:$1/##p" |
    paste -sd, -
}

# One describe call per EC2 type, filtered on the ids. A filter (unlike --instance-ids)
# omits ids that no longer exist instead of failing the call. A failed call marks the ids UNKNOWN.
#   check_ec2 <arn type> <subcommand> <filter flag> <filter name> <query> [args]
check_ec2() {
  local type=$1 sub=$2 flag=$3 name=$4 query=$5 ids
  shift 5
  ids=$(ids_of "$type")
  [ -n "$ids" ] || return 0
  if ! aws ec2 "$sub" --region "$REGION" "$@" \
    "$flag" "Name=$name,Values=$ids" \
    --query "$query" --output text >>"$TMP/live" 2>"$TMP/err" </dev/null; then
    echo "$ids" | tr ',' '\n' | awk '{ printf "%s\tUNKNOWN\n", $0 }' >>"$TMP/live"
  fi
}

check_ec2 instance describe-instances --filters instance-id \
  'Reservations[].Instances[].[InstanceId,State.Name]'
check_ec2 volume describe-volumes --filters volume-id \
  'Volumes[].[VolumeId,State]'
check_ec2 snapshot describe-snapshots --filters snapshot-id \
  'Snapshots[].[SnapshotId,State]' --owner-ids self
check_ec2 image describe-images --filters image-id \
  'Images[].[ImageId,State]' --owners self
check_ec2 natgateway describe-nat-gateways --filter nat-gateway-id \
  'NatGateways[].[NatGatewayId,State]'
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
check_ec2 elastic-ip describe-addresses --filters allocation-id \
  'Addresses[].[AllocationId,`available`]'
check_ec2 vpc describe-vpcs --filters vpc-id \
  'Vpcs[].[VpcId,State]'
check_ec2 subnet describe-subnets --filters subnet-id \
  'Subnets[].[SubnetId,State]'
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
check_ec2 internet-gateway describe-internet-gateways --filters internet-gateway-id \
  'InternetGateways[].[InternetGatewayId,`available`]'
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
check_ec2 route-table describe-route-tables --filters route-table-id \
  'RouteTables[].[RouteTableId,`available`]'
check_ec2 vpc-endpoint describe-vpc-endpoints --filters vpc-endpoint-id \
  'VpcEndpoints[].[VpcEndpointId,State]'
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
check_ec2 security-group describe-security-groups --filters group-id \
  'SecurityGroups[].[GroupId,`available`]'
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
check_ec2 security-group-rule describe-security-group-rules --filters security-group-rule-id \
  'SecurityGroupRules[].[SecurityGroupRuleId,`available`]'

# Non-EC2 types: one call per ARN. "Not found" means gone; any other error is UNKNOWN.
# check_one <arn> <command...>
check_one() {
  local arn=$1 out
  shift
  if out=$("$@" 2>"$TMP/err" </dev/null); then
    printf '%s\t%s\n' "$arn" "${out:-available}" >>"$TMP/live"
  elif ! grep -qiE 'not ?found|NoSuchBucket|\(404\)' "$TMP/err"; then
    printf '%s\t%s\n' "$arn" "UNKNOWN" >>"$TMP/live"
  fi
}

while IFS= read -r arn; do
  case "$arn" in
    arn:*:elasticloadbalancing:*:loadbalancer/*)
      check_one "$arn" aws elbv2 describe-load-balancers --region "$REGION" \
        --load-balancer-arns "$arn" --query 'LoadBalancers[0].State.Code' --output text ;;
    arn:*:elasticloadbalancing:*:targetgroup/*)
      check_one "$arn" aws elbv2 describe-target-groups --region "$REGION" \
        --target-group-arns "$arn" --query 'length(TargetGroups)' --output text ;;
    arn:*:elasticloadbalancing:*:listener/*)
      check_one "$arn" aws elbv2 describe-listeners --region "$REGION" \
        --listener-arns "$arn" --query 'length(Listeners)' --output text ;;
    arn:*:elasticloadbalancing:*)
      printf '%s\t%s\n' "$arn" "UNKNOWN" >>"$TMP/live" ;;
    arn:*:s3:::*)
      check_one "$arn" aws s3api head-bucket --bucket "${arn##*:}" \
        --query 'BucketRegion' --output text ;;
  esac
done < <(cut -f2 "$TMP/tagged")

# EC2 types handled by check_ec2; any other tagged EC2 type is UNKNOWN, not gone.
CHECKED="instance volume snapshot image natgateway elastic-ip vpc subnet internet-gateway route-table vpc-endpoint security-group security-group-rule"

# Tagged ARN + confirmed state -> "<status> <type> <id> <name> <created>".
awk -F'\t' -v OFS='\t' -v checked="$CHECKED" '
  BEGIN { n = split(checked, t, " "); for (i = 1; i <= n; i++) ok[t[i]] = 1 }
  FILENAME == ARGV[1] { st[$1] = $2; next }
  {
    stamp = $1; arn = $2; name = $3; id = arn; sub(/.*\//, "", id)
    if (stamp == "" || stamp == "None") stamp = "-"
    if (name == "" || name == "None") name = "-"
    state = ""
    if (arn ~ /:ec2:/) {
      type = arn; sub(/^arn:[^:]*:ec2:[^:]*:[^:]*:/, "", type); sub(/\/.*/, "", type)
      if (type == "import-snapshot-task") state = "RECORD"
      else if (!(type in ok)) state = "UNKNOWN"
      else if (id in st) state = st[id]
      type = "ec2:" type
    } else if (arn ~ /:elasticloadbalancing:/) {
      type = arn; sub(/^arn:[^:]*:elasticloadbalancing:[^:]*:[^:]*:/, "", type); sub(/\/.*/, "", type)
      type = "elbv2:" type; id = arn
      if (arn in st) state = st[arn]
    } else if (arn ~ /:s3:::/) {
      type = "s3:bucket"; id = arn
      if (arn in st) state = st[arn]
    } else {
      type = arn; sub(/^arn:[^:]*:/, "", type); sub(/:.*/, "", type)
      type = type ":unknown"; id = arn; state = "UNKNOWN"
    }

    if (state == "RECORD" || state == "UNKNOWN") status = state
    else if (state == "" || state == "terminated" || state == "deleted") status = "gone"
    else status = "LIVE"
    print status, type, id, name, stamp
  }
' "$TMP/live" "$TMP/tagged" >"$TMP/report"

while IFS="$(printf '\t')" read -r status type id name created; do
  lo_row "$status" "$type" "$id" "$name" "$created"
done <"$TMP/report"

# IAM is global and not in the regional tagging API; the module names its roles
# and instance profile <cluster_name>-*. Listed objects exist, so they are LIVE.
roles=$(aws iam list-roles --output text \
  --query "Roles[?starts_with(RoleName,'$CLUSTER-')].RoleName" 2>"$TMP/err") ||
  lo_inconclusive "iam list-roles failed: $(head -n 1 "$TMP/err")"
profiles=$(aws iam list-instance-profiles --output text \
  --query "InstanceProfiles[?starts_with(InstanceProfileName,'$CLUSTER-')].InstanceProfileName" 2>"$TMP/err") ||
  lo_inconclusive "iam list-instance-profiles failed: $(head -n 1 "$TMP/err")"

for r in $(printf '%s' "$roles" | tr '\t' ' '); do
  [ "$r" = None ] || lo_row LIVE iam:role "$r" "$r" -
done
for p in $(printf '%s' "$profiles" | tr '\t' ' '); do
  [ "$p" = None ] || lo_row LIVE iam:instance-profile "$p" "$p" -
done

lo_finish
