#!/usr/bin/env bash
# Fake curl: logs args, reads the URL from the -K config on stdin, prints a manifest.
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
cat >"$FAKE_CURL_LOG.stdin"
echo "kind: Namespace"
