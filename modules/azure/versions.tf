terraform {
  required_version = ">= 1.16.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14" # schema of the resources and data sources used here was checked against 5.14
    }

    # Read-only ARM calls with no azurerm data source: VM size restrictions and
    # compute/network usages (availability.tf), subnet and NAT gateway details.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.14" # checked against 2.14
    }

    # time_static.created stamps every resource with the created label;
    # time_offset gives the storage SAS tokens a stable validity window.
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
