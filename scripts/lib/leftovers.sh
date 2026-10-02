#!/usr/bin/env bash
# shellcheck disable=SC2034  # LO_* are read by the sourcing tool
# Sourced by tools/leftovers/<provider>.sh. Common arguments, report and exit codes.
#
#   lo_init "$@"                       parse args; sets LO_CLUSTER, LO_REGION, LO_PROJECT, LO_ALL, LO_TMP
#   lo_row <status> <type> <id> <name> [created]
#                                      status: LIVE | RECORD | UNKNOWN | gone
#   lo_finish                          print the report (header shows LO_SCOPE if set), exit 0 or 1
#   lo_inconclusive <msg>              exit 3 (credentials, list call failed, CLI missing)
#   lo_usage_error <msg>               exit 2
#
# The provider script sets LO_USAGE (usage line) and LO_FLAGS (accepted flags:
# any of "region project") before lo_init. Bash 3.2 compatible.

set -euo pipefail

lo_usage_error() {
  echo "error: $1" >&2
  echo "usage: ${LO_USAGE:-}" >&2
  exit 2
}

lo_inconclusive() {
  echo "inconclusive: $1" >&2
  exit 3
}

lo_need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || lo_inconclusive "$c not installed"
  done
}

lo_init() {
  LO_CLUSTER="" LO_REGION="" LO_PROJECT="" LO_SCOPE="" LO_ALL=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        echo "usage: ${LO_USAGE:-}"
        exit 0
        ;;
      --all) LO_ALL=1 ;;
      --region | --project)
        case " ${LO_FLAGS:-} " in *" ${1#--} "*) ;; *) lo_usage_error "unknown flag: $1" ;; esac
        if [ $# -lt 2 ] || [ -z "$2" ]; then lo_usage_error "$1 needs a value"; fi
        if [ "$1" = --region ]; then LO_REGION=$2; else LO_PROJECT=$2; fi
        shift
        ;;
      -*) lo_usage_error "unknown flag: $1" ;;
      *)
        [ -z "$LO_CLUSTER" ] || lo_usage_error "unexpected argument: $1"
        LO_CLUSTER=$1
        ;;
    esac
    shift
  done
  [ -n "$LO_CLUSTER" ] || lo_usage_error "cluster name missing"
  # Same rule as cluster_name in modules/common/variables-common.tf.
  case "$LO_CLUSTER" in
    -* | *- | *[!a-z0-9-]*) lo_usage_error "invalid cluster name: $LO_CLUSTER" ;;
  esac
  [ "${#LO_CLUSTER}" -le 63 ] || lo_usage_error "invalid cluster name: longer than 63 characters"
  LO_TMP=$(mktemp -d "${TMPDIR:-/tmp}/leftovers.XXXXXX")
  # shellcheck disable=SC2064  # expand now: LO_TMP is fixed
  trap "rm -rf '$LO_TMP'" EXIT
  : >"$LO_TMP/rows"
}

lo_row() {
  case "$1" in LIVE | RECORD | UNKNOWN | gone) ;; *) lo_usage_error "lo_row: bad status $1" ;; esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" "${5:--}" >>"$LO_TMP/rows"
}

lo_finish() {
  local live records unknown gone
  live=$(grep -c '^LIVE	' "$LO_TMP/rows" || true)
  records=$(grep -c '^RECORD	' "$LO_TMP/rows" || true)
  unknown=$(grep -c '^UNKNOWN	' "$LO_TMP/rows" || true)
  gone=$(grep -c '^gone	' "$LO_TMP/rows" || true)

  echo "== $LO_CLUSTER${LO_SCOPE:+ ($LO_SCOPE)}: status, type, id, name, created =="
  sort -t "$(printf '\t')" -k2,2 -k3,3 "$LO_TMP/rows" |
    awk -F'\t' -v all="$LO_ALL" '$1 != "gone" || all == 1 {
      printf "%-8s %-28s %-40s %-36s %s\n", $1, $2, $3, $4, $5 }'
  echo
  echo "$live live, $records record, $unknown unknown, $gone gone"
  if [ "$live" -eq 0 ] && [ "$unknown" -eq 0 ]; then exit 0; fi
  exit 1
}
