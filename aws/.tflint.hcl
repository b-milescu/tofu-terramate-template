# Provider TFLint config. The terraform_tflint hook passes it with an absolute --config: TFLint never searches
# parent directories, and without it TFLint silently runs its default preset without the aws ruleset.
tflint {
  required_version = ">= 0.61.0"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled    = true
  # tflint requires a version here; `make update` sets the newest release.
  version    = "0.49.0"
  source     = "github.com/terraform-linters/tflint-ruleset-aws"
  deep_check = false # deep checks call AWS APIs and need credentials
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

# Secrets must not land in state: flag secret attributes that have write-only variants and non-ephemeral secret lookups.
rule "aws_write_only_arguments" {
  enabled = true
}

rule "aws_ephemeral_resources" {
  enabled = true
}
