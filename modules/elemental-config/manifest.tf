locals {
  aif_release_is_url = can(regex("^https?://", var.aif_release))
  aif_tag            = "aif-operator-${var.aif_release}"

  release_manifest_url = (
    local.aif_release_is_url
    ? var.aif_release
    : "https://raw.githubusercontent.com/SUSE/aif/refs/tags/${local.aif_tag}/uc-release-manifest/release_manifest.yaml"
  )
}

# Fetched at plan time: the body feeds build_hash and, after the beta rewrite
# in beta-overrides.tf, is shipped to the build host as release_manifest.yaml.
data "http" "aif_release_manifest" {
  url = local.release_manifest_url

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Fetching the AI Factory release manifest (${local.release_manifest_url}) returned HTTP ${self.status_code}. ${local.aif_release_is_url ? "The URL came from aif_release." : "The URL was derived from aif_release = \"${var.aif_release}\"; check that SUSE/aif has the tag ${local.aif_tag} with uc-release-manifest/release_manifest.yaml, or set aif_release to a manifest URL."}"
    }
  }
}
