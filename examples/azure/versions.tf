terraform {
  required_version = ">= 1.16.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }

    azapi = {
      source  = "azure/azapi"
      version = "~> 2.14"
    }
  }
}
