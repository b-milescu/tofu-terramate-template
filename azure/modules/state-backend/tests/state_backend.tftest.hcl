mock_provider "azurerm" {
  # The azurerm provider parses the ids of other resources (storage_account_id, scope): a mock id must be a complete Azure id.
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme-tfstate-germanywestcentral"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme-tfstate-germanywestcentral/providers/Microsoft.Storage/storageAccounts/acmetfstate1a2b3c"
    }
  }
}

variables {
  resource_group_name             = "rg-acme-tfstate-germanywestcentral"
  location                        = "germanywestcentral"
  storage_account_name            = "acmetfstate1a2b3c"
  container_name                  = "state-blobs"
  tags                            = { Project = "acme" }
  state_contributor_principal_ids = ["44444444-4444-4444-4444-444444444444", "55555555-5555-5555-5555-555555555555"]
}

run "hardening_wiring_and_policy" {
  command = plan

  assert {
    condition = (
      azurerm_storage_account.state.shared_access_key_enabled == false &&
      azurerm_storage_account.state.default_to_oauth_authentication == true &&
      azurerm_storage_account.state.local_user_enabled == false &&
      azurerm_storage_account.state.allow_nested_items_to_be_public == false &&
      azurerm_storage_account.state.cross_tenant_replication_enabled == false &&
      azurerm_storage_account.state.https_traffic_only_enabled == true &&
      azurerm_storage_account.state.min_tls_version == "TLS1_2" &&
      azurerm_storage_account.state.infrastructure_encryption_enabled == true
    )
    error_message = "The state account must be Entra ID only, private, TLS 1.2 only and doubly encrypted."
  }

  assert {
    condition     = azurerm_storage_account.state.account_kind == "StorageV2" && azurerm_storage_account.state.account_tier == "Standard" && azurerm_storage_account.state.account_replication_type == "GRS" && azurerm_storage_container.state.container_access_type == "private"
    error_message = "The account must be a Standard StorageV2 account that replicates geo-redundantly, and the container must be private."
  }

  assert {
    condition     = azurerm_resource_group.state.name == var.resource_group_name && azurerm_resource_group.state.location == "germanywestcentral" && azurerm_storage_account.state.location == "germanywestcentral" && azurerm_resource_group.state.tags["Project"] == "acme" && azurerm_storage_account.state.tags["Project"] == "acme"
    error_message = "The resource group and the account must take their name, location and tags from the inputs."
  }

  assert {
    condition     = azurerm_storage_account.state.name == var.storage_account_name && azurerm_storage_account.state.resource_group_name == var.resource_group_name && azurerm_storage_container.state.name == var.container_name
    error_message = "The account and the container must carry the names the generated backend addresses (storage_account_name, container_name), and the account must sit in the state resource group."
  }

  assert {
    condition     = one(azurerm_storage_account.state.blob_properties).versioning_enabled == true && one(one(azurerm_storage_account.state.blob_properties).delete_retention_policy).days == 30 && one(one(azurerm_storage_account.state.blob_properties).container_delete_retention_policy).days == 30
    error_message = "Blob versioning and 30-day soft delete of blobs and containers must be on."
  }

  assert {
    condition     = one(azurerm_storage_management_policy.state.rule).enabled == true && one(azurerm_storage_management_policy.state.rule).filters[0].blob_types == toset(["blockBlob"]) && one(azurerm_storage_management_policy.state.rule).actions[0].version[0].delete_after_days_since_creation == 90
    error_message = "Old blob versions must be deleted after 90 days."
  }

  assert {
    condition     = azurerm_management_lock.state.lock_level == "CanNotDelete" && azurerm_management_lock.state.scope == azurerm_storage_account.state.id
    error_message = "The account must carry a CanNotDelete lock."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.state_contributor) == length(var.state_contributor_principal_ids) &&
      alltrue([
        for id in var.state_contributor_principal_ids : (
          azurerm_role_assignment.state_contributor[id].principal_id == id &&
          azurerm_role_assignment.state_contributor[id].role_definition_name == "Storage Blob Data Contributor" &&
          azurerm_role_assignment.state_contributor[id].scope == azurerm_resource_group.state.id
        )
      ])
    )
    error_message = "Each listed principal must get Storage Blob Data Contributor on the state resource group, not on the account or the container."
  }
}

run "resource_group_name_rejects_trailing_period" {
  command = plan

  variables {
    resource_group_name = "rg-acme-tfstate."
  }

  expect_failures = [var.resource_group_name]
}

run "storage_account_name_rejects_uppercase" {
  command = plan

  variables {
    storage_account_name = "AcmeTfState"
  }

  expect_failures = [var.storage_account_name]
}

run "container_name_rejects_double_hyphen" {
  command = plan

  variables {
    container_name = "tf--state"
  }

  expect_failures = [var.container_name]
}

run "principal_ids_reject_non_guid" {
  command = plan

  variables {
    state_contributor_principal_ids = ["not-a-guid"]
  }

  expect_failures = [var.state_contributor_principal_ids]
}

run "principal_ids_reject_empty_set" {
  command = plan

  variables {
    state_contributor_principal_ids = []
  }

  expect_failures = [var.state_contributor_principal_ids]
}
