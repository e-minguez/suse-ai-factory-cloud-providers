#!/usr/bin/env bash
# Fake ssh: logs args, snapshots the -F config (the real one is deleted on
# exit), and serves a sample rke2.yaml or log text.
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
if [ "${1:-}" = -F ]; then
  cp "$2" "$FAKE_SSH_CFGCOPY"
  [ -e "$(grep -m1 '^  UserKnownHostsFile' "$2" | sed 's/.*"\(.*\)"/\1/')" ] && echo known_hosts_exists >>"$FAKE_SSH_LOG"
fi
case "$*" in
  *rke2.yaml*)
    [ -z "${FAKE_SSH_FAIL:-}" ] || exit 255
    # FAKE_SSH_FAIL_TIMES=N: refuse the first N reads (node still booting).
    if [ -n "${FAKE_SSH_FAIL_TIMES:-}" ]; then
      n=$(($(cat "$FAKE_SSH_FAIL_COUNT" 2>/dev/null || echo 0) + 1))
      echo "$n" >"$FAKE_SSH_FAIL_COUNT"
      [ "$n" -gt "$FAKE_SSH_FAIL_TIMES" ] || { echo "channel 0: open failed: connect failed: Connection refused" >&2; exit 255; }
    fi
    cat <<'Y'
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: Q0E=
    server: https://127.0.0.1:6443
  name: default
Y
    ;;
  *elemental-factory.log*) echo "build line 1" ;;
esac
