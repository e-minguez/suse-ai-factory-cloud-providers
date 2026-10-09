terraform {
  required_version = ">= 1.16.5"

  # cluster.sh passes -backend-config=path=... so state lives in clusters/.register/<mgmt>/.
  backend "local" {}

  required_providers {
    rancher2 = {
      source  = "rancher/rancher2"
      version = ">= 15.1, < 16.0"
    }
  }
}
