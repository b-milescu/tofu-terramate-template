# Project-wide globals. Directories below add to or override them (stacks/<environment>/globals.tm.hcl: subscription_id,
# state_contributor_principal_ids, and protect_destroy: true adds a destroy guard to every stack of the environment).
globals {
  # Prefix of the state storage account and resource group, and the Project tag. The RUNBOOK sets it.
  project                  = "example"
  opentofu_version         = ">= 1.12"
  azurerm_provider_version = ">= 5.0, < 6.0"

  # The folder names of stacks/<environment>/<region>/<stack>; the region folder is an Azure location name.
  environment = tm_split("/", terramate.stack.path.relative)[1]
  region      = tm_split("/", terramate.stack.path.relative)[2]

  # One state storage account per subscription and region, created by that region's state-backend stack. Account names are global,
  # 3-24 lowercase letters and digits: up to 10 characters of project without hyphens, "tfstate", then 6 hex digits of a hash of
  # project, subscription and region.
  state_storage_account = "${tm_substr(tm_replace(global.project, "-", ""), 0, 10)}tfstate${tm_substr(tm_sha256("${global.project}/${global.subscription_id}/${global.region}"), 0, 6)}"
  state_resource_group  = "rg-${global.project}-tfstate-${global.region}"
  state_container       = "tfstate"
}

# The azurerm provider has no default tags: every stack gets them as local.tags (generate.tm.hcl) and passes them on.
# Project is also part of the network resource group name (stacks/*/network/main.tf): editing this tag replaces the network.
globals "tags" {
  ManagedBy   = "terramate"
  Project     = global.project
  Environment = global.environment
}
