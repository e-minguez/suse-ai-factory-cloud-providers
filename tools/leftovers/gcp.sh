#!/usr/bin/env bash
# Read-only check: GCP resources labelled elemental-cluster=<name> (instances, disks, images,
# snapshots, addresses, forwarding rules) and unlabelled ones named <name> or <name>-* (firewall
# rules, routers, instance groups, backend services, health checks, subnetworks, networks).
# Deletes nothing. The name match also covers a cluster whose name starts with "<name>-".
LO_USAGE="gcp.sh <cluster_name> [--project P] [--all]   (project falls back to gcloud config)"
LO_FLAGS="project"
# shellcheck source=../../scripts/lib/leftovers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/leftovers.sh"
lo_init "$@"
lo_need gcloud jq

CLUSTER=$LO_CLUSTER
TMP=$LO_TMP
if [ -z "$LO_PROJECT" ]; then
  LO_PROJECT=$(gcloud config get-value project 2>/dev/null </dev/null | head -n 1 || true)
  case "$LO_PROJECT" in "" | "(unset)") lo_inconclusive "no project: use --project or gcloud config set project" ;; esac
fi
case "$LO_PROJECT" in *[!a-z0-9:.-]*) lo_usage_error "invalid project: $LO_PROJECT" ;; esac
PROJECT=$LO_PROJECT
LO_SCOPE="project $PROJECT"

# gather <by> <type> <gcloud args...>: lists "gcloud compute <args>" filtered by label (by=label)
# or name (by=name: the VPC, subnet and router are named <cluster>, the rest <cluster>-*); one
# LIVE row per resource, located by zone, region or global.
gather() {
  local by=$1 type=$2 filter
  shift 2
  case "$by" in
    label) filter="labels.elemental-cluster=$CLUSTER" ;;
    *) filter="name ~ ^$CLUSTER(-|\$)" ;;
  esac
  gcloud compute "$@" list --project "$PROJECT" --filter="$filter" --format=json >"$TMP/list.json" 2>"$TMP/err" </dev/null ||
    lo_inconclusive "$type list failed: $(grep -m 1 . "$TMP/err" || true)"
  # name, zone, region (last path element of the URL, "-" if absent: read collapses empty tab fields), created
  jq -r '.[] | [
      .name,
      (((.zone // "") | split("/") | last) // "-"),
      (((.region // "") | split("/") | last) // "-"),
      (.labels["elemental-created"] // .creationTimestamp // "-")
    ] | map(tostring | gsub("[\t\n]"; " ")) | @tsv' "$TMP/list.json" >"$TMP/found" 2>"$TMP/err" ||
    lo_inconclusive "$type output unreadable: $(grep -m 1 . "$TMP/err" || true)"
  local name zone region created loc
  while IFS="$(printf '\t')" read -r name zone region created; do
    [ -n "$name" ] || continue
    loc=""
    if [ "$zone" != - ]; then
      loc="$zone"
    elif [ "$region" != - ]; then
      loc="$region"
    else
      case "$type" in
        address | forwarding-rule | backend-service | health-check) loc=global ;;
      esac
    fi
    lo_row LIVE "gcp:$type" "${loc:+$loc/}$name" "$name" "$created"
  done <"$TMP/found"
}

gather label forwarding-rule forwarding-rules
gather name backend-service backend-services
gather name health-check health-checks
gather name instance-group instance-groups managed
gather name instance-group instance-groups unmanaged
gather label instance instances
gather label disk disks
gather label snapshot snapshots
gather label image images
gather label address addresses
gather name router routers
gather name firewall-rule firewall-rules
gather name subnetwork networks subnets
gather name network networks

lo_finish
