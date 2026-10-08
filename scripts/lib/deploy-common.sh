#!/usr/bin/env bash
# Sourced by examples/<p>/deploy.sh (after `cd` into its own directory).
#
#   DEPLOY_PROVIDER=<p>            required, selects ../common-<p>.tfvars
#   DEPLOY_PASS_TOTAL=<n>          optional, for "[i/n]" in pass headers
#   deploy_passes()                required hook: calls tf_pass once per pass
#   deploy_precheck()              optional hook: provider-only checks, before any pass
#   deploy_destroy()               optional hook: replaces the default single destroy pass
#   deploy_after_destroy()         optional hook: runs after a successful destroy (suggests the leftover check)
#   deploy_on_crash / tf_retry_on  optional workarounds, see tf.sh
#   deploy_main "$@"
#
# Optional env (see tf.sh): DEPLOY_EVENTS_FD, DEPLOY_CONFIRM_FD.
#
# Sets: DEPLOY_REBUILD, DEPLOY_YES, DEPLOY_DESTROY, DEPLOY_VERBOSITY, DEPLOY_TF_ARGS,
# DEPLOY_VAR_FILES, DEPLOY_TTY, DEPLOY_CI.

set -o pipefail

DEPLOY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tf.sh
. "$DEPLOY_LIB_DIR/tf.sh"

DEPLOY_REBUILD=0
DEPLOY_REBUILD_FILE=rebuild.auto.tfvars.json
DEPLOY_YES=0
DEPLOY_DESTROY=0
DEPLOY_VERBOSITY=normal
DEPLOY_TF_ARGS=()
DEPLOY_VAR_FILES=()

deploy_usage() {
  cat <<'EOF'
Usage: deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform args>]

  --rebuild   bump the image rebuild counter (rebuild.auto.tfvars.json) to force a new image
  --yes       do not ask for confirmation (required without a terminal)
  -v          stream the full Terraform output
  -q          print only step headers, diagnostics and the summary
  --destroy   plan and apply a destroy
  --          pass everything after it to `terraform plan`

Var files, later wins: ../../common-all.tfvars, ../common-all.tfvars,
../common-<provider>.tfvars, terraform.tfvars (only those that exist).
EOF
}

deploy_die() {
  echo "error: $*" >&2
  exit 1
}

deploy_parse_args() {
  local verbosity_set=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rebuild) DEPLOY_REBUILD=1 ;;
      --yes | -y) DEPLOY_YES=1 ;;
      --destroy) DEPLOY_DESTROY=1 ;;
      -v | --verbose | -q | --quiet)
        case "$1" in -v | --verbose) verbosity_set=verbose ;; *) verbosity_set=quiet ;; esac
        if [ "$DEPLOY_VERBOSITY" != normal ] && [ "$DEPLOY_VERBOSITY" != "$verbosity_set" ]; then
          deploy_die "-v and -q cannot be combined"
        fi
        DEPLOY_VERBOSITY=$verbosity_set
        ;;
      -h | --help)
        deploy_usage
        exit 0
        ;;
      --)
        shift
        DEPLOY_TF_ARGS=("$@")
        return 0
        ;;
      *)
        deploy_usage >&2
        deploy_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

deploy_check_deps() {
  local missing="" c
  for c in terraform jq ssh; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || deploy_die "missing required tools:$missing"
}

# -var-file arguments for the files that exist, lowest precedence first.
deploy_var_files() {
  local f
  DEPLOY_VAR_FILES=()
  for f in ../../common-all.tfvars ../common-all.tfvars "../common-${DEPLOY_PROVIDER}.tfvars" terraform.tfvars; do
    [ -f "$f" ] && DEPLOY_VAR_FILES+=("-var-file=$f")
  done
  return 0
}

