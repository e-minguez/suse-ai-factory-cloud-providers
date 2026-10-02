#!/usr/bin/env bash
# Fake ssh: logs the command; `get deployment` succeeds only with FAKE_AGENT=1;
# `apply -f -` stores stdin in $FAKE_SSH_STDIN.
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
case "$*" in
  *"get deployment"*) [ "${FAKE_AGENT:-}" = 1 ] ;;
  *"apply -f -"*) cat >>"$FAKE_SSH_STDIN" ;;
esac
