terraform {
  required_version = ">= 1.16.5"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.32" # vpc_only (2.32.0) and vultr_nat_gateway (2.29.0)
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
