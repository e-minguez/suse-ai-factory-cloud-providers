#!/usr/bin/env bash
# Fake terraform for script tests: `output -json` prints $FAKE_TF_JSON (a file),
# `show -json` prints $FAKE_TF_STATE (a file) or fails when it is unset.
if [ "${1:-}" = output ] && [ "${2:-}" = -json ]; then
  cat "$FAKE_TF_JSON"
  exit 0
fi
if [ "${1:-}" = show ] && [ "${2:-}" = -json ] && [ -n "${FAKE_TF_STATE:-}" ]; then
  cat "$FAKE_TF_STATE"
  exit 0
fi
echo "fake terraform: unsupported: $*" >&2
exit 1
