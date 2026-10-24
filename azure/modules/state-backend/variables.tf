variable "resource_group_name" {
  description = "Name of the resource group that holds the state storage account."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._()-]{1,90}$", var.resource_group_name)) && !endswith(var.resource_group_name, ".")
    error_message = "resource_group_name must be 1-90 characters: letters, digits, . _ ( ) -, and must not end with a period."
  }
}

variable "location" {
  description = "Azure region of the state resource group and storage account, as its short name (for example germanywestcentral)."
  type        = string
}

variable "storage_account_name" {
  description = "Globally unique name of the OpenTofu state storage account."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 characters: lowercase letters and digits only."
  }
}

variable "container_name" {
  description = "Name of the blob container that holds the state blobs."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.container_name)) && !strcontains(var.container_name, "--")
    error_message = "container_name must be 3-63 characters: lowercase letters, digits and single hyphens, starting and ending with a letter or digit."
  }
}

variable "tags" {
  description = "Tags for the resource group and the storage account. The azurerm provider has no default_tags."
  type        = map(string)
  default     = {}
}

variable "state_contributor_principal_ids" {
  description = "Object ids of the users, groups or service principals that get Storage Blob Data Contributor on the state resource group. The principal that runs the bootstrap must be one of them: Owner and Contributor have no blob data actions and the account has no keys."
  type        = set(string)

  validation {
    condition     = length(var.state_contributor_principal_ids) > 0 && alltrue([for id in var.state_contributor_principal_ids : can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", id))])
    error_message = "state_contributor_principal_ids must list at least one Entra ID object id (a GUID)."
  }
}
