#!/usr/bin/env bash
# Sourced by every script that runs Terraform or OpenTofu. Sets and exports
# TF_BIN, the binary all of them call: $TF_BIN if set (name or path), else
# terraform, else tofu. Both must behave the same; the scripts only use init,
# plan, apply, show, output, state and console.
#
#   TF_BIN=tofu ./deploy.sh      use OpenTofu although terraform is installed

if [ -z "${TF_BIN:-}" ]; then
  if command -v terraform >/dev/null 2>&1; then
    TF_BIN=terraform
  elif command -v tofu >/dev/null 2>&1; then
    TF_BIN=tofu
  else
    TF_BIN=terraform # missing: the caller's dependency check reports it
  fi
fi
export TF_BIN

# TOFU_TESTED_MIN: oldest OpenTofu release the scripts and modules were checked with. OpenTofu
# ignores required_version, so nothing else stops an older release.
TOFU_TESTED_MIN_MAJOR=1
TOFU_TESTED_MIN_MINOR=13

# tf_warn_old_tofu: prints a warning on stderr when TF_BIN is an OpenTofu older than the tested one.
# Silent for Terraform (required_version enforces its floor) and when the version cannot be read.
tf_warn_old_tofu() {
  local out
  out=$("$TF_BIN" version 2>/dev/null) || return 0
  if [[ $out =~ ^OpenTofu\ v([0-9]+)\.([0-9]+) ]]; then
    local major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
    if [ "$major" -lt "$TOFU_TESTED_MIN_MAJOR" ] ||
      { [ "$major" -eq "$TOFU_TESTED_MIN_MAJOR" ] && [ "$minor" -lt "$TOFU_TESTED_MIN_MINOR" ]; }; then
      echo "warning: OpenTofu $major.$minor is older than $TOFU_TESTED_MIN_MAJOR.$TOFU_TESTED_MIN_MINOR, the oldest release these modules were tested with" >&2
    fi
  fi
  return 0
}
