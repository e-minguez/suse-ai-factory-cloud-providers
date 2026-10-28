#!/usr/bin/env bash
# Sourced by the fake curl of the exoscale script tests: exo_sig_ok <url> <authorization>
# recomputes the EXO2-HMAC-SHA256 signature as the API does ("GET path",
# body, values of signed-query-args, header values, expiry) with FAKE_SECRET
# and returns 1 on a mismatch, so a wrong signed path fails like a real 403.

exo_sig_ok() {
  local url=$1 auth=$2 rest rpath query names expires sig values="" n kv want
  rest=${url#https://api-*.exoscale.com}
  rpath=${rest%%\?*}
  query=""
  [ "$rpath" = "$rest" ] || query=${rest#*\?}
  names=$(sed -n 's/.*signed-query-args=\([^,]*\),.*/\1/p' <<<"$auth")
  expires=$(sed -n 's/.*expires=\([0-9]*\),.*/\1/p' <<<"$auth")
  sig=$(sed -n 's/.*signature=\([^",]*\).*/\1/p' <<<"$auth")
  [ -n "$expires" ] && [ -n "$sig" ] || return 1
  for n in ${names//;/ }; do
    kv=$(tr '&' '\n' <<<"$query" | grep "^$n=" | head -n 1)
    values="$values${kv#*=}"
  done
  want=$(printf 'GET %s\n\n%s\n\n%s' "$rpath" "$values" "$expires" |
    openssl dgst -sha256 -hmac "$FAKE_SECRET" -binary | openssl base64 -A)
  [ "$sig" = "$want" ]
}
