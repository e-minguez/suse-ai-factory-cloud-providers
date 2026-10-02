#!/usr/bin/env bash
# Single-pass deploy: deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <tf args>]
set -euo pipefail

# Resolve symlinks portably (no readlink -f on macOS) before the cd: BASH_SOURCE may be relative.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
DEPLOY_LIB="$(cd "$(dirname "$src")/../../scripts/lib" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")"

DEPLOY_PROVIDER=aws
# shellcheck source=../../scripts/lib/deploy-common.sh
. "$DEPLOY_LIB/deploy-common.sh"

# Probe iam:CreateRole (and TagRole) with an invalid trust policy: allowed calls fail
# validation and create nothing, denied calls return AccessDenied.
deploy_check_iam() {
  local role out rc=0
  role="$(deploy_cluster_name)-jumphost"
  out=$(aws iam create-role --role-name "$role" --assume-role-policy-document '{}' \
    --tags Key=elemental-managed-by,Value=preflight 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
    return 0
  fi
  case "$out" in
    *AccessDenied*)
      deploy_die "the AWS identity cannot create IAM role $role (iam:CreateRole/iam:TagRole denied).
The module creates IAM roles and an instance profile named <cluster_name>-*; use a
profile with IAM permissions (e.g. an administrator permission set).
$out" ;;
  esac
}

# True when both pre-created IAM names are set: the module creates no IAM, so no probe.
deploy_iam_precreated() {
  [ -n "$(deploy_var_string vmimport_role_name)" ] &&
    [ -n "$(deploy_var_string jumphost_instance_profile_name)" ]
}

# The AWS CLI is optional; when present, fail early on expired credentials and missing IAM permissions.
deploy_precheck() {
  command -v aws >/dev/null 2>&1 || return 0
  aws sts get-caller-identity >/dev/null 2>&1 ||
    deploy_die "AWS credentials are not valid; for SSO run: aws sso login --profile <profile>"
  [ "$DEPLOY_DESTROY" = 1 ] || deploy_iam_precreated || deploy_check_iam
}

# Suggests the leftover check after destroy; the tool needs a region (var files, else AWS_REGION).
deploy_after_destroy() {
  local region
  region=$(deploy_var_string region)
  region=${region:-${AWS_REGION:-${AWS_DEFAULT_REGION:-<region>}}}
  deploy_suggest_leftovers aws "$(deploy_cluster_name)" --region "$region"
}

deploy_passes() {
  tf_pass "Deploy"
}

deploy_main "$@"
