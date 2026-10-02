#!/usr/bin/env bash
# Sourced by deploy-common.sh. Plan, confirm, apply and render one Terraform pass.
#
#   tf_pass <name> [terraform plan args...]   never returns on failure (exits)
#   tf_retry_on <ERE> [max_attempts] [note]   retry a failed apply when the log matches
#   deploy_on_crash <pass> <log>              optional hook, see tf__crash
#   TF_PLAN_HOOK=<fn>                         optional: called as <fn> <plan.json> after each plan;
#                                             returns 1 after changing inputs to have the plan redone
#
# Reads (all optional): DEPLOY_YES, DEPLOY_VERBOSITY (quiet|normal|verbose), DEPLOY_TTY (0|1),
# DEPLOY_VAR_FILES, DEPLOY_TF_ARGS, DEPLOY_PASS_TOTAL, DEPLOY_LOG_DIR, TF_STATE_DIR (default .deploy),
# TF_RETRY_SLEEP.
# Needs bash >= 3.2, jq, terraform. Callers run with `set -euo pipefail`.

TF_STATE_DIR="${TF_STATE_DIR:-.deploy}"
TF_PASS_INDEX=0
TF_RETRY_RE=()
TF_RETRY_MAX=()
TF_RETRY_NOTE=()
TF_CRASH_RETRIED=0

# Group a resource type into a display category (shared by plan totals and the apply renderer).
# shellcheck disable=SC2016 # jq program, not shell
TF_JQ_DEFS='
def cat:
  if test("(^|_)(iam|role|policy|key_pair|ssh_key|instance_profile)(_|$)") then "identity"
  elif test("security_group|firewall|nsg|sg_rule") then "firewall"
  elif test("(^|_)(lb|elb|alb|nlb|load_?balancer|target_group|listener|l4|backend)(_|$)") then "load balancers"
  elif test("vpc|subnet|route|gateway|nat_|eip|network|vnet|dhcp") then "network"
  elif test("(instance|server|bare_metal|virtual_machine|vm)(_|$)") then "compute"
  elif test("s3|bucket|snapshot|ami|image|disk|volume|storage") then "images and storage"
  elif test("^(random|tls|null|time|local|terraform_data|http)") then "helpers"
  else "other" end;
def fmt: floor as $s | "\($s / 60 | floor):\(($s % 60) | tostring | if length < 2 then "0" + . else . end)";
def fmt_min: floor | if . < 60 then "\(.)s" else "\(. / 60 | floor)m" end;
'

