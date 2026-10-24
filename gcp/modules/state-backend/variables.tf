variable "location" {
  description = "Region of the state bucket and the KMS key ring, e.g. europe-west3. Both must live in the same location."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.location))
    error_message = "location must be a lowercase region such as europe-west3 (no multi-region, no dual-region)."
  }
}

variable "bucket_name" {
  description = "Globally unique name of the OpenTofu state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.bucket_name)) && !can(regex("^goog|g[o0][o0]gle", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters: lowercase letters, digits, hyphens and underscores, start and end with a letter or digit, not start with goog and not contain google or a lookalike such as g00gle."
  }
}

variable "kms_key_ring_name" {
  description = "Name of the KMS key ring (key rings cannot be deleted or renamed)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.kms_key_ring_name))
    error_message = "kms_key_ring_name must be 1-63 characters: letters, digits, hyphens and underscores."
  }
}

variable "kms_key_name" {
  description = "Name of the KMS crypto key that encrypts the state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.kms_key_name))
    error_message = "kms_key_name must be 1-63 characters: letters, digits, hyphens and underscores."
  }
}
