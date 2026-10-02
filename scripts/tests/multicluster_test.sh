#!/usr/bin/env bash
# Tests for tools/multicluster/cluster.sh in a throwaway repo tree with fake terraform, ssh and curl.
# Usage: scripts/tests/multicluster_test.sh
set -euo pipefail

T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$T/../.." && pwd)"
FX="$T/fixtures/multicluster"
W=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/multicluster-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$W"' EXIT

# Fake repo: same relative layout as the real one.
R="$W/repo"
mkdir -p "$R/tools/multicluster/register" "$R/tools/cost" "$R/scripts/lib" "$R/modules" "$W/bin" "$W/out"
cp "$REPO/tools/multicluster/cluster.sh" "$R/tools/multicluster/"
cp "$REPO/scripts/lib/ssh.sh" "$R/scripts/lib/"
for p in aws vultr evroc; do
  mkdir -p "$R/examples/$p"
  for f in main.tf variables.tf outputs.tf versions.tf; do echo "# $p" >"$R/examples/$p/$f"; done
  printf 'secret_key = "REPLACE"\n' >"$R/examples/$p/terraform.tfvars.example"
  cat >"$R/examples/$p/deploy.sh" <<'D'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$FAKE_DEPLOY_LOG"
D
  chmod +x "$R/examples/$p/deploy.sh"
done
# examples/broken lacks deploy.sh
mkdir "$R/examples/broken" && : >"$R/examples/broken/main.tf"

