# Project-wide globals. Directories below add to or override them (stacks/<account>/globals.tm.hcl: account_id, and protect_destroy: true adds a destroy guard to every stack of the account).
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
}

globals "default_tags" {
  ManagedBy   = "terramate"
  Project     = global.project
  Environment = global.account_name
}
