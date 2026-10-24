# Code generated into every stack below this folder. Generated files are committed; run `make generate` after
# changing anything here or in a globals.tm.hcl. Only globals and relative paths are used.

assert {
  assertion = tm_can(tm_regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", global.subscription_id))
  message   = "subscription_id (stacks/<environment>/globals.tm.hcl) must be an Azure subscription id: a GUID in lowercase"
}

assert {
  assertion = tm_length(global.state_contributor_principal_ids) > 0 && tm_alltrue([for id in global.state_contributor_principal_ids : tm_can(tm_regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))])
  message   = "state_contributor_principal_ids (stacks/<environment>/globals.tm.hcl) must list at least one Entra ID object id, a GUID in lowercase"
}

assert {
  assertion = tm_can(tm_regex("^[a-z][a-z0-9]+$", global.region))
  message   = "region (the folder name in stacks/<environment>/<region>/) must be an Azure location name in lowercase without spaces (az account list-locations, column Name), not a display name"
}

assert {
  assertion = tm_can(tm_regex("^[a-z][a-z0-9-]*[a-z0-9]$", global.project))
  message   = "project must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit"
}

assert {
  assertion = tm_can(tm_regex("^[a-z0-9]{3,24}$", global.state_storage_account))
  message   = "state_storage_account must be 3-24 lowercase letters and digits"
}

# Resource group names are 1-90 characters. The network stack's rg-<project>-network-<region> is as long as this one.
assert {
  assertion = tm_length(global.state_resource_group) <= 90
  message   = "state resource group name rg-<project>-tfstate-<region> is longer than 90 characters (the network stack's rg-<project>-network-<region> is as long): shorten project"
}

# One state blob per stack under the stack id, locked by a blob lease. Entra ID only: the state account has no shared keys.
# Credentials come from az login or ARM_* variables, never from this block. No tenant_id: with subscription_id it makes the
# az CLI token request fail ("Please specify only one of subscription and tenant, not both").
generate_hcl "_terramate_generated_backend.tf" {
  content {
    terraform {
      backend "azurerm" {
        subscription_id      = global.subscription_id
        storage_account_name = global.state_storage_account
        container_name       = global.state_container
        key                  = "stacks/${terramate.stack.id}/tofu.tfstate"
        use_azuread_auth     = true
      }
    }
  }
}

# subscription_id set here beats ARM_SUBSCRIPTION_ID and the az CLI default subscription. The provider has no counterpart of AWS
# allowed_account_ids: the subscription pinned here is the guard. Credentials come from az login or ARM_* variables only.
generate_hcl "_terramate_generated_provider.tf" {
  content {
    provider "azurerm" {
      subscription_id = global.subscription_id

      features {}
    }
  }
}

generate_hcl "_terramate_generated_versions.tf" {
  content {
    terraform {
      required_version = global.opentofu_version

      required_providers {
        azurerm = {
          source  = "hashicorp/azurerm"
          version = global.azurerm_provider_version
        }
      }
    }

    language {
      compatible_with {
        opentofu = global.opentofu_version
      }
    }
  }
}

# Every stack gets its location and tags as locals: the azurerm provider has no default tags, so each resource that takes tags
# passes tags = local.tags. tflint (terraform_unused_declarations) flags a stack that uses neither.
generate_hcl "_terramate_generated_locals.tf" {
  content {
    locals {
      location = global.region
      tags     = global.tags
    }
  }
}

# The state-backend stack of each subscription and region: account and container names come from the same globals as the backend.
generate_hcl "_terramate_generated_state_backend.tf" {
  condition = tm_contains(terramate.stack.tags, "state-backend")

  content {
    module "state_backend" {
      source = "${terramate.stack.path.to_root}/modules/state-backend"

      resource_group_name             = global.state_resource_group
      location                        = local.location
      storage_account_name            = global.state_storage_account
      container_name                  = global.state_container
      state_contributor_principal_ids = global.state_contributor_principal_ids
      tags                            = local.tags
    }
  }
}

# Blocks `tofu destroy` (and `plan -destroy`) of whole stacks in protected environments.
generate_hcl "_terramate_generated_destroy_guard.tf" {
  condition = global.protect_destroy

  content {
    resource "terraform_data" "destroy_guard" {
      lifecycle {
        prevent_destroy = true
      }
    }
  }
}
