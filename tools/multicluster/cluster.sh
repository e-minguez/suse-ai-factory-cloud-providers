#!/usr/bin/env bash
# Manage several clusters from one checkout, and import them into a Rancher.
#
# Usage: cluster.sh new <provider> <name>
#        cluster.sh deploy <name> [deploy.sh args]
#        cluster.sh destroy <name> [deploy.sh args]
#        cluster.sh register [--bootstrap] [--skip-cidr-check] [--yes] <mgmt> <downstream...>
#        cluster.sh list
#        cluster.sh cost <name> [cost args]
#
# Working area: clusters/ at the repo root (gitignored). See README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTERS="$ROOT/clusters"
REGISTER_ROOT="$HERE/register"
# Files every example provides; clusters/<name> links to each.
LINKED_FILES="main.tf variables.tf outputs.tf versions.tf deploy.sh"
LINKED_SCRIPTS="kubeconfig.sh ssh.sh build-logs.sh"

die() {
  echo "error: $*" >&2
  exit 1
}
warn() { echo "warning: $*" >&2; }
say() { echo "$*" >&2; }

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

valid_name() {
  case "$1" in
    "" | [!a-z]* | *[!a-z0-9-]*) return 1 ;;
  esac
  [ ${#1} -le 63 ]
}

cluster_dir() { # name -> path, dies if missing
  valid_name "$1" || die "invalid cluster name '$1' (lowercase letters, digits, dashes; start with a letter)"
  [ -d "$CLUSTERS/$1" ] || die "no such cluster: $1 (see: cluster.sh list)"
  echo "$CLUSTERS/$1"
}

cmd_new() {
  [ $# -eq 2 ] || die "usage: cluster.sh new <provider> <name>"
  local provider=$1 name=$2 ex f dir
  valid_name "$provider" || die "invalid provider '$provider'"
  valid_name "$name" || die "invalid cluster name '$name' (lowercase letters, digits, dashes; start with a letter)"
  ex="$ROOT/examples/$provider"
  [ -d "$ex" ] || die "unknown provider '$provider': no examples/$provider"
  for f in $LINKED_FILES; do
    [ -f "$ex/$f" ] || die "examples/$provider/$f is missing"
  done
  dir="$CLUSTERS/$name"
  { [ -e "$dir" ] || [ -L "$dir" ]; } && die "clusters/$name already exists; refusing to overwrite"

  mkdir -p "$CLUSTERS"
  # Same depth as examples/<provider>, so the relative module sources resolve.
  mkdir "$dir"
  for f in $LINKED_FILES; do
    ln -s "../../examples/$provider/$f" "$dir/$f"
  done
  for f in $LINKED_SCRIPTS; do
    ln -s "../../scripts/$f" "$dir/$f"
  done
  printf '%s\n' "$provider" >"$dir/.provider"
  if [ -f "$ex/terraform.tfvars.example" ]; then
    (umask 077 && cp "$ex/terraform.tfvars.example" "$dir/terraform.tfvars")
    chmod 600 "$dir/terraform.tfvars"
  fi

  say "created clusters/$name ($provider)"
  say "next: edit clusters/$name/terraform.tfvars (per-cluster values only)"
  say "      shared values: clusters/common-all.tfvars (see common-all.tfvars.example), clusters/common-$provider.tfvars"
  say "      cluster.sh deploy $name"
}

cmd_deploy() {
  [ $# -ge 1 ] || die "usage: cluster.sh deploy <name> [deploy.sh args]"
  local dir
  dir=$(cluster_dir "$1")
  shift
  [ -e "$dir/deploy.sh" ] || die "$dir/deploy.sh is missing"
  # deploy.sh layers ../common-all.tfvars, ../common-<provider>.tfvars and terraform.tfvars itself.
  cd "$dir"
  exec ./deploy.sh "$@"
}

cmd_destroy() {
  [ $# -ge 1 ] || die "usage: cluster.sh destroy <name> [deploy.sh args]"
  local name=$1
  shift
  cmd_deploy "$name" --destroy "$@"
}

cmd_list() {
  local d name provider state n
  printf '%-24s %-10s %s\n' NAME PROVIDER STATE
  for d in "$CLUSTERS"/*/; do
    [ -f "${d}.provider" ] || continue
    name=$(basename "$d")
    provider=$(cat "${d}.provider")
    state="no state"
    if [ -s "${d}terraform.tfstate" ]; then
      state="state present"
      if command -v jq >/dev/null 2>&1; then
        n=$(jq '.resources | length' "${d}terraform.tfstate" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] 2>/dev/null && state="deployed ($n resources)" || state="state empty"
      fi
    fi
    printf '%-24s %-10s %s\n' "$name" "$provider" "$state"
  done
}

cmd_cost() {
  [ $# -ge 1 ] || die "usage: cluster.sh cost <name> [cost args]"
  local dir provider arg args=()
  dir=$(cluster_dir "$1")
  shift
  command -v go >/dev/null 2>&1 || die "go not found"
  provider=$(cat "$dir/.provider")
  while IFS= read -r arg; do args+=(--var-file "${arg#-var-file=}"); done < <(var_file_args "$dir")
  cd "$ROOT/tools/cost"
  exec go run . --provider "$provider" ${args[@]+"${args[@]}"} "$@"
}

# --- register ---------------------------------------------------------------

# True when IPv4 $1 lies inside CIDR $2 (non-IPv4 input never matches).
ip_in_cidr() {
  local ip=$1 cidr=$2 net bits a b c d na nb nc nd ipn netn mask
  net=${cidr%/*}
  bits=${cidr#*/}
  [ "$net" != "$cidr" ] || bits=32
  case "$ip$net" in *[!0-9./]*) return 1 ;; esac
  IFS=. read -r a b c d <<<"$ip"
  IFS=. read -r na nb nc nd <<<"$net"
  [ -n "${d:-}" ] && [ -n "${nd:-}" ] || return 1
  ipn=$(((a << 24) + (b << 16) + (c << 8) + d))
  netn=$(((na << 24) + (nb << 16) + (nc << 8) + nd))
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  [ $((ipn & mask)) -eq $((netn & mask)) ]
}

# Var files deploy.sh would use for cluster $1, in its order (for read-only evaluation).
var_file_args() {
  local dir=$1 provider f
  provider=$(cat "$dir/.provider")
  for f in "$ROOT/common-all.tfvars" "$CLUSTERS/common-all.tfvars" "$CLUSTERS/common-$provider.tfvars" "$dir/terraform.tfvars"; do
    [ -f "$f" ] && printf -- '-var-file=%s\n' "$f"
  done
  return 0
}

# Mgmt ingress_cidrs must admit the downstream egress IPs: the agents dial the mgmt Rancher.
check_ingress() { # mgmt_dir mgmt_name, then "name<TAB>ips" lines on stdin
  local mdir=$1 cidrs_json args=() line ips ip name missing=0 cidr ok cidrs
  while IFS= read -r line; do args+=("$line"); done < <(var_file_args "$mdir")
  cidrs_json=$(cd "$mdir" && echo 'jsonencode(var.ingress_cidrs)' | terraform console ${args[@]+"${args[@]}"} 2>/dev/null | jq -r '. | fromjson | .[]' 2>/dev/null) || cidrs_json=""
  cidrs=$cidrs_json
  local known=1
  [ -n "$cidrs" ] || known=0
  while IFS=$'\t' read -r name ips; do
    [ -n "$name" ] || continue
    if [ -z "$ips" ]; then
      warn "$name reports no egress_ips; make sure the management ingress_cidrs admit it"
      continue
    fi
    say "  $name egress: $ips"
    [ "$known" = 1 ] || continue
    for ip in $ips; do
      ok=0
      for cidr in $cidrs; do
        if ip_in_cidr "$ip" "$cidr"; then ok=1 && break; fi
      done
      [ "$ok" = 1 ] || { warn "$name egress $ip is not in the management ingress_cidrs"; missing=1; }
    done
  done
  if [ "$known" = 0 ]; then
    warn "cannot read the management ingress_cidrs; make sure they include the egress IPs above"
    return 0
  fi
  return "$missing"
}

remote_apply() { # name url insecure
  local name=$1 url=$2 insecure=$3 dir curl_opts=(-fsS) init
  dir="$CLUSTERS/$name"
  [ "$insecure" != true ] || curl_opts+=(-k)
  (
    # shellcheck source=../../scripts/lib/ssh.sh
    . "$ROOT/scripts/lib/ssh.sh"
    SSH_DIR=$dir
    ssh_setup
    init=$(jq -r '[(.nodes.value // {}) | to_entries[] | select(.value.init == true) | .key] | first // empty' <<<"$TF_JSON")
    [ -n "$init" ] || ssh_die "no init node in outputs of $name"
    kc='KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl'
    if ssh_run -n "$init" "$kc get deployment cattle-cluster-agent -n cattle-system" >/dev/null 2>&1; then
      say "$name: Rancher agent already installed, skipping"
      exit 0
    fi
    # The URL carries the registration token: keep it out of argv (curl -K reads stdin).
    printf 'url = "%s"\n' "$url" | curl "${curl_opts[@]}" -K - |
      ssh_run "$init" "$kc apply -f -" >/dev/null || ssh_die "registration failed on $name"
    say "$name: registration manifest applied on $init"
  )
}

cmd_register() {
  local bootstrap=0 skip_cidr=0 yes=0 names=() mgmt m_dir d_dir n
  while [ $# -gt 0 ]; do
    case "$1" in
      --bootstrap) bootstrap=1 ;;
      --skip-cidr-check) skip_cidr=1 ;;
      --yes | -y) yes=1 ;;
      -*) die "unknown option: $1" ;;
      *) names+=("$1") ;;
    esac
    shift
  done
  [ ${#names[@]} -ge 2 ] || die "usage: cluster.sh register [--bootstrap] [--skip-cidr-check] [--yes] <mgmt> <downstream...>"
  for n in jq terraform curl; do command -v "$n" >/dev/null 2>&1 || die "$n not found"; done

  mgmt=${names[0]}
  m_dir=$(cluster_dir "$mgmt")
  local state="$CLUSTERS/.register/$mgmt" downstream=() listed
  # Register state holds the registration tokens (and the admin token with --bootstrap).
  (umask 077 && mkdir -p "$state")
  chmod 700 "$state"
  # Registered clusters accumulate: an earlier run's clusters stay imported.
  if [ -f "$state/downstream.list" ]; then
    while IFS= read -r listed; do [ -n "$listed" ] && downstream+=("$listed"); done <"$state/downstream.list"
  fi
  for n in "${names[@]:1}"; do
    [ "$n" != "$mgmt" ] || die "$n is the management cluster"
    cluster_dir "$n" >/dev/null
    case " ${downstream[*]:-} " in *" $n "*) ;; *) downstream+=("$n") ;; esac
  done
  [ "$bootstrap" = 1 ] || [ ! -f "$state/bootstrap" ] || bootstrap=1

  local m_json rancher_url rancher_name
  m_json=$(cd "$m_dir" && terraform output -json) || die "no outputs for $mgmt (deploy it first)"
  rancher_url=$(jq -r '.rancher_url.value // empty' <<<"$m_json")
  rancher_name=$(jq -r '.cluster_name.value // empty' <<<"$m_json")
  [ -n "$rancher_url" ] || die "$mgmt has no rancher_url (Rancher is not enabled there)"

  # Non-secret fields only; they reach Terraform through the environment.
  local ds_json='{}' egress_lines="" j
  for n in "${downstream[@]}"; do
    d_dir=$(cluster_dir "$n")
    j=$(cd "$d_dir" && terraform output -json) || die "no outputs for $n (deploy it first)"
    ds_json=$(jq -c --arg k "$n" --argjson o "$j" \
      '. + {($k): {cluster_name: $o.cluster_name.value, provider: $o.provider.value, egress_ips: ($o.egress_ips.value // [])}}' <<<"$ds_json") ||
      die "outputs of $n are missing cluster_name, provider or egress_ips"
    egress_lines="$egress_lines$n	$(jq -r '(.egress_ips.value // []) | join(" ")' <<<"$j")
