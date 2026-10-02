#!/usr/bin/env bash
# Fake terraform for multicluster_test.sh. Cluster outputs come from
# $FAKE_OUT/<dir name>.json; the register root serves $FAKE_REG_OUT (JSON object of values).
# Every call is appended to $FAKE_TF_LOG together with the TF_* environment names.
[ "${1:-}" != "${1#-chdir=}" ] && { cd "${1#-chdir=}" || exit 1; shift; }
printf '%s | cwd=%s | data=%s\n' "$*" "$(basename "$PWD")" "${TF_DATA_DIR:-}" >>"$FAKE_TF_LOG"
case "${1:-}" in
  init) exit 0 ;;
  apply)
    printf '%s\n' "${TF_VAR_downstream:-}" >"$FAKE_TF_LOG.downstream"
    printf '%s|%s|%s\n' "${TF_VAR_bootstrap:-}" "${TF_VAR_bootstrap_password:-}" "${TF_VAR_mgmt:-}" >"$FAKE_TF_LOG.vars"
    [ -z "${FAKE_APPLY_FAIL:-}" ] || exit 1
    exit 0
    ;;
  console)
    cat >/dev/null
    [ -z "${FAKE_CONSOLE_FAIL:-}" ] || exit 1
    printf '%s\n' "${FAKE_INGRESS:-\"[\\\"0.0.0.0/0\\\"]\"}"
    exit 0
    ;;
  output)
    if [ "$(basename "$PWD")" = register ]; then
      jq -c ".[\"$3\"]" "$FAKE_REG_OUT"
    else
      f="$FAKE_OUT/$(basename "$PWD").json"
      [ -f "$f" ] || { echo "no outputs" >&2; exit 1; }
      cat "$f"
    fi
    exit 0
    ;;
esac
echo "fake terraform: unsupported: $*" >&2
exit 1
