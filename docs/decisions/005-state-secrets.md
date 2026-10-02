# 005 - Secrets in Terraform state

## Status
Accepted.

## Context
The RKE2 join token (`random_password.token`), the Rancher bootstrap password,
registry credentials and password hashes are rendered into the image config or
into node `user_data`. Every provider stores `user_data` in state, and
ephemeral values and write-only attributes do not apply to those attributes.
Removing the `rke2_token` output therefore does not remove the token from state.

## Decision
Keep the token in state through `user_data`, drop the `rke2_token` output, and
treat state as a secret with an encrypted remote backend
([security](../security.md#state-is-secret)).

Options considered:
- B: the init node lets RKE2 generate the token and `deploy.sh` copies it to the
  joiners over SSH. The token leaves state, but a plain `terraform apply` no
  longer yields a working cluster, and node replacement and scale-out need
  `deploy.sh` too.
- C: the token lives in a provider secret store that nodes read at boot. Not
  every provider has one, and instances do not read from object storage
  ([security](../security.md#object-storage)).

## Consequences
A plain `terraform apply` produces a working cluster. Do not reintroduce the
output or move the token out of `user_data` without a new ADR.
