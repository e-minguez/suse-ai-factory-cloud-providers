terraform {
  required_version = ">= 1.16.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
      # aws.nodes: node instances only, low max_retries (docs/workarounds.md).
      configuration_aliases = [aws.nodes]
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # time_static.created stamps every resource with the created label.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