cp "$FX/fake-terraform.sh" "$W/bin/terraform"
cp "$FX/fake-ssh.sh" "$W/bin/ssh"
cp "$FX/fake-curl.sh" "$W/bin/curl"
cat >"$W/bin/go" <<'G'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$FAKE_GO_LOG"
G
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH"
export TMPDIR="$W"
export FAKE_OUT="$W/out" FAKE_TF_LOG="$W/tf.log" FAKE_SSH_LOG="$W/ssh.log" FAKE_SSH_STDIN="$W/ssh.stdin"
export FAKE_CURL_LOG="$W/curl.log" FAKE_DEPLOY_LOG="$W/deploy.log" FAKE_GO_LOG="$W/go.log" FAKE_REG_OUT="$W/reg.json"
unset RANCHER_TOKEN_KEY FAKE_AGENT FAKE_INGRESS FAKE_CONSOLE_FAIL FAKE_APPLY_FAIL
: >"$FAKE_TF_LOG" && : >"$FAKE_SSH_LOG" && : >"$FAKE_CURL_LOG" && : >"$FAKE_DEPLOY_LOG"
cp "$FX"/*.json "$W/out/"
cat >"$FAKE_REG_OUT" <<'J'
{"registrations": {"gpu-a": "https://rancher.example/v3/import/tokA.yaml", "gpu-b": "https://rancher.example/v3/import/tokB.yaml", "gpu-c": "https://rancher.example/v3/import/tokC.yaml"},
 "rancher_insecure": true}
J

CS="$R/tools/multicluster/cluster.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" <<<"$1" || fail "missing '$2' in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2' in: $1"; }
fhas() { grep -qF -- "$2" "$1" || fail "missing '$2' in $1: $(cat "$1")"; }
fhasnt() { ! grep -qF -- "$2" "$1" || fail "unexpected '$2' in $1"; }
reset() { : >"$FAKE_TF_LOG"; : >"$FAKE_SSH_LOG"; : >"$FAKE_CURL_LOG"; rm -f "$FAKE_SSH_STDIN" "$FAKE_TF_LOG".*; }
# Runs cluster.sh; sets rc and out (stdout+stderr).
run() { rc=0; out=$("$CS" "$@" 2>&1) || rc=$?; }
expect_fail() { run "$@"; [ "$rc" -ne 0 ] || fail "expected failure: $*"; }

# --- new
run new aws mgmt
[ "$rc" -eq 0 ] || fail "new failed: $out"
for f in main.tf variables.tf outputs.tf versions.tf deploy.sh; do
  [ -L "$R/clusters/mgmt/$f" ] || fail "$f is not a symlink"
  [ "$(readlink "$R/clusters/mgmt/$f")" = "../../examples/aws/$f" ] || fail "$f target: $(readlink "$R/clusters/mgmt/$f")"
  [ -e "$R/clusters/mgmt/$f" ] || fail "$f dangling"
done
[ "$(cat "$R/clusters/mgmt/.provider")" = aws ] || fail ".provider"
# Same depth as examples/<p>: ../../modules resolves from the cluster dir.
[ -d "$R/clusters/mgmt/../../modules" ] || fail "../../modules does not resolve from clusters/mgmt"
[ -n "$(find "$R/clusters/mgmt/terraform.tfvars" -perm 600)" ] || fail "tfvars mode"
cmp -s "$R/clusters/mgmt/terraform.tfvars" "$R/examples/aws/terraform.tfvars.example" || fail "tfvars is not the example"
echo 'secret_key = "real"' >"$R/clusters/mgmt/terraform.tfvars"

expect_fail new aws mgmt
has "$out" "refusing to overwrite"
fhas "$R/clusters/mgmt/terraform.tfvars" real
expect_fail new nosuch x1
has "$out" "unknown provider"
expect_fail new aws Bad_Name
expect_fail new aws .register
expect_fail new broken x2
has "$out" "is missing"
[ ! -e "$R/clusters/x2" ] || fail "partial cluster left behind"
expect_fail new aws

run new vultr gpu-a && run new evroc gpu-b && run new vultr gpu-c
[ "$rc" -eq 0 ] || fail "new failed: $out"

# --- deploy / destroy
run deploy gpu-a --rebuild --yes -- -var=x=1
[ "$rc" -eq 0 ] || fail "deploy failed: $out"
fhas "$FAKE_DEPLOY_LOG" "$R/clusters/gpu-a|--rebuild --yes -- -var=x=1"
fhasnt "$FAKE_DEPLOY_LOG" "common-all"
run destroy gpu-a --yes
fhas "$FAKE_DEPLOY_LOG" "$R/clusters/gpu-a|--destroy --yes"
expect_fail deploy nosuch
has "$out" "no such cluster"
expect_fail deploy ../etc
expect_fail deploy

# --- list
echo '{"resources": [{"a": 1}]}' >"$R/clusters/mgmt/terraform.tfstate"
echo '{"resources": []}' >"$R/clusters/gpu-b/terraform.tfstate"
mkdir -p "$R/clusters/.register/mgmt"
run list
has "$out" "mgmt"
has "$out" "deployed (1 resources)"
has "$out" "state empty"
has "$out" "no state"
hasnt "$out" ".register"
hasnt "$out" "real"

# --- register: argument and precondition errors
expect_fail register mgmt
expect_fail register mgmt mgmt
has "$out" "management cluster"
expect_fail register mgmt nosuch
expect_fail register mgmt gpu-a
has "$out" "no Rancher API token"
rm -f "$R/clusters/gpu-a/terraform.tfstate"

# --- register: token from the environment; egress ip missing from ingress_cidrs
export RANCHER_TOKEN_KEY=token-x:secret
reset
FAKE_INGRESS='"[\"203.0.113.0/24\"]"' expect_fail register --yes mgmt gpu-a
has "$out" "198.51.100.4 is not in the management ingress_cidrs"
[ ! -s "$FAKE_TF_LOG.vars" ] 2>/dev/null || fail "apply ran despite failed CIDR check"
fhasnt "$FAKE_TF_LOG" "apply"

# ...covered by a CIDR, and empty egress_ips only warns
reset
FAKE_INGRESS='"[\"198.51.100.0/24\",\"192.0.2.9/32\"]"' run register --yes mgmt gpu-a gpu-b gpu-c
[ "$rc" -eq 0 ] || fail "register failed: $out"
has "$out" "gpu-a egress: 198.51.100.4"
has "$out" "gpu-b reports no egress_ips"
fhas "$FAKE_TF_LOG" "init -input=false -reconfigure -backend-config=path=$R/clusters/.register/mgmt/terraform.tfstate"
fhas "$FAKE_TF_LOG" "-auto-approve"
fhas "$FAKE_TF_LOG" "data=$R/clusters/.register/mgmt/.terraform"
# ...and only there: the cluster directories keep their own .terraform.
grep -q "output -json | cwd=gpu-a | data=$" "$FAKE_TF_LOG" || fail "no terraform output in gpu-a"
! grep -q "cwd=gpu-. | data=." "$FAKE_TF_LOG" || fail "TF_DATA_DIR leaked into a cluster directory"
# Terraform got names only, no secrets, via the environment.
ds=$(cat "$FAKE_TF_LOG.downstream")
[ "$(jq -r '."gpu-a".cluster_name + "/" + ."gpu-a".provider + "/" + (."gpu-a".egress_ips | join(","))' <<<"$ds")" = "gpu-a/vultr/198.51.100.4" ] || fail "downstream var: $ds"
[ "$(jq -r '."gpu-b".provider' <<<"$ds")" = evroc ] || fail "downstream var: $ds"
[ "$(cut -d'|' -f1,2 "$FAKE_TF_LOG.vars")" = "|" ] || fail "bootstrap vars set without --bootstrap"
fhas "$FAKE_TF_LOG.vars" '"rancher_url":"https://rancher.example"'
fhasnt "$FAKE_TF_LOG.vars" boot-pass
# Registration ran over ssh on the init node, manifest piped on stdin, URL kept out of argv.
fhas "$FAKE_SSH_LOG" "gpu-a-cp-01 KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl apply -f -"
fhasnt "$FAKE_SSH_LOG" "gpu-a-cp-02 KUBECONFIG"
fhasnt "$FAKE_SSH_LOG" "tokA"
fhasnt "$FAKE_CURL_LOG" "tokA"
fhas "$FAKE_CURL_LOG" "-K -"
fhas "$FAKE_CURL_LOG" "-k"
fhas "$FAKE_CURL_LOG.stdin" "tokC.yaml"
[ "$(grep -c 'kind: Namespace' "$FAKE_SSH_STDIN")" -eq 3 ] || fail "manifest not applied for all three clusters"
[ "$(sort "$R/clusters/.register/mgmt/downstream.list" | tr '\n' ' ')" = "gpu-a gpu-b gpu-c " ] || fail "downstream.list"
fhasnt "$FAKE_SSH_LOG" "rke2.yaml -"

# Second run with one cluster keeps the earlier ones (plain accumulating state).
reset
run register --yes mgmt gpu-a
[ "$rc" -eq 0 ] || fail "re-register failed: $out"
ds=$(cat "$FAKE_TF_LOG.downstream")
[ "$(jq -r 'keys | join(",")' <<<"$ds")" = "gpu-a,gpu-b,gpu-c" ] || fail "state did not accumulate: $ds"

# Agent already installed: no apply over ssh.
reset
FAKE_AGENT=1 run register --yes mgmt gpu-a
[ "$rc" -eq 0 ] || fail "register failed: $out"
has "$out" "agent already installed"
[ ! -e "$FAKE_SSH_STDIN" ] || fail "manifest applied although the agent exists"

# Unreadable ingress_cidrs: warning only.
reset
FAKE_CONSOLE_FAIL=1 run register --yes mgmt gpu-a
[ "$rc" -eq 0 ] || fail "register failed: $out"
has "$out" "cannot read the management ingress_cidrs"

# --skip-cidr-check downgrades the failure.
reset
FAKE_INGRESS='"[\"203.0.113.0/24\"]"' run register --yes --skip-cidr-check mgmt gpu-a
[ "$rc" -eq 0 ] || fail "skip-cidr-check failed: $out"

# terraform apply failure stops before ssh.
reset
FAKE_APPLY_FAIL=1 expect_fail register --yes mgmt gpu-a
[ ! -s "$FAKE_SSH_LOG" ] || fail "ssh ran after failed apply"

# --- register: bootstrap passes the password by environment and is remembered
unset RANCHER_TOKEN_KEY
rm -rf "$R/clusters/.register"
reset
run register --yes --bootstrap mgmt gpu-a
[ "$rc" -eq 0 ] || fail "bootstrap register failed: $out"
[ "$(cut -d'|' -f1,2 "$FAKE_TF_LOG.vars")" = "true|boot-pass" ] || fail "bootstrap vars: $(cat "$FAKE_TF_LOG.vars")"
hasnt "$out" boot-pass
reset
run register --yes mgmt gpu-b
[ "$rc" -eq 0 ] || fail "second register failed: $out"
[ "$(cut -d'|' -f1 "$FAKE_TF_LOG.vars")" = true ] || fail "bootstrap not remembered"

# --- register: rancher_token in common-register.tfvars is accepted
rm -rf "$R/clusters/.register"
printf 'rancher_token = "t:s"\n' >"$R/clusters/common-register.tfvars"
reset
run register --yes mgmt gpu-a
[ "$rc" -eq 0 ] || fail "register with tfvars token failed: $out"
fhas "$FAKE_TF_LOG" "-var-file=$R/clusters/common-register.tfvars"

# --- register: management cluster without Rancher
jq '.rancher_url.value = null' "$FX/mgmt.json" >"$W/out/mgmt.json"
expect_fail register --yes mgmt gpu-a
has "$out" "no rancher_url"

# --- cost: provider and var files in deploy.sh order
: >"$FAKE_GO_LOG"
printf 'x = 1\n' >"$R/clusters/common-all.tfvars"
printf 'x = 2\n' >"$R/clusters/common-vultr.tfvars"
run cost gpu-a --json --durations 1h
[ "$rc" -eq 0 ] || fail "cost failed: $out"
fhas "$FAKE_GO_LOG" "$R/tools/cost|run . --provider vultr --var-file $R/clusters/common-all.tfvars --var-file $R/clusters/common-vultr.tfvars --var-file $R/clusters/gpu-a/terraform.tfvars --json --durations 1h"
: >"$FAKE_GO_LOG"
run cost gpu-b
fhas "$FAKE_GO_LOG" "--provider evroc --var-file $R/clusters/common-all.tfvars --var-file $R/clusters/gpu-b/terraform.tfvars"
fhasnt "$FAKE_GO_LOG" "common-vultr"
expect_fail cost nosuch
has "$out" "no such cluster"
expect_fail cost

echo "multicluster_test: ok"