# deploy_var_string <name>: string value of <name> from TF_VAR_<name>, the var files, then
# -var in the tf args (Terraform's precedence, last wins); empty if unset or null.
# -var-file in the tf args and *.auto.tfvars are not read.
deploy_var_string() {
  local a f v env="TF_VAR_$1" out next=0
  out=${!env:-}
  for a in ${DEPLOY_VAR_FILES[@]+"${DEPLOY_VAR_FILES[@]}"}; do
    f=${a#-var-file=}
    v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$f" | tail -n 1)
    if [ -n "$v" ]; then
      out=$v
    elif grep -Eq "^[[:space:]]*$1[[:space:]]*=" "$f"; then
      out=""
    fi
  done
  for a in ${DEPLOY_TF_ARGS[@]+"${DEPLOY_TF_ARGS[@]}"}; do
    if [ "$next" = 1 ]; then
      next=0
    elif [ "$a" = -var ]; then
      next=1
      continue
    elif [ "${a#-var=}" != "$a" ]; then
      a=${a#-var=}
    else
      continue
    fi
    case "$a" in "$1="*) out=${a#"$1="} ;; esac
  done
  echo "$out"
}

# cluster_name as Terraform sees it, else the variable default.
deploy_cluster_name() {
  local name
  name=$(deploy_var_string cluster_name)
  echo "${name:-suse-ai-factory}"
}

# deploy_suggest_leftovers [VAR=<placeholder>] <tool> <args...>: prints the read-only
# tools/leftovers/<tool>.sh command for the user to run; never runs it. No secrets in the args.
deploy_suggest_leftovers() {
  local env="" tool
  case "$1" in *=*) env="$1 " && shift ;; esac
  tool="$(cd "$DEPLOY_LIB_DIR/../.." && pwd)/tools/leftovers/$1.sh"
  shift
  printf '\nCheck for leftovers (read-only, expect "0 live, 0 unknown"):\n  %s%s %s\n' "$env" "$tool" "$*"
}

deploy_detect_tty() {
  if [ -n "${CI:-}" ] || [ ! -t 1 ]; then
    DEPLOY_TTY=${DEPLOY_TTY:-0}
  else
    DEPLOY_TTY=${DEPLOY_TTY:-1}
  fi
  # shellcheck disable=SC2034 # read by provider deploy.sh hooks
  DEPLOY_CI=$((1 - DEPLOY_TTY))
}

deploy_init() {
  local rc=0 log
  [ -d .terraform ] && return 0
  tf__logdir
  log="$DEPLOY_LOG_DIR/init.log"
  tf__say "==> terraform init"
  terraform init -input=false -no-color >"$log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || tf__fail "terraform init" "$rc" "$log"
}

# Current rebuild counter: the larger of the state's image.rebuild and the
# persisted file, so a lost file never lowers it.
deploy_rebuild_state() {
  local v
  v=$(terraform output -json image 2>/dev/null | jq -r '.rebuild // 0' 2>/dev/null) || v=0
  echo "${v:-0}"
}

deploy_rebuild_file() {
  local v=0
  if [ -f "$DEPLOY_REBUILD_FILE" ]; then
    v=$(jq -r '.image_rebuild // 0' "$DEPLOY_REBUILD_FILE" 2>/dev/null) || v=x
  fi
  echo "${v:-0}"
}

deploy_rebuild_write() {
  printf '{\n  "image_rebuild": %s\n}\n' "$1" >"$DEPLOY_REBUILD_FILE" ||
    deploy_die "cannot write $DEPLOY_REBUILD_FILE"
}

# A var file setting image_rebuild overrides the auto file.
deploy_rebuild_var_file_check() {
  local a f
  for a in ${DEPLOY_VAR_FILES[@]+"${DEPLOY_VAR_FILES[@]}"}; do
    f=${a#-var-file=}
    if grep -Eq '^[[:space:]]*image_rebuild[[:space:]]*=' "$f"; then
      deploy_die "image_rebuild is set in $f, which overrides $DEPLOY_REBUILD_FILE; remove it"
    fi
  done
  return 0
}

deploy_rebuild_current() {
  local s f
  s=$(deploy_rebuild_state)
  f=$(deploy_rebuild_file)
  case "$s$f" in *[!0-9]*) deploy_die "cannot read the current image rebuild counter" ;; esac
  if [ "$s" -ge "$f" ]; then echo "$s"; else echo "$f"; fi
}

# --rebuild: persist counter+1 so a later plain run keeps the new value.
deploy_bump_rebuild() {
  local cur next
  deploy_rebuild_var_file_check
  cur=$(deploy_rebuild_current)
  next=$((cur + 1))
  deploy_rebuild_write "$next"
  tf__say "note: --rebuild sets image_rebuild=$next ($DEPLOY_REBUILD_FILE)."
}

# Plain run: restore the file when state is ahead (fresh checkout, deleted
# file), or the build hash would change and rebuild the image.
deploy_keep_rebuild() {
  local s f
  s=$(deploy_rebuild_state)
  f=$(deploy_rebuild_file)
  case "$s$f" in *[!0-9]*) return 0 ;; esac
  [ "$s" -gt "$f" ] || return 0
  deploy_rebuild_var_file_check
  deploy_rebuild_write "$s"
  tf__say "note: restored image_rebuild=$s from state ($DEPLOY_REBUILD_FILE)."
}

