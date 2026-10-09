terraform {
  required_version = ">= 1.16.5"

  required_providers {
    exoscale = {
      source  = "exoscale/exoscale"
      version = "~> 0.74"
    }
  }
}
