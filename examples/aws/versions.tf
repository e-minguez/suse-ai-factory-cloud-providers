terraform {
  # 1.16.4 crashes on some plans; raise to 1.16.5 once released (docs/workarounds.md).
  required_version = ">= 1.16.4"

  required_providers {
    # The only provider this root configures; the module's other providers
    # need no entry here.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
