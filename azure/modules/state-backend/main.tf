resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# The three trivy ignores below are choices each organisation makes for itself:
# AVD-AZU-0012 network rules: the public endpoint stays on, access is Entra ID only; rules or a private endpoint would lock out laptops and CI runners.
# AVD-AZU-0057 logging: the check looks for queue logging; no queue service is used and queue_properties no longer exists in azurerm 5.x.
# AVD-AZU-0060 customer-managed key: Microsoft-managed keys with infrastructure encryption; a customer-managed key needs a Key Vault with purge protection.
#trivy:ignore:AVD-AZU-0012
#trivy:ignore:AVD-AZU-0057
#trivy:ignore:AVD-AZU-0060
resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys with infrastructure encryption; a customer-managed key needs a Key Vault with purge protection, decided per organisation.
  #checkov:skip=CKV2_AZURE_33:A private endpoint needs a network the runner can reach; the account is Entra ID only and reachable from the public endpoint by design.
  #checkov:skip=CKV_AZURE_33:No queue service is used; classic Storage Analytics logging is superseded by diagnostic settings.
  #checkov:skip=CKV_AZURE_59:Disabling public network access would lock out laptops and CI runners; access is Entra ID only, add IP rules or a private endpoint per organisation.
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
  tags                = var.tags

  account_kind = "StorageV2"
  account_tier = "Standard"
  # GRS puts a second copy in the region's Azure pair, and not every region has one: Microsoft Learn lists, for example, Poland Central,
  # Italy North and Spain Central as having none. There set "ZRS" instead and add an inline checkov skip for CKV_AZURE_206 with its reason.
  account_replication_type = "GRS"

  # Entra ID only: no shared keys, no key-signed SAS, no local users, no anonymous reads.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  local_user_enabled              = false
  allow_nested_items_to_be_public = false

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  #checkov:skip=CKV2_AZURE_21:Blob read logging needs a diagnostic setting and a log destination; add one per organisation.
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

# Owner and Contributor have no blob data actions and the account has no keys: whoever runs tofu needs this role. The scope is the
# resource group (it holds only the account), not the container: the lock below also blocks deleting role assignments at or below
# the account, so removing a principal from the list would fail with ScopeLocked.
resource "azurerm_role_assignment" "state_contributor" {
  for_each = var.state_contributor_principal_ids

  scope                = azurerm_resource_group.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

resource "azurerm_storage_management_policy" "state" {
  storage_account_id = azurerm_storage_account.state.id

  rule {
    name    = "expire-old-state-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}

# Counterpart of prevent_destroy for the control plane. Created last, so destroy removes it first: a CanNotDelete lock also
# blocks deleting the container and the management policy below the account.
resource "azurerm_management_lock" "state" {
  name       = "cannot-delete-state"
  scope      = azurerm_storage_account.state.id
  lock_level = "CanNotDelete"
  notes      = "OpenTofu state storage: remove this lock before destroying."

  depends_on = [
    azurerm_storage_container.state,
    azurerm_storage_management_policy.state,
  ]
}