deploy_print_next_steps() {
  local out
  out=$(terraform output -raw next_steps 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  echo
  printf '%s\n' "$out"
  if [ -n "${DEPLOY_LOG_DIR:-}" ]; then
    echo "Logs           : $DEPLOY_LOG_DIR/"
  fi
}

# EXIT trap: remove plan files, then emit the final `done` event (when DEPLOY_EVENTS_FD is set).
deploy__exit() {
  local rc=$?
  tf__cleanup
  tf__events_finish "$rc"
  return "$rc"
}

deploy_main() {
  [ -n "${DEPLOY_PROVIDER:-}" ] || deploy_die "DEPLOY_PROVIDER is not set"
  deploy_parse_args "$@"
  deploy_detect_tty
  deploy_check_deps
  deploy_var_files
  trap deploy__exit EXIT
  # shellcheck disable=SC2016 # jq program, not shell
  if [ "$DEPLOY_DESTROY" = 1 ]; then
    tf__event start '{provider: $p, action: "destroy", pass_total: 1}' --arg p "$DEPLOY_PROVIDER"
  else
    tf__event start '{provider: $p, action: "deploy", pass_total: $t}' --arg p "$DEPLOY_PROVIDER" \
      --argjson t "$(tf__pass_total)"
  fi

  if [ "$DEPLOY_VERBOSITY" != quiet ]; then
    tf__version_note
    if [ "${#DEPLOY_VAR_FILES[@]}" -gt 0 ]; then
      echo "var-files      : ${DEPLOY_VAR_FILES[*]#-var-file=}"
    fi
  fi
  if declare -F deploy_precheck >/dev/null; then deploy_precheck; fi
  deploy_init

  if [ "$DEPLOY_DESTROY" = 1 ]; then
    DEPLOY_PASS_TOTAL=""
    if declare -F deploy_destroy >/dev/null; then
      deploy_destroy
    else
      tf_pass "Destroy" -destroy
    fi
    if declare -F deploy_after_destroy >/dev/null; then deploy_after_destroy; fi
    if [ -n "${DEPLOY_LOG_DIR:-}" ]; then
      echo
      echo "Logs           : $DEPLOY_LOG_DIR/"
    fi
    return 0
  fi

  declare -F deploy_passes >/dev/null || deploy_die "deploy_passes is not defined"
  if [ "$DEPLOY_REBUILD" = 1 ]; then deploy_bump_rebuild; else deploy_keep_rebuild; fi
  deploy_passes
  deploy_print_next_steps
}
