# Provider TFLint config. The terraform_tflint hook passes it with an absolute --config: TFLint never searches
# parent directories, and without it TFLint silently runs its default preset without the azurerm ruleset.
tflint {
  required_version = ">= 0.61.0"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

# No deep_check: this ruleset has none and calls no Azure API.
plugin "azurerm" {
  enabled = true
  # tflint requires a version here; `make update` sets the newest release.
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Terramate writes a `// TERRAMATE: GENERATED ...` header into every generated file.
rule "terraform_comment_syntax" {
  enabled = false
}

# Stacks and modules/state-backend lack some of main.tf, variables.tf and outputs.tf.
rule "terraform_standard_module_structure" {
  enabled = false
}

# Registry modules are pinned to one exact version and bumped in reviewed pull requests.
rule "terraform_module_version" {
  enabled = true
  exact   = true
}