# Renders the `terraform apply -json` stream (and raw non-JSON lines such as a crash trace).
# Args: tty (0|1), quiet (0|1), totals (object category -> expected completions).
# shellcheck disable=SC2016 # jq program, not shell
TF_JQ_RENDER='
def clr: if $tty == 1 then "\r\u001b[K" else "" end;
def short: sub("^(module\\.[^.]+(\\[[^\\]]*\\])?\\.)+"; "");
foreach (inputs | ((fromjson? | select(type == "object")) // {type: "raw", "@message": .})) as $e
  ({done: {}, last: {}, out: [], t0: now};
   .out = [] |
   if $e.type == "apply_complete" and $quiet == 0 then
     ($e.hook.resource.resource_type // "" | cat) as $c
     | .done[$c] = ((.done[$c] // 0) + 1)
     | if ($totals[$c] // 0) > 0 and .done[$c] == $totals[$c]
       then .out = [clr + "    ✓ " + $c + " (" + ($totals[$c] | tostring) + ")  (" + ((now - .t0) | fmt) + ")\n"]
       else . end
   elif $e.type == "apply_errored" then
     .out = [clr + "    ✗ " + ($e["@message"] // "") + "\n"]
   elif $e.type == "apply_progress" and $quiet == 0 then
     if $tty == 1 then .out = ["\r\u001b[K    … " + ($e["@message"] // "")] else . end
   elif $e.type == "provision_progress" and $quiet == 0 then
     ((($e.hook.output // "") | capture("status=(?<s>[^ ]+) elapsed=(?<t>[0-9]+)(?<rest>.*)")) // null) as $m
     | if $m == null then . else
         ($e.hook.resource.addr | short) as $a
         | $m.s as $s
         | (.last[$a] != $s) as $chg
         | .last[$a] = $s
         | ("    … " + $a + ": " + $s + "  " + ($m.t | tonumber | fmt_min) + " elapsed"
            + ($m.rest | gsub("^\\s+|\\s+$"; "") | if . == "" then "" else "  " + . end)) as $line
         | if $chg or $s == "done" or $s == "failed" or $s == "timeout" then .out = [clr + $line + "\n"]
           elif $tty == 1 then .out = ["\r\u001b[K" + $line] else . end
       end
   elif $e.type == "diagnostic" then
     .out = [clr + "\n" + (($e.diagnostic.severity // "error") | (.[0:1] | ascii_upcase) + .[1:]) + ": "
             + ($e.diagnostic.summary // "") + (if $e.diagnostic.address then "  (" + $e.diagnostic.address + ")" else "" end)
             + "\n" + (if ($e.diagnostic.detail // "") != "" then $e.diagnostic.detail + "\n" else "" end)]
   elif $e.type == "change_summary" then
     ($e.changes // {}) as $c
     | .out = [clr + "    " + (if $c.operation == "destroy" then "destroy: \($c.remove // 0) destroyed"
                              else "apply: \($c.add // 0) added, \($c.change // 0) changed, \($c.remove // 0) destroyed" end)
               + (if ($c.import // 0) > 0 then ", \($c.import) imported" else "" end) + "\n"]
   elif $e.type == "raw" and (($e["@message"] // "") != "") then
     .out = [clr + $e["@message"] + "\n"]
   else . end;
   .out[])
'

tf__say() { [ "${DEPLOY_VERBOSITY:-normal}" = quiet ] || printf '%s\n' "$*"; }

tf__logdir() {
  if [ -z "${DEPLOY_LOG_DIR:-}" ]; then
    # Absolute, so the printed log paths work from any directory.
    case "$TF_STATE_DIR" in /*) DEPLOY_LOG_DIR=$TF_STATE_DIR ;; *) DEPLOY_LOG_DIR=$PWD/$TF_STATE_DIR ;; esac
    DEPLOY_LOG_DIR="$DEPLOY_LOG_DIR/logs/$(date +%Y%m%d-%H%M%S)"
  fi
  if [ ! -d "$DEPLOY_LOG_DIR" ]; then
    (umask 077 && mkdir -p "$DEPLOY_LOG_DIR")
  fi
  chmod 700 "$TF_STATE_DIR" 2>/dev/null || true
}

tf__cleanup() {
  rm -f "$TF_STATE_DIR"/*.tfplan "$TF_STATE_DIR"/.plan-show.* 2>/dev/null || true
}

tf__slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# Print the last 30 log lines, the log location and exit with the failure code.
tf__fail() {
  local what=$1 rc=$2 log=$3
  echo
  echo "==> FAILED: $what (exit $rc)"
  if [ -s "$log" ]; then
    echo "--- last 30 lines of $log"
    tail -n 30 "$log"
    echo "---"
  fi
  echo "Logs           : ${DEPLOY_LOG_DIR:-$TF_STATE_DIR/logs}/"
  tf__cleanup
  exit "$rc"
}

# Human-readable log from a -json stream (also keeps non-JSON lines such as panics).
tf__humanize() {
  jq -R -r '((fromjson? | select(type == "object")) // {type: "raw", "@message": .})
    | if .type == "diagnostic" then (.["@message"] // "") + "\n" + (.diagnostic.detail // "")
      else (.["@message"] // empty) end' "$1"
}

# Warning blocks of a -no-color plan log; they end at the horizontal rule before "Saved the plan".
tf__plan_warnings() {
  awk '/^Warning: / { p = 1 } /^─/ { p = 0 } p' "$1" | sed 's/^/    /'
}

# Plan summary text from `terraform show -json` output: counts, then creates (first 20), updates,
# replacements and destroys.
tf__plan_report() {
  jq -r '
    [.resource_changes[]? | {addr: .address, a: .change.actions, r: (.action_reason // "")}
      | select(.a != ["no-op"] and .a != ["read"] and .a != ["forget"])] as $ch
    | ($ch | map(select(.a == ["create"] or (.a | length) == 2)) | length) as $add
    | ($ch | map(select(.a == ["update"])) | length) as $upd
    | ($ch | map(select(.a == ["delete"] or (.a | length) == 2)) | length) as $del
    | ($ch | map(select((.a | length) == 2))) as $rep
    | ($ch | map(select(.a == ["delete"]))) as $des
    | ($ch | map(select(.a == ["create"]))) as $cre
    | ($ch | map(select(.a == ["update"]))) as $updl
    | ([.resource_changes[]? | select(.change.importing != null)] | length) as $imp
    | ([.resource_changes[]? | select(.change.actions == ["forget"])] | length) as $fgt
    | ([.output_changes // {} | .[] | select(.actions != ["no-op"])] | length) as $out
    | "    plan: \($add) to add, \($upd) to change, \($del) to destroy"
      + (if $imp > 0 then ", \($imp) to import" else "" end) + (if $fgt > 0 then ", \($fgt) to forget" else "" end)
      + (if $out > 0 then ", \($out) outputs changed" else "" end),
      (if ($cre | length) > 0 then "    create (\($cre | length)):", ($cre[:20][] | "      +   \(.addr)"),
        (if ($cre | length) > 20 then "      ... \(($cre | length) - 20) more in the plan log" else empty end) else empty end),
      (if ($updl | length) > 0 then "    update (\($updl | length)):", ($updl[] | "      ~   \(.addr)") else empty end),
      (if ($rep | length) > 0 then "    replace (\($rep | length)):", ($rep[] | "      -/+ \(.addr)" + (if .r != "" then "  (\(.r))" else "" end)) else empty end),
      (if ($des | length) > 0 then "    destroy (\($des | length)):", ($des[] | "      -   \(.addr)") else empty end),
      (if $out > 0 then "    outputs (\($out)):", (.output_changes | to_entries[] | select(.value.actions != ["no-op"])
        | "      \(.value.actions | if . == ["create"] then "+  " elif . == ["delete"] then "-  " else "~  " end) \(.key)") else empty end)
  ' "$1"
}

# Number of deletes (plain or as part of a replacement).
tf__plan_destructive() {
  jq -r '[.resource_changes[]? | .change.actions | select(index("delete"))] | length' "$1"
}

# Anything an apply would write: resource actions (forget included), imports, output changes.
tf__plan_total() {
  jq -r '[(.resource_changes[]? | select((.change.actions != ["no-op"] and .change.actions != ["read"]) or .change.importing != null)),
    (.output_changes // {} | .[] | select(.actions != ["no-op"]))] | length' "$1"
}

# Expected apply_complete events per category (a replacement completes twice).
tf__plan_totals() {
  jq -c "$TF_JQ_DEFS"'
    [.resource_changes[]? | .change.actions as $a | select($a != ["no-op"] and $a != ["read"] and $a != ["forget"])
      | {c: (.type | cat), n: (if ($a | length) == 2 then 2 else 1 end)}]
    | group_by(.c) | map({key: .[0].c, value: (map(.n) | add)}) | from_entries' "$1"
}

tf__confirm() {
  local ans=""
  [ "${DEPLOY_YES:-0}" = 1 ] && return 0
  printf '    Apply this plan? [y/N] '
  read -r ans || ans=""
  case "$ans" in y | Y | yes | YES) return 0 ;; esac
  echo
  echo "    Aborted, nothing applied. (Non-interactive runs need --yes.)"
  return 1
}

tf__version_note() {
  local v
  v=$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null) || v=""
  # TEMPORARY WORKAROUND (docs/workarounds.md, Terraform crash): remove with 1.16.5.
  if [ "$v" = 1.16.4 ]; then
    echo "note: Terraform 1.16.4 can crash while applying (hashicorp/terraform#39283); 1.16.5 or later is not affected."
  fi
}

# TEMPORARY WORKAROUND (docs/workarounds.md, Terraform crash): remove with 1.16.5.
# Returns 0 to retry once: only when deploy_on_crash <pass> <log>, if defined, reconciled the
# state (a crash can leave created objects out of it) and returned 0. Returns 1 to stop.
tf__crash() {
  local pass=$1 log=$2
  grep -q 'TERRAFORM CRASH' "$log" || return 1
  echo
  echo "ERROR: $pass: Terraform crashed (hashicorp/terraform#39283, fixed in 1.16.5)."
  echo "       Objects created during this apply may be missing from the state while they"
  echo "       still exist in the cloud project. Do not delete the state and do not rely on"
  echo "       'terraform destroy' now: it only sees what is in state."
  if [ "$TF_CRASH_RETRIED" = 0 ] && declare -F deploy_on_crash >/dev/null && deploy_on_crash "$pass" "$log"; then
    TF_CRASH_RETRIED=1
    echo "       State reconciled by deploy_on_crash; retrying once."
    return 0
  fi
  echo "       Re-run deploy.sh; upgrade Terraform to 1.16.5 or later if the trace mentions 'ObjectStatus(0)'."
  return 1
}

# TEMPORARY WORKAROUND (docs/workarounds.md, retry on pattern; evroc 409 on load-balancer writes):
# register an ERE. A failed apply whose log matches is re-planned and re-applied (asking again
# only if the new plan deletes something) up to max_attempts total attempts. Other failures stop.
tf_retry_on() {
  TF_RETRY_RE+=("$1")
  TF_RETRY_MAX+=("${2:-3}")
  TF_RETRY_NOTE+=("${3:-matched a retryable error}")
}

# Echo the note when a registered pattern matches and attempts remain; return 0 to retry.
tf__retry_match() {
  local log=$1 attempt=$2 i
  for ((i = 0; i < ${#TF_RETRY_RE[@]}; i++)); do
    if grep -Eq -- "${TF_RETRY_RE[$i]}" "$log"; then
      if [ "$attempt" -ge "${TF_RETRY_MAX[$i]}" ]; then
        echo "    ${TF_RETRY_NOTE[$i]}: still failing after ${TF_RETRY_MAX[$i]} attempts."
        return 1
      fi
      echo "    ${TF_RETRY_NOTE[$i]}; re-planning, attempt $((attempt + 1)) of ${TF_RETRY_MAX[$i]}."
      return 0
    fi
  done
  return 1
}

tf__plan_args() {
  TF__PLAN_ARGS=()
  local a
  for a in ${DEPLOY_VAR_FILES[@]+"${DEPLOY_VAR_FILES[@]}"} "$@" ${DEPLOY_TF_ARGS[@]+"${DEPLOY_TF_ARGS[@]}"}; do
    [ "$a" = -auto-approve ] || TF__PLAN_ARGS+=("$a")
  done
}

# tf_pass <name> [terraform plan args...]
tf_pass() {
  local name=$1
  shift
  local slug plan planlog showjson mode attempt=1 t0 rc totals tty quiet jsonl applylog suffix
  slug=$(tf__slug "$name")
  mode=${DEPLOY_VERBOSITY:-normal}
  tty=${DEPLOY_TTY:-0}
  quiet=0
  [ "$mode" = quiet ] && quiet=1
  TF_PASS_INDEX=$((TF_PASS_INDEX + 1))
  TF_CRASH_RETRIED=0
  TF_INT=""

  tf__logdir
  plan="$TF_STATE_DIR/$slug.tfplan"
  t0=$(date +%s)
  echo
  if [ -n "${DEPLOY_PASS_TOTAL:-}" ]; then
    echo "==> [$TF_PASS_INDEX/$DEPLOY_PASS_TOTAL] $name"
  else
    echo "==> $name"
  fi
  tf__plan_args "$@"

  while :; do
    suffix=""
    [ "$attempt" -gt 1 ] && suffix="-a$attempt"
    planlog="$DEPLOY_LOG_DIR/$slug$suffix.plan.log"
    jsonl="$DEPLOY_LOG_DIR/$slug$suffix.apply.jsonl"
    applylog="$DEPLOY_LOG_DIR/$slug$suffix.apply.log"

    # --- plan
    tf__say "    planning..."
    rc=0
    if [ "$mode" = verbose ]; then
      terraform plan -input=false -no-color -out="$plan" ${TF__PLAN_ARGS[@]+"${TF__PLAN_ARGS[@]}"} 2>&1 | tee "$planlog" || rc=$?
    else
      terraform plan -input=false -no-color -out="$plan" ${TF__PLAN_ARGS[@]+"${TF__PLAN_ARGS[@]}"} >"$planlog" 2>&1 || rc=$?
    fi
    [ "$rc" -eq 0 ] || tf__fail "$name: plan" "$rc" "$planlog"
    # Plan-time warnings (check blocks, deprecations) before the confirmation; -v already showed them.
    [ "$mode" = verbose ] || tf__plan_warnings "$planlog"

    showjson=$(mktemp "$TF_STATE_DIR/.plan-show.XXXXXX")
    if ! terraform show -json "$plan" >"$showjson" 2>>"$planlog"; then
      rm -f "$showjson"
      tf__fail "$name: show plan" 1 "$planlog"
    fi
    if [ -n "${TF_PLAN_HOOK:-}" ] && ! "$TF_PLAN_HOOK" "$showjson"; then
      rm -f "$showjson" "$plan"
      continue
    fi
    if [ "$(tf__plan_total "$showjson")" -eq 0 ]; then
      tf__say "    plan: no changes"
      rm -f "$showjson" "$plan"
      return 0
    fi
    totals=$(tf__plan_totals "$showjson")

    # Retries re-plan and ask again only when the new plan replaces or destroys something.
    if [ "$quiet" -eq 0 ] || [ "${DEPLOY_YES:-0}" != 1 ]; then
      tf__plan_report "$showjson"
    fi
    if [ "$attempt" -eq 1 ] || [ "$(tf__plan_destructive "$showjson")" -gt 0 ]; then
      if ! tf__confirm; then
        rm -f "$showjson" "$plan"
        tf__cleanup
        exit 1
      fi
    fi
    rm -f "$showjson"

    # --- apply the saved plan
    rc=0
    trap 'TF_INT=1' INT
    if [ "$mode" = verbose ]; then
      terraform apply -input=false -no-color "$plan" 2>&1 | tee -i "$applylog" || rc=$?
    else
      terraform apply -json -input=false "$plan" 2>&1 | tee -i "$jsonl" |
        (trap '' INT; exec jq -R -n -j --unbuffered --argjson tty "$tty" --argjson quiet "$quiet" \
          --argjson totals "$totals" "$TF_JQ_DEFS$TF_JQ_RENDER") || rc=$?
      [ "$tty" = 1 ] && printf '\r\033[K'
      tf__humanize "$jsonl" >"$applylog"
    fi
    trap - INT
    rm -f "$plan"

    if [ "$rc" -eq 0 ]; then
      tf__say "    done in $(($(date +%s) - t0))s"
      return 0
    fi
    [ -z "${TF_INT:-}" ] || tf__fail "$name: interrupted" "$rc" "$applylog"
    if tf__crash "$name" "$applylog"; then
      attempt=$((attempt + 1))
      continue
    fi
    if grep -q 'TERRAFORM CRASH' "$applylog"; then
      tf__fail "$name: apply" "$rc" "$applylog"
    fi
    if tf__retry_match "$applylog" "$attempt"; then
      attempt=$((attempt + 1))
      sleep "${TF_RETRY_SLEEP:-5}"
      continue
    fi
    tf__fail "$name: apply" "$rc" "$applylog"
  done
}
