terraform {
  # 1.16.4 crashes on some plans; raise to 1.16.5 once released (docs/workarounds.md).
  required_version = ">= 1.16.4"

  required_providers {
    # 0.9.4 is the first release where evroc_loadbalancer accepts backend_network.
    # See docs/decisions/004-evroc-module-rationale.md.
    evroc = {
      source  = "evroc-oss/evroc"
      version = "~> 0.9.4"
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

    # The config module fetches the AI Factory release manifest at plan time.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }
}
