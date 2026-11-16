#!/usr/bin/env bash
# Read-only check: OCI resources tagged elemental-cluster=<name> (Search service), plus the
# <name>-build bucket with its objects and PARs, and images named <name>-* (needs --compartment).
# Deletes nothing. Status meanings and coverage: docs/providers/oci.md#leftover-check.
LO_USAGE="oci.sh <cluster_name> [--region R] [--compartment OCID] [--all]   (region falls back to the OCI CLI profile)"
LO_FLAGS="region compartment"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/leftovers.sh"
lo_init "$@"
lo_need oci jq

CLUSTER=$LO_CLUSTER
TMP=$LO_TMP
case "$LO_COMPARTMENT" in *[!A-Za-z0-9._-]*) lo_usage_error "invalid compartment: $LO_COMPARTMENT" ;; esac
REGION_ARGS=()
LO_SCOPE="default region"
if [ -n "$LO_REGION" ]; then
  REGION_ARGS=(--region "$LO_REGION")
  LO_SCOPE="region $LO_REGION"
fi
[ -z "$LO_COMPARTMENT" ] || LO_SCOPE="$LO_SCOPE, compartment $LO_COMPARTMENT"

# oci <args>: the CLI with the region and no prompts; stderr in $TMP/err.
oci_cli() { oci "${REGION_ARGS[@]+"${REGION_ARGS[@]}"}" "$@" 2>"$TMP/err" </dev/null; }
# First line naming the error (the CLI may print a blank or usage line first).
oci_err() { grep -m 1 -E 'Error|"message"|"code"' "$TMP/err" || grep -m 1 . "$TMP/err" || true; }

# Search service: every indexed resource type, tenancy-wide (optionally one compartment).
# The index lags a few minutes behind changes, so a just-deleted resource can still show
# TERMINATING/TERMINATED.
QUERY="query all resources where (freeformTags.key = 'elemental-cluster' && freeformTags.value = '$CLUSTER'"
[ -z "$LO_COMPARTMENT" ] || QUERY="$QUERY && compartmentId = '$LO_COMPARTMENT'"
QUERY="$QUERY)"
# structured-search has no --all: follow opc-next-page and merge the pages.
PAGE="" PAGES=0
echo '{"data":{"items":[]}}' >"$TMP/search.json"
while :; do
  oci_cli search resource structured-search --query-text "$QUERY" --limit 1000 ${PAGE:+--page "$PAGE"} >"$TMP/page.json" ||
    lo_inconclusive "search failed: $(oci_err)"
  [ -s "$TMP/page.json" ] || break
  jq -s '{data: {items: ((.[0].data.items // []) + (.[1].data.items // []))}}' "$TMP/search.json" "$TMP/page.json" >"$TMP/merged.json" ||
    lo_inconclusive "search output unreadable"
  mv "$TMP/merged.json" "$TMP/search.json"
  PAGE=$(jq -r '."opc-next-page" // empty' "$TMP/page.json")
  PAGES=$((PAGES + 1))
  [ -n "$PAGE" ] && [ "$PAGES" -lt 50 ] || break
done

# state, type, id, name, created (elemental-created tag, else the API timestamp)
jq -r '(.data.items // [])[] | [
    (."lifecycle-state" // "-"),
    (."resource-type" // "unknown"),
    .identifier,
    (."display-name" // "-"),
    (."freeform-tags"["elemental-created"] // ."time-created" // "-")
  ] | map(tostring | gsub("[\t\n]"; " ")) | @tsv' "$TMP/search.json" >"$TMP/found" 2>"$TMP/err" ||
  lo_inconclusive "search output unreadable: $(oci_err)"

# "oci:<type>" rows; the build bucket is reported by the explicit check below.
: >"$TMP/seen"
while IFS="$(printf '\t')" read -r state type id name created; do
  [ -n "$id" ] || continue
  printf '%s\n' "$id" >>"$TMP/seen"
  [ "$type" = Bucket ] && [ "$name" = "$CLUSTER-build" ] && continue
  case "$state" in
    TERMINATED | DELETED) status=gone ;;
    *) status=LIVE ;;
  esac
  # The Search index can list a deleted image as AVAILABLE for hours: ask Compute.
  if [ "$type" = Image ] && [ "$status" = LIVE ]; then
    if oci_cli compute image get --image-id "$id" --query 'data."lifecycle-state"' --raw-output >"$TMP/img"; then
      case "$(head -n 1 "$TMP/img")" in DELETED) status=gone ;; esac
    elif grep -qE 'NotAuthorizedOrNotFound|"status": 404' "$TMP/err"; then
      status=gone
    else
      status=UNKNOWN
    fi
  fi
  lo_row "$status" "oci:$type" "$id" "$name" "$created"
done <"$TMP/found"

# Explicit checks. A missing bucket is gone; any other error is UNKNOWN.
oci_cli os ns get --query data --raw-output >"$TMP/ns" ||
  lo_inconclusive "object storage namespace lookup failed: $(oci_err)"
NS=$(head -n 1 "$TMP/ns")
BUCKET="$CLUSTER-build"
if oci_cli os bucket get --namespace-name "$NS" --bucket-name "$BUCKET" >"$TMP/bucket.json"; then
  lo_row LIVE oci:bucket "$BUCKET" "$BUCKET" \
    "$(jq -r '.data."freeform-tags"["elemental-created"] // .data."time-created" // "-"' "$TMP/bucket.json")"
  if oci_cli os object list --namespace-name "$NS" --bucket-name "$BUCKET" --all >"$TMP/objects.json"; then
    jq -r '(.data // [])[] | .name' "$TMP/objects.json" | while IFS= read -r o; do
      lo_row LIVE oci:object "$BUCKET/$o" "$o" -
    done
  else
    lo_row UNKNOWN oci:object "$BUCKET/*" "list failed" -
  fi
  if oci_cli os preauth-request list --namespace-name "$NS" --bucket-name "$BUCKET" --all >"$TMP/pars.json"; then
    jq -r '(.data // [])[] | [.id, (.name // "-")] | @tsv' "$TMP/pars.json" |
      while IFS="$(printf '\t')" read -r id name; do
        lo_row LIVE oci:par "$id" "$name" -
      done
  else
    lo_row UNKNOWN oci:par "$BUCKET/*" "list failed" -
  fi
elif grep -qE 'BucketNotFound|NamespaceNotFound|"status": 404' "$TMP/err"; then
  :
else
  lo_row UNKNOWN oci:bucket "$BUCKET" "$(oci_err | cut -c1-36)" -
fi

# Images by name (<cluster>-<12-hex build id>, so a cluster sharing the prefix does not match);
# catches images without the tag.
if [ -n "$LO_COMPARTMENT" ]; then
  if oci_cli compute image list --compartment-id "$LO_COMPARTMENT" --all >"$TMP/images.json"; then
    jq -r --arg p "$CLUSTER-" '(.data // [])[]
      | select((."display-name" // "") | test("^" + $p + "[0-9a-f]{12}$"))
      | [.id, ."display-name", (."lifecycle-state" // "-"), (."freeform-tags"["elemental-created"] // ."time-created" // "-")]
      | @tsv' "$TMP/images.json" |
      while IFS="$(printf '\t')" read -r id name state created; do
        grep -qxF "$id" "$TMP/seen" && continue
        case "$state" in DELETED | TERMINATED) status=gone ;; *) status=LIVE ;; esac
        lo_row "$status" oci:image "$id" "$name" "$created"
      done
  else
    lo_row UNKNOWN oci:image "$CLUSTER-*" "list failed" -
  fi
fi

lo_finish
