terraform {
  required_version = ">= 1.16.5"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = ">= 1.8.0, < 2.0.0"
    }
  }
}
