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
