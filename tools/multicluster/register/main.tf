# Imports downstream clusters into the management cluster's Rancher and exposes
# their registration manifest URLs. cluster.sh applies the manifests over SSH.

# First-login mode: only used with bootstrap = true.
provider "rancher2" {
  alias     = "bootstrap"
  api_url   = var.mgmt.rancher_url
  bootstrap = true
  insecure  = var.rancher_insecure
}

resource "rancher2_bootstrap" "admin" {
  count = var.bootstrap ? 1 : 0

  provider         = rancher2.bootstrap
  initial_password = var.bootstrap_password

  lifecycle {
    precondition {
      condition     = var.bootstrap_password != null
      error_message = "bootstrap = true needs bootstrap_password."
    }
  }
}

provider "rancher2" {
  api_url   = var.mgmt.rancher_url
  insecure  = var.rancher_insecure
  token_key = var.bootstrap ? rancher2_bootstrap.admin[0].token : var.rancher_token
}

# A rancher2_cluster without a *_config block is an imported cluster.
resource "rancher2_cluster" "downstream" {
  for_each = var.downstream

  name        = each.value.cluster_name
  description = "Imported from ${each.value.provider} (${each.key})"
}
