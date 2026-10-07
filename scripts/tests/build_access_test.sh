#!/usr/bin/env bash
# build-logs.sh and ssh.sh read terraform_data.build_access from state during the
# apply, per provider (vultr, evroc, exoscale), with a fake terraform and ssh on PATH.
# Usage: scripts/tests/build_access_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(dirname "$T")"
W=$(mktemp -d "${TMPDIR:-/tmp}/build-access-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/ex"
cp "$T/fake-terraform.sh" "$W/bin/terraform"
cp "$T/fake-ssh.sh" "$W/bin/ssh"
chmod +x "$W/bin/terraform" "$W/bin/ssh"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_SSH_LOG="$W/ssh.log"
export FAKE_SSH_CFGCOPY="$W/cfg.copy"
unset NODE_USERNAME

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }
reset() { : >"$FAKE_SSH_LOG"; rm -f "$FAKE_SSH_CFGCOPY"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }

cd "$W/ex"

# check <provider> <build_id> <jumphost public ip> <method> <extra build host or "">
check() {
  local p=$1 id=$2 pub=$3 method=$4 extra=$5 out
  export FAKE_TF_STATE="$T/sample-state-$p.json"

  # Outputs written before the jumphost existed: only unrelated entries.
  out="$W/$p-partial.json"
  echo '{"provider": {"value": "'"$p"'", "type": "string", "sensitive": false}}' >"$out"
  reset
  FAKE_TF_JSON="$out" "$S/build-logs.sh" --no-follow >/dev/null 2>"$W/err"
  has "$(cat "$W/err")" "terraform_data.build_access"
  has "$(cat "$W/err")" "method=$method"
  has "$(cat "$FAKE_SSH_LOG")" "jumphost tail -n +1 /var/log/elemental-factory.log"
  if [ -n "$extra" ]; then
    has "$(cat "$FAKE_SSH_LOG")" "$extra tail -n +1 /var/log/elemental-factory.log"
    has "$(cat "$FAKE_SSH_CFGCOPY")" "HostName $extra"
    has "$(cat "$FAKE_SSH_CFGCOPY")" "ProxyJump jumphost"
  fi
  has "$(FAKE_TF_JSON="$out" "$S/ssh.sh" --config 2>/dev/null)" "HostName $pub"
  noleftover

  # Outputs of the previous build (--rebuild): state wins, build_status included.
  out="$W/$p-stale.json"
  jq -n --arg p "$pub" '{
    jumphost: {value: {public_ip: "198.51.100.99", private_ip: "10.9.9.9", ssh_user: "old"}},
    image: {value: {build_id: "old999"}},
    build_status: {value: null}}' >"$out"
  reset
  FAKE_TF_JSON="$out" "$S/build-logs.sh" --no-follow >/dev/null 2>"$W/err"
  has "$(cat "$W/err")" "method=$method"
  has "$(cat "$FAKE_SSH_CFGCOPY")" "HostName $pub"
  hasnt "$(cat "$FAKE_SSH_CFGCOPY")" "198.51.100.99"

  # Outputs current and build done: no fallback, no ssh.
  out="$W/$p-done.json"
  jq -n --arg id "$id" --arg pub "$pub" '{
    jumphost: {value: {public_ip: $pub, private_ip: "10.0.0.1", ssh_user: "root"}},
    image: {value: {build_id: $id}},
    build_status: {value: null}}' >"$out"
  reset
  FAKE_TF_JSON="$out" "$S/build-logs.sh" >/dev/null 2>"$W/err"
  has "$(cat "$W/err")" "no build running"
  hasnt "$(cat "$W/err")" "build_access"
  [ ! -s "$FAKE_SSH_LOG" ] || fail "$p: ssh ran after the build finished"

  # --host <IPv4> through the jumphost with outputs missing.
  out="$W/$p-partial.json"
  reset
  FAKE_TF_JSON="$out" "$S/build-logs.sh" --no-follow --host 10.0.7.7 >/dev/null 2>&1
  has "$(cat "$FAKE_SSH_LOG")" "10.0.7.7 tail"
  has "$(cat "$FAKE_SSH_CFGCOPY")" "ProxyJump jumphost"
  noleftover
  unset FAKE_TF_STATE
}

check vultr vul123 203.0.113.60 http ""
check evroc evr123 203.0.113.70 relay 10.30.1.71
check exoscale exo123 203.0.113.80 http ""

echo "build_access_test: ok"
