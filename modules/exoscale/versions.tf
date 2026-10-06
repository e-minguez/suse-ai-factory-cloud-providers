terraform {
  # 1.16.4 crashes on some plans; raise to 1.16.5 once released (docs/workarounds.md).
  required_version = ">= 1.16.4"

  required_providers {
    exoscale = {
      source  = "exoscale/exoscale"
      version = "~> 0.74" # exoscale_template resource (0.72.0), NLB on the plugin framework (0.74.0)
    }

    # Signed API reads (availability, quotas, pool members): no data source covers them.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }

    # time_static.created stamps every resource with the created label.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
