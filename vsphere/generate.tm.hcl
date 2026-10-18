# Code generated into every stack below this folder. Generated files are committed; run `make generate` after
# changing anything here or in a globals.tm.hcl. Only globals and relative paths are used.

assert {
  assertion = tm_can(tm_regex("^[a-z][a-z0-9-]*[a-z0-9]$", global.project))
  message   = "project must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit"
}

assert {
  assertion = tm_can(tm_regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", global.environment))
  message   = "environment (the folder name in stacks/<environment>/) must use lowercase letters, digits and hyphens, start with a letter and end with a letter or digit"
}

assert {
  assertion = tm_length("${global.project}-${global.environment}") < 80
  message   = "the VM folder name <project>-<environment> must be shorter than 80 characters (the vSphere entity name limit): shorten project"
}

assert {
  assertion = tm_can(tm_regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$", global.vsphere_server))
  message   = "vsphere_server (stacks/<environment>/globals.tm.hcl) must be the vCenter host name or IPv4 address in lowercase, optionally with :port, without scheme or path"
}

assert {
  assertion = tm_can(tm_regex("^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*$", global.gitlab_url))
  message   = "gitlab_url must be https://<host>[:port][/path] without a trailing slash"
}

assert {
  assertion = tm_can(tm_regex("^[1-9][0-9]*$", global.gitlab_project_id))
  message   = "gitlab_project_id must be the numeric GitLab project id, not the project path"
}

# GitLab-managed state, one per stack and named by the stack id. lock_method and unlock_method are required: OpenTofu's
# defaults (LOCK, UNLOCK) get GitLab's 405. Credentials come from TF_HTTP_USERNAME and TF_HTTP_PASSWORD only.
generate_hcl "_terramate_generated_backend.tf" {
  lets {
    state = "${global.gitlab_url}/api/v4/projects/${global.gitlab_project_id}/terraform/state/${terramate.stack.id}"
  }

  content {
    terraform {
      backend "http" {
        address        = let.state
        lock_address   = "${let.state}/lock"
        unlock_address = "${let.state}/lock"
        lock_method    = "POST"
        unlock_method  = "DELETE"
        retry_wait_min = 5
      }
    }
  }
}

# vsphere_server and allow_unverified_ssl set here beat VSPHERE_SERVER and VSPHERE_ALLOW_UNVERIFIED_SSL in the
# environment. Credentials come from VSPHERE_USER and VSPHERE_PASSWORD only.
generate_hcl "_terramate_generated_provider.tf" {
  content {
    provider "vsphere" {
      vsphere_server       = global.vsphere_server
      allow_unverified_ssl = false
    }
  }
}

generate_hcl "_terramate_generated_versions.tf" {
  content {
    terraform {
      required_version = global.opentofu_version

      required_providers {
        vsphere = {
          source  = "vmware/vsphere"
          version = global.vsphere_provider_version
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

# Binds every stack to the datacenter its folder names: stacks use data.vsphere_datacenter.this.id.
# ponytail: generated into every stack; tflint (terraform_unused_declarations) flags a stack that does not use it, such
# as a vCenter-wide tags stack: add a stack-tag condition here when the first one appears.
generate_hcl "_terramate_generated_datacenter.tf" {
  content {
    data "vsphere_datacenter" "this" {
      name = global.datacenter
    }
  }
}

# The folder stack of each environment and datacenter: <project>-<environment> stays unique when environments share
# a vCenter and a datacenter.
generate_hcl "_terramate_generated_folder.tf" {
  condition = tm_contains(terramate.stack.tags, "folder")

  content {
    resource "vsphere_folder" "vms" {
      path          = "${global.project}-${global.environment}"
      type          = "vm"
      datacenter_id = data.vsphere_datacenter.this.id
    }

    output "folder_path" {
      description = "VM folder path below the datacenter's vm folder: the folder argument of a VM, /<datacenter>/vm/<path> for data.vsphere_folder."
      value       = vsphere_folder.vms.path
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
