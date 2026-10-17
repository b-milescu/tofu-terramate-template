variable "bucket_name" {
  description = "Globally unique name of the OpenTofu state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters: lowercase letters, digits and hyphens."
  }
}

variable "kms_alias_name" {
  description = "Alias of the state KMS key without the alias/ prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]{1,250}$", var.kms_alias_name)) && !startswith(var.kms_alias_name, "alias/") && !startswith(var.kms_alias_name, "aws/")
    error_message = "kms_alias_name must not start with alias/ or aws/."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days after which noncurrent state versions expire."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 7 && var.noncurrent_version_retention_days <= 3650
    error_message = "noncurrent_version_retention_days must be between 7 and 3650."
  }
}
