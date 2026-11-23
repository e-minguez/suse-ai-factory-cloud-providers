terraform {
  required_version = ">= 1.16.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0" # schema of the resources and data sources used here was checked against 8.x
    }

    # Compute API reads for quotas and the build guest attributes (no data source exists).
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
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
