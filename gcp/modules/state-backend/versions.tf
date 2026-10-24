terraform {
  required_version = ">= 1.12"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0, < 9.0"
    }
  }
}

language {
  compatible_with {
    opentofu = ">= 1.12"
  }
}
