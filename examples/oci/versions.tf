terraform {
  required_version = ">= 1.16.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.13"
    }
  }
}
