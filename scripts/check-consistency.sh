#!/usr/bin/env bash
# Consistency checks across providers (CLAUDE.md "Layout", "Conventions").
# 1. modules/<provider>/variables-common.tf is a symlink to the common file.
# 2. Every key in common-all.tfvars.example is declared by every example.
# 3. Variables from variables-common.tf declared by several examples have the
#    same type and default in each, except provider-specific defaults.
# 4. Output names match docs/conventions.md and examples/<p>/outputs.tf are identical.
# 5. Every provider module sets the four managed label keys.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

common=modules/common/variables-common.tf
shared_modules=" common elemental-config image-factory rke2-ports "

# Names of declared variables, one per line.
declared() { cat "$@" | sed -n 's/^variable "\([a-z0-9_]*\)".*/\1/p' | sort -u; }

# Type and default of one variable, normalised (no description or validation).
signature() { # file name
  awk -v n="$2" '
    $0 ~ "^variable \"" n "\"" { on = 1; next }
    on && /^}/ { exit }
    on {
      if (skip) { skip += gsub(/{/, "{") - gsub(/}/, "}"); next }
      if ($0 ~ /^[[:space:]]*validation[[:space:]]*{/) { skip = 1; next }
      if ($0 ~ /^[[:space:]]*description/) next
      gsub(/[[:space:]]+/, " "); print
    }' "$1"
}

providers=()
for d in modules/*/; do
  name=$(basename "$d")
  [[ -f "$d/versions.tf" && "$shared_modules" != *" $name "* ]] || continue
  providers+=("$name")
  link="$d/variables-common.tf"
  if [[ ! -L "$link" ]]; then
    err "$link is not a symlink"
  elif [[ ! "$link" -ef "$common" ]]; then
    err "$link does not resolve to $common"
  fi
done
[[ ${#providers[@]} -gt 0 ]] || err "no provider modules found"

# Keys users set in common-all.tfvars.example, active or commented out.
mapfile -t keys < <(sed -n 's/^#\{0,1\} \{0,1\}\([a-z][a-z0-9_]*\) *= .*/\1/p' common-all.tfvars.example | sort -u)
common_names=$(declared "$common")
# Variables whose default legitimately differs per provider.
provider_specific=" region rancher_hostname gpu_driver_repository gpu_driver_version "
for k in "${keys[@]}"; do
  grep -qx "$k" <<<"$common_names" || err "common-all.tfvars.example: $k is not in variables-common.tf"
  for p in "${providers[@]}"; do
    declared examples/"$p"/*.tf | grep -qx "$k" || err "examples/$p does not declare $k (set in common-all.tfvars.example)"
  done
done

while read -r v; do
  [[ " $provider_specific " == *" $v "* ]] && continue
  ref="" refp=""
  for p in "${providers[@]}"; do
    f=$(grep -l "^variable \"$v\"" examples/"$p"/*.tf 2>/dev/null | head -1 || true)
    [[ -n "$f" ]] || continue
    sig=$(signature "$f" "$v")
    if [[ -z "$refp" ]]; then ref=$sig refp=$p
    elif [[ "$sig" != "$ref" ]]; then err "$v: type/default differs between examples/$refp and examples/$p"; fi
  done
done <<<"$common_names"

# 4. Output set (docs/conventions.md): same names in every provider module,
#    and examples/<p>/outputs.tf identical across providers.
required_outputs="api_host api_vip build_status cluster_name egress_ips image ingress_endpoint jumphost kubernetes_api_endpoint network next_steps nodes provider provider_details rancher_bootstrap_password rancher_hostname rancher_url region"
outputs_of() { sed -n 's/^output "\([a-z0-9_]*\)".*/\1/p' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
ref_example=""
for p in "${providers[@]}"; do
  got=$(outputs_of modules/"$p"/*.tf)
  [[ "$got" == "$required_outputs" ]] || err "modules/$p outputs differ from the required set: $got"
  if [[ -z "$ref_example" ]]; then ref_example=examples/$p/outputs.tf
  elif ! cmp -s "$ref_example" examples/"$p"/outputs.tf; then err "examples/$p/outputs.tf differs from $ref_example"; fi
done

# 5. Every provider module sets the four managed label keys (CLAUDE.md "Conventions").
for p in "${providers[@]}"; do
  for k in cluster managed-by module created; do
    grep -qF "\"elemental-$k\"" modules/"$p"/*.tf || err "modules/$p does not set the elemental-$k label"
  done
done

if [[ $fail -eq 0 ]]; then echo "check-consistency: ok (${providers[*]})"; fi
exit $fail
