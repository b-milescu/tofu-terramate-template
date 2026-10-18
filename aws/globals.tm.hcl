# Project-wide globals. Directories below add to or override them (stacks/<account>/globals.tm.hcl: account_id).
globals {
  # Prefix of the state bucket and KMS alias, and the Project tag. The RUNBOOK sets it.
  project              = "example"
  opentofu_version     = ">= 1.12"
  aws_provider_version = ">= 6.0, < 7.0"

  # The folder names of stacks/<account>/<region>/<stack>.
  account_name = tm_split("/", terramate.stack.path.relative)[1]
  region       = tm_split("/", terramate.stack.path.relative)[2]

  # One state bucket and KMS key per account and region, created by that region's state-backend stack.
  state_bucket    = "${global.project}-tfstate-${global.account_id}-${global.region}"
  state_kms_alias = "${global.project}-tfstate"

  # true adds a destroy guard to every stack of an account (set in stacks/<account>/globals.tm.hcl).
  protect_destroy = false
}

globals "default_tags" {
  ManagedBy   = "terramate"
  Project     = global.project
  Environment = global.account_name
}
