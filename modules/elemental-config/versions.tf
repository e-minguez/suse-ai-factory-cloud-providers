terraform {
  required_version = ">= 1.16.5"

  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
