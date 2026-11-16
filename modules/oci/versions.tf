terraform {
  required_version = ">= 1.16.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.13" # schema of the resources and data sources used here was checked against 9.13
    }

    # time_static.created stamps every resource with the created label;
    # time_offset gives the pre-authenticated requests a stable expiry.
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
