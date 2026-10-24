# Code generated into every stack below this folder. Generated files are committed; run `make generate` after
# changing anything here or in a globals.tm.hcl. Only globals and relative paths are used.

assert {
  assertion = tm_can(tm_regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", global.project_id))
  message   = "project_id (stacks/<environment>/globals.tm.hcl) must be a Google Cloud project ID, not the project number: 6-30 lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen"
}

assert {
  assertion = tm_can(tm_regex("^[a-z]+-[a-z]+[0-9]+$", global.region))
  message   = "region (the folder name in stacks/<environment>/<region>/) must be a Google Cloud region such as us-central1, not a zone, multi-region or dual-region"
}

assert {
  assertion = tm_can(tm_regex("^[a-z][a-z0-9-]*[a-z0-9]$", global.project))
  message   = "project must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit"
}

assert {
  assertion = tm_length(global.state_bucket) <= 63 && !tm_can(tm_regex("^goog|g[o0][o0]gle", global.state_bucket))
  message   = "state bucket name <project>-tfstate-<project_id>-<region> must be at most 63 characters and must neither start with goog nor contain google: shorten or rename project"
}

assert {
  assertion = tm_alltrue([for k, v in global.default_labels : tm_can(tm_regex("^[a-z][a-z0-9_-]{0,62}$", k)) && tm_can(tm_regex("^[a-z0-9_-]{0,63}$", v))])
  message   = "default_labels keys and values, the environment folder name included, must use lowercase letters, digits, underscores and hyphens, at most 63 characters; keys start with a letter"
}

# One state object per stack under the stack id: stacks/<id>/default.tfstate, locked by stacks/<id>/default.tflock. The bucket's
# default key encrypts both. Credentials come from application default credentials only, never from this block.
generate_hcl "_terramate_generated_backend.tf" {
  content {
    terraform {
      backend "gcs" {
        bucket = global.state_bucket
        prefix = "stacks/${terramate.stack.id}"
      }
    }
  }
}

# project and region set here beat GOOGLE_PROJECT, GOOGLE_REGION and their aliases in the environment. The provider has no
# counterpart of AWS allowed_account_ids: the project pinned here is the guard. Credentials come from application default
# credentials only.
generate_hcl "_terramate_generated_provider.tf" {
  content {
    provider "google" {
      project        = global.project_id
      region         = global.region
      default_labels = global.default_labels
    }
  }
}

generate_hcl "_terramate_generated_versions.tf" {
  content {
    terraform {
      required_version = global.opentofu_version

      required_providers {
        google = {
          source  = "hashicorp/google"
          version = global.google_provider_version
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

# The state-backend stack of each project and region: bucket and key names come from the same globals as the backend.
generate_hcl "_terramate_generated_state_backend.tf" {
  condition = tm_contains(terramate.stack.tags, "state-backend")

  content {
    module "state_backend" {
      source = "${terramate.stack.path.to_root}/modules/state-backend"

      location          = global.region
      bucket_name       = global.state_bucket
      kms_key_ring_name = global.state_kms_key_ring
      kms_key_name      = global.state_kms_key
    }
  }
}

# Blocks `tofu destroy` (and `plan -destroy`) of whole stacks in protected environments. Every stacks/<environment>/globals.tm.hcl sets
# protect_destroy (true or false): a missing or misspelt key fails on the condition below.
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
