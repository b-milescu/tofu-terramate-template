# Code generated into every stack below this folder. Generated files are committed; run `make generate` after
# changing anything here or in a globals.tm.hcl. Only globals and relative paths are used.

assert {
  assertion = tm_can(tm_regex("^[0-9]{12}$", global.account_id))
  message   = "account_id must be a 12-digit AWS account id"
}

# ponytail: standard partition only: arn:aws is written out in the backend kms_key_id below and in modules/state-backend's key policy; for cn-* or us-gov-* add a partition global and use it in both.
assert {
  assertion = tm_can(tm_regex("^[a-z]{2}-[a-z]+-[0-9]+$", global.region)) && !tm_can(tm_regex("^cn-", global.region))
  message   = "region (the folder name in stacks/<account>/<region>/) must be a standard-partition AWS region such as eu-central-1, not cn-*, us-gov-* or us-iso*"
}

assert {
  assertion = tm_can(tm_regex("^[a-z][a-z0-9-]*[a-z0-9]$", global.project)) && !tm_can(tm_regex("^(xn--|sthree-|amzn-s3-demo-)", global.project))
  message   = "project must use lowercase letters, digits and hyphens, start with a letter, end with a letter or digit, and not start with xn--, sthree- or amzn-s3-demo-"
}

assert {
  assertion = tm_length(global.state_bucket) <= 63
  message   = "state bucket name <project>-tfstate-<account_id>-<region> is longer than 63 characters: shorten project"
}

generate_hcl "_terramate_generated_backend.tf" {
  content {
    terraform {
      backend "s3" {
        bucket              = global.state_bucket
        key                 = "stacks/${terramate.stack.id}/tofu.tfstate"
        region              = global.region
        encrypt             = true
        kms_key_id          = "arn:aws:kms:${global.region}:${global.account_id}:alias/${global.state_kms_alias}"
        use_lockfile        = true
        allowed_account_ids = [global.account_id]
      }
    }
  }
}

generate_hcl "_terramate_generated_provider.tf" {
  content {
    provider "aws" {
      region              = global.region
      allowed_account_ids = [global.account_id]

      default_tags {
        tags = global.default_tags
      }
    }
  }
}

generate_hcl "_terramate_generated_versions.tf" {
  content {
    terraform {
      required_version = global.opentofu_version

      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = global.aws_provider_version
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

# The state-backend stack of each account and region: bucket and key names come from the same globals as the backend.
generate_hcl "_terramate_generated_state_backend.tf" {
  condition = tm_contains(terramate.stack.tags, "state-backend")

  content {
    module "state_backend" {
      source = "${terramate.stack.path.to_root}/modules/state-backend"

      bucket_name    = global.state_bucket
      kms_alias_name = global.state_kms_alias
    }
  }
}

# Blocks `tofu destroy` (and `plan -destroy`) of whole stacks in protected accounts.
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
