terraform {
  # 1.16.4 crashes on some plans; raise to 1.16.5 once released (docs/workarounds.md).
  required_version = ">= 1.16.4"

  required_providers {
    exoscale = {
      source  = "exoscale/exoscale"
      version = "~> 0.74"
    }
  }
}
