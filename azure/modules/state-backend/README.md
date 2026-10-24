# state-backend

Creates the resource group, storage account and blob container that hold one Azure subscription and region's OpenTofu state. The account is Entra ID only (shared keys, local users, anonymous access and cross-tenant replication off), accepts HTTPS and TLS 1.2 only, uses Microsoft-managed keys with infrastructure encryption and replicates to the region's Azure pair (`GRS`, fixed in `main.tf`: a region without a pair, such as Poland Central, Italy North or Spain Central, needs `ZRS` there and an inline checkov skip for `CKV_AZURE_206`). It has blob versioning, 30-day soft delete of blobs and containers, a policy deleting versions after 90 days, a `CanNotDelete` lock (remove it before destroying anything below the account) and `prevent_destroy`; the container is private. The listed principals get Storage Blob Data Contributor on the resource group, which holds only the account. Applied once per subscription and region through the generated call in `stacks/<environment>/<region>/state-backend`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 5.0, < 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 5.0, < 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_management_lock.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock) | resource |
| [azurerm_resource_group.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.state_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_container.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_management_policy.state](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_management_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_container_name"></a> [container\_name](#input\_container\_name) | Name of the blob container that holds the state blobs. | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region of the state resource group and storage account, as its short name (for example germanywestcentral). | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group that holds the state storage account. | `string` | n/a | yes |
| <a name="input_state_contributor_principal_ids"></a> [state\_contributor\_principal\_ids](#input\_state\_contributor\_principal\_ids) | Object ids of the users, groups or service principals that get Storage Blob Data Contributor on the state resource group. The principal that runs the bootstrap must be one of them: Owner and Contributor have no blob data actions and the account has no keys. | `set(string)` | n/a | yes |
| <a name="input_storage_account_name"></a> [storage\_account\_name](#input\_storage\_account\_name) | Globally unique name of the OpenTofu state storage account. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for the resource group and the storage account. The azurerm provider has no default\_tags. | `map(string)` | `{}` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
