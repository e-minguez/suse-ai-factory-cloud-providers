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
