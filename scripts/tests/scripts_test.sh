#!/usr/bin/env bash
# Tests for scripts/{ssh,kubeconfig,build-logs}.sh with a fake terraform and ssh on PATH.
# Usage: scripts/tests/scripts_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(dirname "$T")"
W=$(mktemp -d "${TMPDIR:-/tmp}/scripts-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

mkdir "$W/bin" "$W/tmp" "$W/ex"
cp "$T/fake-terraform.sh" "$W/bin/terraform"
cp "$T/fake-ssh.sh" "$W/bin/ssh"
chmod +x "$W/bin/terraform" "$W/bin/ssh"
export PATH="$W/bin:$PATH"
export TMPDIR="$W/tmp"
export FAKE_TF_JSON="$T/sample-outputs.json"
export FAKE_SSH_LOG="$W/ssh.log"
export FAKE_SSH_CFGCOPY="$W/cfg.copy"
unset NODE_USERNAME

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }
reset() { : >"$FAKE_SSH_LOG"; rm -f "$FAKE_SSH_CFGCOPY"; }
noleftover() { [ -z "$(ls -A "$W/tmp")" ] || fail "temp dir not cleaned: $(ls "$W/tmp")"; }
count_kube() { local f n=0; for f in "$W"/kube.yaml*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

cd "$W/ex"

# --- ssh.sh --config
cfg=$("$S/ssh.sh" --config)
has "$cfg" "Host jumphost"
has "$cfg" "HostName 203.0.113.5"
has "$cfg" "User ec2-user"
has "$cfg" "Host t-cp-01"
has "$cfg" "HostName 10.0.2.21"
has "$cfg" "ProxyJump jumphost"
has "$cfg" "GlobalKnownHostsFile /dev/null"
has "$cfg" "StrictHostKeyChecking accept-new"
has "$cfg" "UpdateHostKeys no"
has "$cfg" "User suse"
# node without private_ip: public_ip, no ProxyJump
bm=$(awk "/^Host t-bm-01\$/{on=1;next} /^Host /{on=0} on" <<<"$cfg")
has "$bm" "HostName 198.51.100.7"
has "$bm" "User bmuser"
hasnt "$bm" "ProxyJump"
noleftover

cfg=$("$S/ssh.sh" -u admin --config)
has "$cfg" "User admin"
hasnt "$cfg" "User suse"
hasnt "$cfg" "User bmuser"
NODE_USERNAME=envuser "$S/ssh.sh" --config | grep -qF "User envuser" || fail "NODE_USERNAME ignored"

# --- ssh.sh session: config exists during ssh, known_hosts throwaway, cleaned after
reset
"$S/ssh.sh" t-cp-02 uptime
has "$(cat "$FAKE_SSH_LOG")" "t-cp-02 uptime"
has "$(cat "$FAKE_SSH_LOG")" "known_hosts_exists"
has "$(cat "$FAKE_SSH_CFGCOPY")" "UserKnownHostsFile \"$W/tmp/"
noleftover

reset
"$S/ssh.sh" jumphost true
has "$(cat "$FAKE_SSH_LOG")" "jumphost true"

# unknown host rejected before ssh runs
reset
rc=0
"$S/ssh.sh" nope 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "unknown host accepted"
[ ! -s "$FAKE_SSH_LOG" ] || fail "ssh ran for unknown host"
noleftover

# persistent known_hosts
kh="$W/kh"
"$S/ssh.sh" --known-hosts "$kh" --config | grep -qF "UserKnownHostsFile \"$kh\"" || fail "--known-hosts not used"
[ -f "$kh" ] || fail "persistent known_hosts not created"
noleftover

# unsafe output value refused
bad="$W/bad.json"
jq '.nodes.value["t-cp-01"].private_ip = "1.2.3.4\n  ProxyCommand evil"' "$FAKE_TF_JSON" >"$bad"
rc=0
FAKE_TF_JSON="$bad" "$S/ssh.sh" --config >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "unsafe value accepted"

# node without ssh_user: refused unless -u given
nou="$W/nou.json"
jq 'del(.nodes.value["t-cp-01"].ssh_user)' "$FAKE_TF_JSON" >"$nou"
rc=0
FAKE_TF_JSON="$nou" "$S/ssh.sh" --config >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "missing ssh_user accepted"
FAKE_TF_JSON="$nou" "$S/ssh.sh" -u admin --config >/dev/null || fail "-u did not override missing ssh_user"

# -C DIR
mkdir "$W/other"
(cd "$W/other" && "$S/ssh.sh" -C "$W/ex" --config >/dev/null) || fail "-C failed"

# --- kubeconfig.sh stdout
reset
kc=$("$S/kubeconfig.sh")
has "$kc" "server: https://rke2-203.0.113.10.sslip.io:6443"
hasnt "$kc" "127.0.0.1"
has "$kc" "certificate-authority-data: Q0E="
has "$(cat "$FAKE_SSH_LOG")" "t-cp-01 cat /etc/rancher/rke2/rke2.yaml"
has "$(cat "$FAKE_SSH_CFGCOPY")" "Host t-cp-01"
noleftover
[ ! -e "$W/ex/kubeconfig" ] || fail "kubeconfig written into cwd"

# -o creates mode 600 (even with a permissive caller umask)
out="$W/kube.yaml"
(umask 022 && "$S/kubeconfig.sh" -o "$out" 2>/dev/null)
has "$(cat "$out")" "server: https://rke2-203.0.113.10.sslip.io:6443"
mode=$(stat -c %a "$out" 2>/dev/null || stat -f %Lp "$out")
[ "$mode" = 600 ] || fail "mode $mode, want 600"
[ "$(count_kube)" -eq 1 ] || fail "stray temp file next to output"

# refuses overwrite; content unchanged
echo keep >"$out"
reset
rc=0
"$S/kubeconfig.sh" -o "$out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "overwrite without --force accepted"
[ "$(cat "$out")" = keep ] || fail "existing file modified"
[ ! -s "$FAKE_SSH_LOG" ] || fail "ssh ran before overwrite check"

# --force overwrites, keeps 600
"$S/kubeconfig.sh" -o "$out" --force 2>/dev/null
has "$(cat "$out")" "server: https://rke2-203.0.113.10.sslip.io:6443"
mode=$(stat -c %a "$out" 2>/dev/null || stat -f %Lp "$out")
[ "$mode" = 600 ] || fail "mode after --force $mode"

# ssh failure: nonzero, no output file created
rm -f "$out"
rc=0
FAKE_SSH_FAIL=1 "$S/kubeconfig.sh" -o "$out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "ssh failure not propagated"
[ ! -e "$out" ] || fail "file created on failure"
[ "$(count_kube)" -eq 0 ] || fail "temp file left on failure"

# no init node
noinit="$W/noinit.json"
jq '.nodes.value |= map_values(.init = false)' "$FAKE_TF_JSON" >"$noinit"
rc=0
FAKE_TF_JSON="$noinit" "$S/kubeconfig.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "missing init node accepted"

# --- build-logs.sh (default: every build host; jumphost address maps to jumphost)
reset
logs=$("$S/build-logs.sh" --no-follow 2>"$W/err")
has "$logs" "[jumphost] build line 1"
has "$logs" "[10.0.9.9] build line 1"
has "$(cat "$FAKE_SSH_LOG")" "jumphost tail -n +1 /var/log/elemental-factory.log"
has "$(cat "$FAKE_SSH_LOG")" "10.0.9.9 tail -n +1 /var/log/elemental-factory.log"
has "$(cat "$W/err")" "method=http"
has "$("$S/ssh.sh" --config)" "Host 10.0.9.9"
extra=$(awk "/^Host 10.0.9.9\$/{on=1;next} /^Host /{on=0} on" <<<"$("$S/ssh.sh" --config)")
has "$extra" "ProxyJump jumphost"
has "$extra" "User ec2-user"
# --host picks one; no prefix
reset
logs=$("$S/build-logs.sh" --host t-gpu-01 --no-follow 2>/dev/null)
has "$(cat "$FAKE_SSH_LOG")" "t-gpu-01 tail -n +1 /var/log/elemental-factory.log"
hasnt "$logs" "[t-gpu-01]"
reset
"$S/build-logs.sh" --host jumphost >/dev/null 2>&1
has "$(cat "$FAKE_SSH_LOG")" "jumphost tail -n +1 -F "
rc=0
"$S/build-logs.sh" --host nope >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "unknown --host accepted"

# build_status null: no ssh
nobuild="$W/nobuild.json"
jq '.build_status.value = null' "$FAKE_TF_JSON" >"$nobuild"
reset
FAKE_TF_JSON="$nobuild" "$S/build-logs.sh" >/dev/null 2>"$W/err"
has "$(cat "$W/err")" "no build running"
[ ! -s "$FAKE_SSH_LOG" ] || fail "ssh ran with null build_status"
noleftover

# --- state fallback (terraform_data.build_access) while the apply runs
export FAKE_TF_STATE="$T/sample-state.json"
# outputs written before the jumphost existed: jumphost, image and build_status missing
partial="$W/partial.json"
jq 'del(.jumphost, .build_status, .nodes)' "$FAKE_TF_JSON" >"$partial"
reset
FAKE_TF_JSON="$partial" "$S/build-logs.sh" --no-follow >/dev/null 2>"$W/err"
has "$(cat "$W/err")" "terraform_data.build_access"
has "$(cat "$W/err")" "method=s3"
has "$(cat "$FAKE_SSH_LOG")" "jumphost tail -n +1 /var/log/elemental-factory.log"
has "$(FAKE_TF_JSON="$partial" "$S/ssh.sh" --config 2>/dev/null)" "HostName 203.0.113.50"
# outputs from the previous build (--rebuild): state wins
stale="$W/stale.json"
jq '.build_status.value = null | .image = {value: {build_id: "old999"}}' "$FAKE_TF_JSON" >"$stale"
reset
FAKE_TF_JSON="$stale" "$S/build-logs.sh" --no-follow >/dev/null 2>"$W/err"
has "$(cat "$W/err")" "method=s3"
has "$(cat "$FAKE_SSH_LOG")" "jumphost tail"
# outputs current and build done: no fallback
done_json="$W/done.json"
jq '.build_status.value = null | .image = {value: {build_id: "new123"}}' "$FAKE_TF_JSON" >"$done_json"
reset
FAKE_TF_JSON="$done_json" "$S/build-logs.sh" >/dev/null 2>"$W/err"
has "$(cat "$W/err")" "no build running"
hasnt "$(cat "$W/err")" "build_access"
[ ! -s "$FAKE_SSH_LOG" ] || fail "ssh ran after the build finished"
# no state available: same message as before
reset
FAKE_TF_STATE="" FAKE_TF_JSON="$nobuild" "$S/build-logs.sh" >/dev/null 2>"$W/err"
has "$(cat "$W/err")" "no build running"
unset FAKE_TF_STATE

# --- build-logs.sh --host <raw IPv4>: behind the jumphost, even with build_status null
reset
FAKE_TF_JSON="$nobuild" "$S/build-logs.sh" --host 10.0.7.7 --no-follow >/dev/null 2>&1
has "$(cat "$FAKE_SSH_LOG")" "10.0.7.7 tail -n +1 /var/log/elemental-factory.log"
reset
"$S/build-logs.sh" --host 10.0.0.5 --no-follow >/dev/null 2>&1
has "$(cat "$FAKE_SSH_LOG")" "jumphost tail"
noleftover

echo ok
