terraform {
  required_version = ">= 1.16.5"

  required_providers {
    # The only provider this root configures; the module's other providers
    # need no entry here.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
