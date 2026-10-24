# Project-wide globals. Directories below add to or override them (stacks/<environment>/globals.tm.hcl: project_id, and protect_destroy: true adds a destroy guard to every stack of the environment).
globals {
  # Prefix of the state bucket and KMS key ring, and the project label. The RUNBOOK sets it.
  project                 = "example"
  opentofu_version        = ">= 1.12"
  google_provider_version = ">= 8.0, < 9.0"

  # The folder names of stacks/<environment>/<region>/<stack>.
  environment = tm_split("/", terramate.stack.path.relative)[1]
  region      = tm_split("/", terramate.stack.path.relative)[2]

  # One state bucket and KMS key per Google Cloud project and region, created by that region's state-backend stack.
  state_bucket       = "${global.project}-tfstate-${global.project_id}-${global.region}"
  state_kms_key_ring = "${global.project}-tfstate"
  state_kms_key      = "tfstate"
}

# Keys and values: lowercase letters, digits, underscores and hyphens (asserted in generate.tm.hcl).
globals "default_labels" {
  managed_by  = "terramate"
  project     = global.project
  environment = global.environment
}
