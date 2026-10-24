terraform {
  required_version = ">= 1.12"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.0, < 6.0"
    }
  }
}

language {
  compatible_with {
    opentofu = ">= 1.12"
  }
}