"
  done

  say "Management: $mgmt ($rancher_url)"
  if ! printf '%s' "$egress_lines" | check_ingress "$m_dir" "$mgmt"; then
    if [ "$skip_cidr" = 1 ]; then
      warn "continuing (--skip-cidr-check)"
    else
      die "add the egress IPs to ingress_cidrs of $mgmt and redeploy it, or pass --skip-cidr-check"
    fi
  fi

  local -a tf_args=(-input=false)
  if [ "$bootstrap" = 0 ]; then
    if [ -z "${RANCHER_TOKEN_KEY:-}" ] && ! { [ -f "$CLUSTERS/common-register.tfvars" ] && grep -q '^[[:space:]]*rancher_token[[:space:]]*=' "$CLUSTERS/common-register.tfvars"; }; then
      die "no Rancher API token: export RANCHER_TOKEN_KEY=<access:secret>, set rancher_token in clusters/common-register.tfvars, or use --bootstrap (first login)"
    fi
  else
    TF_VAR_bootstrap=true
    TF_VAR_bootstrap_password=$(jq -r '.rancher_bootstrap_password.value // empty' <<<"$m_json")
    [ -n "$TF_VAR_bootstrap_password" ] || die "$mgmt exposes no rancher_bootstrap_password"
    export TF_VAR_bootstrap TF_VAR_bootstrap_password
    : >"$state/bootstrap"
  fi
  [ ! -f "$CLUSTERS/common-register.tfvars" ] || tf_args+=("-var-file=$CLUSTERS/common-register.tfvars")
  [ "$yes" = 0 ] || tf_args+=(-auto-approve)

  TF_VAR_mgmt=$(jq -cn --arg n "$rancher_name" --arg u "$rancher_url" '{cluster_name: $n, rancher_url: $u}')
  TF_VAR_downstream=$ds_json
  export TF_VAR_mgmt TF_VAR_downstream
  # TF_DATA_DIR only on the register root: exported, it would also redirect the
  # terraform output that remote_apply runs in each cluster directory.
  reg_tf() { TF_DATA_DIR="$state/.terraform" terraform -chdir="$REGISTER_ROOT" "$@"; }

  reg_tf init -input=false -reconfigure -backend-config="path=$state/terraform.tfstate" >/dev/null ||
    die "terraform init failed in tools/multicluster/register"
  reg_tf apply "${tf_args[@]}" || die "terraform apply failed"
  printf '%s\n' "${downstream[@]}" >"$state/downstream.list"

  local regs insecure url
  regs=$(reg_tf output -json registrations) || die "cannot read registrations"
  insecure=$(reg_tf output -json rancher_insecure)
  for n in "${downstream[@]}"; do
    url=$(jq -r --arg k "$n" '.[$k] // empty' <<<"$regs")
    [ -n "$url" ] || die "no registration URL for $n"
    remote_apply "$n" "$url" "$insecure"
  done
  say "done. Clusters become Active in Rancher once the agents connect: $rancher_url"
}

main() {
  local cmd=${1:-}
  [ $# -eq 0 ] || shift
  case "$cmd" in
    new) cmd_new "$@" ;;
    deploy) cmd_deploy "$@" ;;
    destroy) cmd_destroy "$@" ;;
    register) cmd_register "$@" ;;
    list) cmd_list "$@" ;;
    cost) cmd_cost "$@" ;;
    -h | --help | help | "") usage ;;
    *) usage >&2 && die "unknown command: $cmd" ;;
  esac
}

main "$@"
