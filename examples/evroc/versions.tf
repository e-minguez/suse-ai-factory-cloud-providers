terraform {
  # 1.16.4 crashes on some plans; raise to 1.16.5 once released (docs/workarounds.md).
  required_version = ">= 1.16.4"

  required_providers {
    # 0.9.4 is the first release with evroc_loadbalancer.backend_network --
    # see the module's own versions.tf.
    evroc = {
      source  = "evroc-oss/evroc"
      version = "~> 0.9.4"
    }
  }
}

# Empty on purpose: the provider reads ~/.evroc/config.yaml, written by
# `evroc login`. region and project are module variables (null = the CLI context).
provider "evroc" {}
