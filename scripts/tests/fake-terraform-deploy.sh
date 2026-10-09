#!/usr/bin/env bash
# Fake terraform for deploy tests. Env: FAKE_TF_DIR (fixtures), FAKE_TF_STATE (scratch dir),
# FAKE_TF_PLAN (plan fixture name), FAKE_TF_PLAN_SEQ ("a.json b.json" consumed one per `show`,
# the last repeats), FAKE_TF_PLAN_FAIL,
# FAKE_TF_PLAN_WARN, FAKE_TF_IMAGE (JSON answered for `output -json image`), FAKE_TF_APPLY_SEQ ("fixture:rc ..." consumed one per apply call), FAKE_TF_NEXT_STEPS,
# FAKE_TF_STATE_LIST (lines answered for `state list`), FAKE_TF_STATE_LIST_FILE (same, from a file,
# written line by line, so an early-exiting reader gets SIGPIPE as with real terraform).
echo "$*" >>"$FAKE_TF_STATE/calls.log"
cmd=${1:-}
shift || true
case "$cmd" in
  init) echo "Terraform has been successfully initialized!" ;;
  state)
    [ "${1:-}" = list ] || exit 1
    [ -z "${FAKE_TF_STATE_LIST:-}" ] || printf "%s\n" "$FAKE_TF_STATE_LIST"
    if [ -n "${FAKE_TF_STATE_LIST_FILE:-}" ]; then
      while IFS= read -r l; do echo "$l"; done <"$FAKE_TF_STATE_LIST_FILE"
    fi
    ;;
  plan)
    if [ -n "${FAKE_TF_PLAN_FAIL:-}" ]; then
      echo "Error: bad variable" >&2
      exit 1
    fi
    for a in "$@"; do
      case "$a" in -out=*) echo fakeplan >"${a#-out=}" ;; esac
    done
    echo "Plan: fake."
    [ -z "${FAKE_TF_PLAN_WARN:-}" ] || printf '\nWarning: Check block assertion failed\n\nquota low\n\n─────\n\nSaved the plan\n'
    ;;
  show)
    [ "${1:-}" = -json ] || exit 1
    plan=${FAKE_TF_PLAN:-plan.json}
    if [ -n "${FAKE_TF_PLAN_SEQ:-}" ]; then
      s=$(($(cat "$FAKE_TF_STATE/show_n" 2>/dev/null || echo 0) + 1))
      echo "$s" >"$FAKE_TF_STATE/show_n"
      read -ra pseq <<<"$FAKE_TF_PLAN_SEQ"
      plan=${pseq[$((s - 1))]:-${pseq[$((${#pseq[@]} - 1))]}}
    fi
    cat "$FAKE_TF_DIR/$plan"
    ;;
  apply)
    json=0
    for a in "$@"; do [ "$a" = -json ] && json=1; done
    for last; do :; done
    [ -f "$last" ] || { echo "no saved plan: $last" >&2; exit 1; }
    n=$(($(cat "$FAKE_TF_STATE/n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_TF_STATE/n"
    read -ra seq <<<"${FAKE_TF_APPLY_SEQ:-apply-ok.jsonl:0}"
    ent=${seq[$((n - 1))]:-${seq[$((${#seq[@]} - 1))]}}
    fx=${ent%%:*}
    rc=${ent##*:}
    if [ "$json" = 1 ]; then
      cat "$FAKE_TF_DIR/$fx"
    else
      jq -R -r '(fromjson? | select(type == "object") | .["@message"]) // .' "$FAKE_TF_DIR/$fx"
    fi
    exit "$rc"
    ;;
  output)
    if [ "${1:-}" = -json ] && [ "${2:-}" = image ]; then
      [ -n "${FAKE_TF_IMAGE:-}" ] || exit 1
      printf '%s\n' "$FAKE_TF_IMAGE"
      exit 0
    fi
    if [ "${1:-}" = -json ] && [ "${2:-}" = provider_details ]; then
      default='{"control_plane_ids":["i-1","i-2"],"agent_node_cidrs":["10.0.0.5/32"],"nat_gateway_public_cidrs":["203.0.113.7/32"]}'
      printf '%s\n' "${FAKE_TF_PROVIDER_DETAILS:-$default}"
      exit 0
    fi
    [ "${1:-}" = -raw ] && [ "${2:-}" = next_steps ] || exit 1
    printf '%s\n' "${FAKE_TF_NEXT_STEPS:-Kubernetes API : https://example:6443}"
    ;;
  *) echo "fake terraform: unsupported: $cmd $*" >&2; exit 1 ;;
esac
