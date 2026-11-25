terraform {
  required_version = ">= 1.16.5"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = ">= 1.8.0, < 2.0.0"
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
