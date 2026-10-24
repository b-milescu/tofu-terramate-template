# OpenTofu + Terramate on Azure

[OpenTofu](https://opentofu.org) for the code, [Terramate](https://terramate.io) for stacks, code generation and run order, [pre-commit](https://pre-commit.com) as the only check runner. `make help` lists the local entry points; coding agents read [AGENTS.md](AGENTS.md).

- A stack is a directory with a `stack.tm.hcl`: one OpenTofu root module with its own state.
- State lives in an Azure Storage account per subscription and region, over the `azurerm` backend with Microsoft Entra ID authentication: no account keys, no SAS tokens. One state blob per stack, named by the stack id; the lock is a lease on that blob.
- Shipped: the stacks `state-backend` and `network` for every environment and region (defaults: environments `dev` and `prod`, one Azure subscription each, region `germanywestcentral`; [Parameters](#parameters) changes them).
- Every check runs without cloud credentials. Nothing has been applied to a real Azure subscription (see [Not covered](#not-covered)); `make e2e` replays Bootstrap, Operate and Destroy against a local emulator ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)). Unless you replaced them, the subscription ids `11111111-1111-1111-1111-111111111111` and `22222222-2222-2222-2222-222222222222` and the principal ids `33333333-3333-3333-3333-333333333333` and `44444444-4444-4444-4444-444444444444` are placeholders. Replace them first: they feed the provider and backend pin, the state account names and the role assignments, and, unlike `allowed_account_ids` on AWS, nothing offline refuses a wrong subscription id.

## Layout

Tree with the default names:

```text
.pre-commit-config.yaml  .tool-versions  .tflint.hcl  .editorconfig  .gitattributes  .gitignore
.agents/skills/          terraform-skill copy (`make skill`)
.mcp.json                MCP servers for coding agents ([Agent tooling](#agent-tooling))
terramate.tm.hcl         root-only Terramate settings: version floor, telemetry off
globals.tm.hcl           project-wide globals
generate.tm.hcl          code generated into every stack
Makefile  Brewfile       local-dev entry points; toolchain for `make setup`
e2e.sh                   optional floci-az rehearsal (`make e2e`)
AGENTS.md  README.md     rules for coding agents; this file
modules/state-backend/   resource group, storage account, container, role assignments, lifecycle policy and lock for state; tests/ (mock provider); README.md filled by terraform-docs
stacks/
  dev/                   globals.tm.hcl: subscription_id, state_contributor_principal_ids, protect_destroy (the folder name is the environment)
    germanywestcentral/  the folder name is the region (an Azure location name)
      state-backend/     stack.tm.hcl (tag state-backend) + generated files
      network/           stack.tm.hcl, main.tf, outputs.tf + generated files
  prod/                  same shape; protect_destroy = true adds the destroy guard
```

An environment is one Azure subscription; the region folder is the location name in its short form (`germanywestcentral`, the `name` field of `az account list-locations`), not the display name.

Terramate always treats the git root as the project root, so the root-only settings in `terramate.tm.hcl` (`required_version`, `telemetry`, ...) only work in that file; `config.run.env` also works in subfolders.

Globals per level; lower levels add to or override higher ones:

| Level | File | Globals |
|---|---|---|
| project | [`globals.tm.hcl`](globals.tm.hcl) | `project`, `opentofu_version`, `azurerm_provider_version`, `environment` and `region` (the folder names of `stacks/<environment>/<region>/`), `state_storage_account`, `state_resource_group`, `state_container` and the map `tags` (`ManagedBy`, `Project` = `project`, `Environment` = `environment`); values are in the file |
| environment | `stacks/<environment>/globals.tm.hcl` | `subscription_id` (a lowercase GUID, asserted in `generate.tm.hcl`) and `state_contributor_principal_ids` (at least one lowercase GUID, asserted); `protect_destroy` (`true` for a protected environment, else `false`; required: a missing or misspelt key fails `make generate`) |
| stack | `stack.tm.hcl` | `stack {}`: `name`, `description`, `tags`, `after`, `id` |

`generate.tm.hcl` writes these files into every stack below it. They are committed and never edited by hand: change `generate.tm.hcl` or a globals file, run `make generate` and commit the result (the `terramate` hook runs `terramate generate` with `--detailed-exit-code` and fails when it had to write files). The `id` of a stack is assigned by `make generate` and is the state key.

| Generated file | Content | Written for |
|---|---|---|
| `_terramate_generated_backend.tf` | `backend "azurerm"`: `subscription_id`, `storage_account_name`, `container_name`, `key` = `stacks/<stack id>/tofu.tfstate`, `use_azuread_auth = true`; no credentials and no `tenant_id` | every stack |
| `_terramate_generated_provider.tf` | `provider "azurerm"`: `subscription_id` and an empty `features` block; no credentials | every stack |
| `_terramate_generated_versions.tf` | `required_version`, `required_providers`, `language { compatible_with }` | every stack |
| `_terramate_generated_locals.tf` | `locals`: `location` (the region) and `tags` (the `tags` global) | every stack |
| `_terramate_generated_state_backend.tf` | `module "state_backend"`; account, resource group and container names come from the same globals as the backend | tag `state-backend` |
| `_terramate_generated_destroy_guard.tf` | `terraform_data` resource with `prevent_destroy` | `protect_destroy = true` |

The azurerm provider has no default tags: a resource that takes `tags` passes `tags = local.tags`, and every location is `local.location` (no region literal in a `.tf`).

| Stack | Runs after | Content |
|---|---|---|
| `state-backend` | | the generated module call: resource group `rg-<project>-tfstate-<region>`, container `tfstate` and storage account `<project without hyphens, at most 10 characters>tfstate<6 hex digits>`, 15 to 23 characters; the digits are the start of `sha256("<project>/<subscription_id>/<region>")` |
| `network` | `../state-backend` | plain `azurerm` resources (exact in `main.tf`): resource group `rg-<project>-network-<region>`, virtual network `vnet-main`, network security group `nsg-private` with its default rules only, and the subnets `snet-app` and `snet-data` (one /24 each, `default_outbound_access_enabled = false`) associated with that group; outputs `vnet_id`, `subnet_ids` (name to id) and `network_security_group_id`; default CIDRs dev `10.10.0.0/16`, prod `10.20.0.0/16` |

`modules/state-backend`: resource group, storage account, container, role assignments, lifecycle policy and lock for state; behavior and inputs are documented in [its README](modules/state-backend/README.md).

## Prerequisites

```bash
make setup    # Brewfile packages (installed ones are kept), the OpenTofu and Terramate pins via tenv, the tflint ruleset, hook environments; ends with make doctor
make doctor   # one line per tool: ok, MISSING or WRONG; installs nothing, makes no network call, changes nothing in the project; any problem is a non-zero exit
make update   # hook revisions and the tflint ruleset to their newest releases (OpenTofu, Terramate and providers stay pinned); then review git diff, make check-all, commit
make hooks    # the git hooks (pre-commit, pre-push, commit-msg); run it after the first commit
```

- `make setup` needs [Homebrew](https://brew.sh) on macOS 15+ (Apple Silicon), Linux (x86_64 or arm64, glibc) or WSL2; on Linux and WSL first run `sudo apt-get update && sudo apt-get install -y build-essential procps curl file git unzip` (Homebrew's own requirements on Linux, plus `unzip` for the tflint cask). The first run needs network and takes minutes (downloads and caches: Homebrew formulae, `~/.tenv`, `~/.tflint.d`, the Go toolchain and Python packages of the hook environments in `~/.cache`, the azurerm provider in `~/.terraform.d/plugin-cache` (246 MB for darwin_arm64); the total was not measured for this folder); later runs work offline, except that trivy then scans with its embedded checks ([Not covered](#not-covered)).
- `make check`, `check-all`, `test` and `relock` export `TF_PLUGIN_CACHE_DIR` (default `~/.terraform.d/plugin-cache`, created) to share provider binaries across stacks and modules. Interactive `tofu` and `terramate run` commands need the export themselves, and so do the git hooks: `terraform_validate` on `git push` does not export it, so a fresh clone downloads the azurerm provider into every stack and module directory (5 here, about 245 MB each: about 1.2 GB; the download time was not measured). Put `export TF_PLUGIN_CACHE_DIR=$HOME/.terraform.d/plugin-cache` (and `mkdir -p "$TF_PLUGIN_CACHE_DIR"`) in your shell profile, or run `make check-all` once: it leaves `.terraform` in place. A directory without a lock file downloads the provider once even with a warm cache; locked inits reuse the cache.
- When the anonymous GitHub API quota (60 requests per hour per IP) is exhausted, run `TENV_GITHUB_TOKEN=<token> GITHUB_TOKEN=<token> make setup` (the same for `make update`): tenv ignores `GITHUB_TOKEN`, `tflint --init` downloads the azurerm ruleset from GitHub. Never print or commit tokens.
- Run `terramate` and `tofu` from the project root or below it: tenv finds the pins by walking up from the working directory (`terramate -C` from outside the project ignores them). A missing pinned tool makes the tenv shim exit 42: run `make setup`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, ...); the `commit-msg` hook enforces it.
- Optional: `export CHECKPOINT_DISABLE=1` stops Terramate's update check in interactive runs (the Makefile and the hooks set it).
- To operate ([Bootstrap](#bootstrap), [Operate](#operate)), not for the checks: the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`), which neither the Brewfile nor `make doctor` knows, and HTTPS to Microsoft Entra ID (`login.microsoftonline.com`), Azure Resource Manager (`management.azure.com`, from Microsoft's documentation) and the blob endpoint of each state account (`<account>.blob.core.windows.net`). Only the Azure public cloud is covered: the generated blocks set no `environment` and no `metadata_host`. The provider and the backend both use `HTTPS_PROXY` and `NO_PROXY` (observed through the rehearsal's dead proxy). The Azure CLI 2.90.0 was the version at hand when its authentication paths were examined, with a stub and an empty config dir, never against Azure.

| Tool | Version | Provided by |
|---|---|---|
| OpenTofu, Terramate | pinned in `.tool-versions`; `terramate.tm.hcl` sets the Terramate floor | installed by tenv |
| pre-commit | 4.4.0 or newer (4.7.0 verified) | brew |
| tflint | 0.61.0 or newer (0.61.0 verified); the azurerm ruleset version in `.tflint.hcl` (tflint requires one; it needs TFLint 0.46 or newer), newest via `make update` | the `terraform-linters/tap/tflint` cask; the ruleset is fetched by `tflint --init` |
| trivy, terraform-docs, tenv, terraform-mcp-server | newest at install (0.76.0, 0.24.0, 4.15.1, 1.3.0 verified) | brew |
| checkov | Homebrew's current formula: 3.3.30 on 2026-10-24, the version the files of this folder were checked with (from PyPI through `uvx`: the verifying Mac had no Homebrew checkov); the formula can lag PyPI. The `terraform_checkov` hook runs the system binary | brew |
| gitleaks | newest hook release (`make update`) | built by pre-commit on first use |
| Azure CLI | not provided: only needed to operate | yours |

## Make targets

`make help` lists the targets. `check`, `check-all` and `test` stop with "untracked files are not checked" and list up to five of them while git shows untracked files: `git add -A` them or gitignore them. Hooks only see tracked files: pre-commit skips an untracked one and still exits 0. `make e2e` is not part of `check-all`: it runs on macOS with Docker Desktop only and takes minutes ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)).

In the template repository (this folder lies inside another repository's work tree, so it is not a project: a project is its own git repository), `check`, `check-all`, `test` and `e2e` print `template checkout: running <target> in a throwaway project` and run in a copy of the tracked and unignored files in a scratch git repository (`make generate`, then the target), removed on every exit, Ctrl-C included; they need no `git add`. What the hooks rewrote or created in the copy is applied to the checkout as one patch (review `git diff` and `git status`, then rerun); stack ids and generated files never come back, a patch that does not apply is printed on stderr instead, and the exit code is the target's. `generate`, `relock`, `skill` and `hooks` refuse there (`this folder is a template inside <path>`); a project copied into a subfolder of another repository gets the same treatment: `git init` it.

## Parameters

The wizard of the template's RUNBOOK.md (a checkout of the template; its commit is in the first line of this file) asks these rows once; they are also the guide for later edits. Paths are relative to the project root.

| Parameter | Default | Rule | How to change (project-root paths) |
|---|---|---|---|
| project | basename of the target directory, lowercased, every run of other characters → `-`, trimmed; if the result breaks the rule: ask | `^[a-z][a-z0-9-]*[a-z0-9]$` and `len(project) + len(region) <= 78`, so that the resource group names `rg-<project>-tfstate-<region>` and `rg-<project>-network-<region>` (12 characters plus both) stay within Azure's 90 (both asserted by generate.tm.hcl); unique among your projects in the same subscription and region (the resource group names collide otherwise). The storage account name is global: apply fails when another tenant already owns it (not evaluated) | `project` in `globals.tm.hcl`, then `make generate` |
| environments | `dev` (subscription `11111111-1111-1111-1111-111111111111`, principal `33333333-3333-3333-3333-333333333333`), `prod` (`22222222-2222-2222-2222-222222222222`, `44444444-4444-4444-4444-444444444444`) — placeholders: replace them, nothing offline refuses them | name `^[a-z][a-z0-9-]{0,19}$`, unique; `subscription_id` a GUID in lowercase (asserted), distinct per environment: it is a Subscription ID (`az account list --query "[].id" -o tsv`); `state_contributor_principal_ids` at least one lowercase GUID (asserted): the Entra ID object ids (not application ids) of the people and service principals that run `terramate run`, the identity that bootstraps included ([Bootstrap](#bootstrap), [Deployer RBAC](#deployer-rbac)) | per environment `stacks/<name>/globals.tm.hcl` (`subscription_id`, `state_contributor_principal_ids`; the folder name is the environment name). Rename: `mv stacks/<old> stacks/<new>`; add: copy `stacks/<existing>` to `stacks/<new>` (once `make generate` has run, delete the copied `id = ...` lines in its `stack.tm.hcl` files, recipe in [Grow the tree](#grow-the-tree)), set its `subscription_id` and `state_contributor_principal_ids`, give it a new `vnet_cidr`, `make generate`; remove: delete `stacks/<name>` |
| protect_destroy | `true` for environments whose name starts with `prod`, else `false` | boolean, set in every environment | `protect_destroy = true` or `false` in `stacks/<name>/globals.tm.hcl` |
| region | `germanywestcentral` (all environments) | `^[a-z][a-z0-9]+$`, an Azure location name as `az account list-locations --query "[].name" -o tsv` prints it, not the display name (asserted by generate.tm.hcl). That the location exists and is open to the subscription (storage SKUs, quota) no offline check can tell: always tell the user to confirm it with that command (their credentials) before the first plan; the state account is `GRS`, which needs a region with a pair, and Microsoft Learn lists regions without one (for example Poland Central, Italy North, Spain Central): there the module needs `ZRS` and an inline checkov skip for `CKV_AZURE_206` in `modules/state-backend/main.tf` | per environment `mv stacks/<environment>/germanywestcentral stacks/<environment>/<region>` (the folder name is the region; no `.tf` holds a region literal) |
| VNet CIDR | `10.10.0.0/16` (dev), `10.20.0.0/16` (prod), then `10.30.0.0/16`, ... | `^10\.[0-9]{1,3}\.0\.0/16$`, distinct | `vnet_cidr` in each `network/main.tf` |
| Azure provider | keep the locked 5.11.0 (verified) | `keep` or `latest` (newest 5.x: `curl -fsS https://registry.opentofu.org/v1/providers/hashicorp/azurerm/versions`); the constraint `>= 5.0, < 6.0` stays | `latest`: `make relock` after `make generate` |

Version pins of OpenTofu and Terramate are generic (step 2 of the template's RUNBOOK): `.tool-versions` lines `opentofu X.Y.Z` / `terramate X.Y.Z`; Terramate also `required_version = "~> X.Y.Z"` in `terramate.tm.hcl`; rule `^[0-9]+\.[0-9]+\.[0-9]+$`, OpenTofu >= 1.12.0.

Derived by `make generate` (the RUNBOOK shows them back): per environment and region the state resource group `rg-<project>-tfstate-<region>`, the container `tfstate` and the storage account `<project without hyphens, at most 10 characters>tfstate<6 hex digits>`. Before generating, print the digits with `printf '%s' '<project>/<subscription_id>/<region>' | shasum -a 256 | cut -c1-6` (`sha256sum` on Linux); for the shipped placeholders that gives `exampletfstate65dc31` (dev) and `exampletfstatea6dac3` (prod), the names `make generate` writes (checked in a scratch copy).

Placeholder values the RUNBOOK leftover scan looks for: `example`, `11111111-1111-1111-1111-111111111111`, `22222222-2222-2222-2222-222222222222`, `33333333-3333-3333-3333-333333333333`, `44444444-4444-4444-4444-444444444444`, `germanywestcentral`.

## Checks

`.pre-commit-config.yaml`, in execution order. "Both" means pre-commit and pre-push: the fast set re-runs at push to catch `git commit --no-verify`. `make check` runs the commit stage on every tracked file, `make check-all` both stages.

| Hook id | Source | Stage | Checks |
|---|---|---|---|
| `check-added-large-files`, `check-merge-conflict`, `check-yaml`, `end-of-file-fixer`, `mixed-line-ending` (lf), `trailing-whitespace` | pre-commit-hooks | both | hygiene; `check-added-large-files` runs with `--enforce-all` and `check-merge-conflict` with `--assume-in-merge` so both also work under `--all-files`; the three fixers skip the skill copy (`.agents/skills/`) |
| `gitleaks` | gitleaks | both | secrets in the staged changes (blind under `--all-files`) |
| `gitleaks-history` | gitleaks | pre-push | secrets in every commit (`gitleaks git --redact --verbose`), runs even when no file survives |
| `conventional-pre-commit` | conventional-pre-commit | commit-msg | Conventional Commits message |
| `terramate` | local | both | `terramate fmt`, `generate`, `list --run-order`: fails on rewritten `.tm.hcl`, stale or hand-edited generated files, duplicate stack ids, `after` cycles or typos, failed asserts (project name, subscription id, principal ids, region, state account name, resource group name length), a stack without `_terramate_generated_{backend,provider,versions,locals}.tf`; prints `hint: run "make generate"` when a stack has no id |
| `generated-versions` | local (pygrep) | both | generated versions still has the top-level `language { compatible_with { opentofu = ... } }` gate (OpenTofu ignores `required_version` in `.tf` files) |
| `generated-backend` | local (pygrep) | both | generated backend still has, line-anchored, a lowercase-GUID `subscription_id`, `use_azuread_auth = true` and `key = "stacks/<uuid>/tofu.tfstate"`, and none of `tenant_id`, `access_key`, `sas_token`, a `client_*`, `oidc_*` or `msi_*` attribute, `use_msi`, `use_cli`, `use_oidc`, `environment` or `metadata_host` |
| `generated-provider` | local (pygrep) | both | generated provider still has a lowercase-GUID `subscription_id` (line-anchored) and `features {`, and none of a `client_*`, `oidc_*` or `msi_*` attribute, `use_msi`, `use_cli`, `use_oidc`, `environment` or `metadata_host` |
| `forbidden-files` | local | both | rejects state files, plans, crash logs, `.terraform/`, `.tofu`, `.tofu.json` and `.tofutest.hcl` files and override files (`override.tf`, `*_override.tf`, `.json` forms): they silently replace the generated backend, provider and destroy guard |
| `module-prevent-destroy` | local (pygrep) | both | `modules/state-backend/main.tf` still has 3 `prevent_destroy = true` lines (resource group, account and container): `tofu test` cannot see lifecycle arguments; lower the count only in a reviewed change that removes a guard on purpose, never just to pass the hook |
| `tofu-test` | local | pre-push | `tofu test` in every module with mock providers; fails when a module has no tests, runs none, or leaves `errored_test.tfstate` |
| `terraform_fmt` | pre-commit-terraform | both | `tofu fmt` |
| `terraform_providers_lock` | pre-commit-terraform | both | every provider in every lock file has at least as many `h1:` hashes as configured platforms (darwin and linux, amd64 and arm64) and a `zh:` hash; it counts hashes, it does not check which platforms they belong to (offline) |
| `terraform_tflint` | pre-commit-terraform | both | tflint with preset `all`, the azurerm ruleset and exact registry-module versions; the ruleset has no deep check and no write-only or ephemeral-resource rules |
| `terraform_docs` | pre-commit-terraform | both | regenerates `modules/*/README.md` between the `BEGIN_TF_DOCS` and `END_TF_DOCS` markers |
| `terraform_validate` | pre-commit-terraform | pre-push | `tofu validate`, serially, in every directory under `make check-all` and in the directories of changed files on a push; a directory without `.terraform` first gets `tofu init -backend=false -lockfile=readonly`, so the stacks' azurerm backend is never contacted (it exports no `TF_PLUGIN_CACHE_DIR`: see [Prerequisites](#prerequisites)); validate needs no credentials and no placeholder variables for the generated provider block |
| `terraform_trivy` | pre-commit-terraform | both | `trivy config`, MEDIUM and above, `.terraform` and downloaded registry-module internals excluded: once at the project root under `make check` and `check-all`, per directory of changed files on a commit or push; the three `#trivy:ignore` above the state storage account carry their reasons (`grep -rn 'trivy:ignore' .`) |
| `terraform_checkov` | pre-commit-terraform | pre-push | the Homebrew checkov, terraform framework, `--skip-download`: once at the project root under `check-all`, inside each directory of changed files on a push; `CKV_TF_1` is skipped in the hook, every other skip is an inline `#checkov:skip` with a reason (`grep -rn checkov:skip .`) |

- A hook that rewrites files (`end-of-file-fixer`, `mixed-line-ending`, `trailing-whitespace`, `terraform_fmt`, `terraform_docs`, `terramate`) fails the run: review the change, `git add` it, run again. `terramate fmt` formats `*.tm.hcl` files up front: run it after editing one by hand.
- `trivy` and `checkov` are system tools: they must be on the `PATH` of whatever runs git (no hook environment builds them; a GUI git client or a minimal CI image often lacks Homebrew's `bin`). Missing: `checkov: command not found` (exit 127) or `'trivy' is required by 'terraform_trivy' pre-commit hook but it is not discoverable in the system's PATH`. `make doctor` finds both.
- Network use of the pre-commit-terraform hooks: trivy fetches its checks bundle from `mirror.gcr.io` at most once a day and still runs offline, with its embedded checks ([Not covered](#not-covered)); checkov (the hook sets `CKV_SKIP_PACKAGE_UPDATE_CHECK=true`) makes no request. `tofu validate`, `tofu test` and `tofu init -backend=false` ran in a container without network (azurerm 5.11.0 installed beforehand, OpenTofu 1.13.1) and made no `az` call and no request to the instance metadata address (a logging `az` stub and a listener on 169.254.169.254 saw none); nothing enforces that they stay so.
- `make check`, `check-all`, `test`, `relock` and `doctor` unset every `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `MSI_*`, `IDENTITY_*`, `ACTIONS_ID_TOKEN_REQUEST_*`, `GOOGLE_*`, `GCLOUD_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `TF_HTTP_*`, `TF_VAR_*` and `GITLAB_*` variable, plus `SYSTEM_ACCESSTOKEN`, `CI_JOB_TOKEN`, `CI_JOB_JWT`, `CI_JOB_JWT_V2`, `CI_REGISTRY_PASSWORD`, `TF_ENCRYPTION`, `TENV_GITHUB_TOKEN`, `GH_TOKEN` and `HOMEBREW_GITHUB_API_TOKEN` (not `GITHUB_TOKEN`: `terraform_tflint` runs `tflint --init`, which reads it), before pre-commit, tflint, tofu or a provider binary starts. `ARM_*` variables select an Azure identity on their own (a client secret, a managed identity, OIDC: observed with a stubbed az), and the provider also reads `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_FEDERATED_TOKEN_FILE`; `MSI_*`, `IDENTITY_*`, `ACTIONS_ID_TOKEN_REQUEST_*` and `SYSTEM_ACCESSTOKEN` did nothing alone in the same test (azurerm 5.11.0, OpenTofu 1.13.1) and are scrubbed as defence in depth. Variables only: a login cached in a config dir (`~/.azure`, `~/.aws`, gcloud, `~/.govmomi`) is not isolated; only the `tofu-test` hook points `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `GOOGLE_APPLICATION_CREDENTIALS` at `/dev/null` and the az, azd and gcloud config dirs at an empty temp dir (with the real config dir of a logged-in `az`, `az account show` succeeds; with an empty one it fails with `Please run 'az login'`). The git hooks that `make hooks` installs run with the environment of the process that runs git; inside them only `tofu-test` scrubs itself. trivy and checkov only read files. The prefix list must stay in step in the Makefile `SCRUB` (`INSTALL_HOOKS` uses it too), the `tofu-test` hook and `e2e.sh`.

### Disabled tools

| Tool | Reason | Instead |
|---|---|---|
| `terraform_tfsec` | deprecated | `terraform_trivy` |
| `terrascan` | archived 2025-11 | `terraform_trivy`, `terraform_checkov` |
| `terraform_docs_replace`, `terraform_docs_without_aggregate_type_defaults` | deprecated or duplicate | `terraform_docs` |
| `infracost_breakdown` | needs an Infracost API key and network | none |
| `tfupdate` | stack constraints are Terramate globals; module pins are bumped in reviewed pull requests | [Upgrades](#upgrades) |
| `terraform_wrapper_module_for_each` | for module-publisher repositories | none |
| `terragrunt_*` | Terramate is the orchestrator | none |
| terramate-io/pre-commit-hooks | run bare commands at the git root; pass when generated files are missing | local `terramate` |
| `detect-private-key` | gitleaks covers it | `gitleaks` |
| yamllint, markdownlint, typos | style only (`check-yaml` covers YAML syntax) | none |
| shellcheck | `e2e.sh` is the only shell file and is optional (`make e2e`) | none |
| `deep_check` of the azurerm tflint ruleset | the ruleset has no such argument (`An argument named "deep_check" is not expected here`) and calls no Azure API | none |
| the tflint rule `azurerm_resource_missing_tags` | off by default; enabled it flagged `tags = var.tags` inside a module (observed): the tags come from the generated `local.tags`, and `AGENTS.md` makes passing them a rule | review |

## CI contract

No pipeline file ships (the forge is undecided). After `make setup` (the runner needs `trivy` and `checkov` on its `PATH`), a pipeline gates on exactly this, with `SKIP` unset, a full clone (history scan), `GITHUB_TOKEN` exported for `tflint --init`, and network for the first downloads (later runs work offline: [Checks](#checks)):

```bash
make check-all
git diff --exit-code
test -z "$(git status --porcelain)"
```

- `check-all` is one run of the pre-push stage, which holds every commit-stage hook too (`default_stages`). A bare `pre-commit run --all-files` would skip the push-only hooks, `gitleaks-history` among them (`gitleaks` only sees staged changes).
- The last two commands catch rewrites and new untracked files (READMEs) that a hook can create while still reporting success.
- This is the only authoritative gate. `--no-verify`, `SKIP` and a missing `make hooks` bypass the local hooks, and deletion-only commits skip every file-based hook (only `gitleaks-history` always runs).
- Plan and apply need credentials and are out of scope for the template; the runbook is under [Operate](#operate). A pipeline that runs them authenticates a service principal or a federated identity through the `ARM_*` variables (with `ARM_USE_OIDC=true` and, on GitHub, the `ACTIONS_ID_TOKEN_REQUEST_*` variables of the job), not `az login` ([Bootstrap](#bootstrap) lists what each variable does; `make check-all` scrubs all of them); that was never tried against Microsoft Entra ID.

## Agent tooling

Project scope: instructions in [AGENTS.md](AGENTS.md); MCP servers in `.mcp.json`, read as is by Claude Code and omp (verified) and, per their documentation, by GitHub Copilot, VS Code and Devin; the skill `terraform-skill` ([Skill](#skill)).

| Server | Gives the agent | Where it runs | Credentials |
|---|---|---|---|
| `terraform-registry` | Terraform registry lookups: provider and module versions, resource schemas, docs (9 read-only tools) | local binary | none |
| `microsoft-learn` | Microsoft Learn documentation search, code-sample search and page fetch: Azure services, limits, roles, naming rules (3 lookup tools: `microsoft_docs_search`, `microsoft_code_sample_search`, `microsoft_docs_fetch`) | remote: `https://learn.microsoft.com/api/mcp`, hosted by Microsoft | none |

`microsoft-learn` is a remote server hosted by Microsoft: no Azure account and no authentication (its `initialize`, `tools/list` and a search call answered without any; Microsoft Learn MCP Server 1.0.0, protocol 2025-06-18), under Microsoft's terms and any rate limits (not evaluated). Every session start your harness connects to it (`initialize`, `tools/list`: nothing from your project); afterwards only what the agent puts into a tool call leaves your machine: search phrases, documentation URLs, code-sample queries. Do not paste secrets, subscription or tenant ids or resource names into queries. The pages it returns are text written by Microsoft that the agent reads: documentation, not instructions. Not every harness reads `.mcp.json` or supports remote servers: add the entries to its own MCP config by hand (`microsoft-learn` as a remote Streamable HTTP server without authentication) and keep it in step with `.mcp.json`.

The provider namespace is `hashicorp`: `get_latest_provider_version` answered 5.11.0 for `hashicorp/azurerm` and `search_providers` served the `storage_account` resource documentation of that version (terraform-mcp-server 1.3.0). The server queries registry.terraform.io, not registry.opentofu.org: both listed the same azurerm versions when compared (412 each), but they serve different builds of a release ([Design decisions](#design-decisions), 9).

Why the `terraform-registry` command looks like this: `--toolsets=registry` keeps the 9 read-only registry tools (without it a TFE token in `~/.terraform.d/credentials.tfrc.json` exposes 56 tools, 19 of them without a read-only hint); `env -u TFE_TOKEN -u TFE_ADDRESS HOME=/nonexistent` stops the binary from reading and sending that token, and makes it log `failed to create TFE client ... /nonexistent` to stderr on every start: by design, not a failure.

Cloud API access (an `az` session, a service principal, a token) is not shipped: every entry above is lookup-only and credential-free. If you add a credentialed server yourself, keep it out of `.mcp.json` in the repository.

- Review changes to `.mcp.json`, `.agents/`, `AGENTS.md`, `.claude/settings.json` and harness files like code: omp, OpenCode and Devin start project MCP servers without asking, and Claude Code does too in `-p` mode and when `enableAllProjectMcpServers` is set in a user settings file or a committed `.claude/settings.json`.
- The template's RUNBOOK may add `CLAUDE.md` (`@AGENTS.md`) for Claude Code and the skill link ([Skill](#skill)).
- A user-level MCP server with the same name (for example `terraform-registry`) is never overwritten: Claude Code uses the project entry after you approve it (until then yours); omp uses yours when any config it imports defines the name (its own `~/.omp/agent/mcp.json`, Claude Code's `~/.claude.json`, Cursor's `~/.cursor/mcp.json`, ...): the project `.mcp.json` ranks last there.

### Skill

`terraform-skill` ([upstream](https://github.com/antonbabenko/terraform-skill), Anton Babenko) is not pinned: `make skill` installs and updates it from the upstream default branch, and the RUNBOOK runs it once at creation. The copy lives in `.agents/skills/terraform-skill` and is committed, so teammates need nothing.

| Harness | How it finds the skill | Invoke as |
|---|---|---|
| Claude Code | the link `.claude/skills/terraform-skill` to the copy | `/terraform-skill` |
| omp | reads `.agents/skills` | `/skill:terraform-skill` |
| Other harnesses | most read `.agents/skills` (per their documentation, not run here) | `/terraform-skill` or by description |

`make skill` replaces `.agents/skills/terraform-skill` (the folder, its `LICENSE` and a one-line `SOURCE` naming the upstream commit) from a fresh clone of the upstream default branch and always verifies TLS, whatever your git config says. It prints `terraform-skill at <sha>` and `review "git status" and "git diff -- .agents/skills", then commit`; when `SOURCE` already names the upstream commit it prints only `terraform-skill already at <sha>` and changes nothing.

- Before replacing, it refuses while git shows uncommitted changes under the folder, untracked files included: `has uncommitted changes: commit or discard them first`. Discard with `git reset -q -- .agents/skills/terraform-skill && git checkout -- .agents/skills/terraform-skill && git clean -fd -- .agents/skills/terraform-skill` (a copy that was never committed: `rm -rf` it after the `git reset`). Committed edits are replaced without a warning and show as a revert in `git diff`: keep project rules in `AGENTS.md`, not in the copy.
- Copy a project with `git clone` or `COPYFILE_DISABLE=1 tar`: macOS `tar` and Finder zips add AppleDouble `._*` files inside the folder, which git shows as untracked files.
- A user-level `terraform-skill` (`~/.claude/skills`, `~/.agents/skills`) may be listed next to the project's.

## Bootstrap

Once per subscription and region, with an identity that may create the state resources ([Deployer RBAC](#deployer-rbac)): it creates the resource group, the storage account and its container, the role assignments, the lifecycle policy and the lock. Until the storage account exists every other stack of that subscription and region fails at `tofu init`. Use plain `tofu` here: the generated azurerm backend points at a container that does not exist yet, so a gitignored `backend_override.tf` swaps in local state for the first apply. Not evaluated: nothing below ran against a real Azure subscription (the emulator rehearsal covers the apply sequence, [End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)).

**Before the first apply**

1. Sign in with `az login`. The provider and the backend take their token from the az session (the CLI is the default method of both), and the subscription comes from the generated blocks, whatever `az account set` or `ARM_SUBSCRIPTION_ID` say (a value in code beats both: observed with a stubbed az). The session must list the environment's subscription: `az account list --query "[].id" -o tsv`.
2. Set the real `subscription_id` and `state_contributor_principal_ids` in `stacks/<environment>/globals.tm.hcl`, run `make generate` and commit: the placeholder ids are baked into the committed generated files, the state account name derives from the subscription id, and plain `tofu` has no outdated-code safeguard. The list must hold the object id of the identity that runs this bootstrap (`az ad signed-in-user show --query id -o tsv` for yourself): Owner and Contributor carry no blob data actions and the account has no keys, so without the role the migration below is refused.
3. Register the resource providers once per subscription: `az provider register --namespace Microsoft.Storage --subscription <subscription_id>` and the same for `Microsoft.Network`, then wait until `az provider show --namespace <namespace> --subscription <subscription_id> --query registrationState -o tsv` prints `Registered`. azurerm 5.x registers nothing itself: `resource_provider_registrations` defaults to `none` (its 5.0 upgrade guide), and the generated provider does not set it.
4. The identity needs Owner on the subscription, or Contributor plus User Access Administrator. Contributor alone cannot write role assignments (`Microsoft.Authorization/*/Write` is one of its NotActions); Role Based Access Control Administrator writes role assignments only, and creating or deleting the lock needs `Microsoft.Authorization/locks/*`, which Owner and User Access Administrator, among others, carry (Microsoft Learn, not evaluated against a subscription).

```bash
cd stacks/<environment>/<region>/state-backend
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
tofu init
tofu plan -out=tfplan     # review
tofu apply tfplan && rm backend_override.tf   # a failed apply keeps the override, so the next line cannot overwrite an existing state
tofu init -migrate-state -force-copy   # a 403 here: the role assignment has not taken effect yet, wait and rerun
tofu plan -detailed-exitcode && [ ! -e backend_override.tf ] && rm -f terraform.tfstate* tfplan   # the local state goes only after the migration and a clean plan (exit code 0)
```

- git cannot show a forgotten `backend_override.tf` (it is ignored): check that it is gone. Never commit it: the `forbidden-files` hook rejects tracked override files, which would silently replace the generated backend.
- Role assignments can take up to 10 minutes to take effect (Microsoft Learn): until then the migration may fail with 403 from the blob endpoint (expected, not observed). Wait and rerun the same command. Stop on any other failure: the local state is the only record of the resource group, account and container.
- The stack now keeps its own state in the container it created. `prevent_destroy` on the resource group, account and container and the CanNotDelete lock on the account make decommissioning a deliberate change ([Operate](#operate)).
- Then initialise the other stacks: `cd stacks/<environment> && terramate run -- tofu init`.

**Credentials**

They come from the az session or from `ARM_*` variables in the shell, never from a file of the project, and the generated blocks carry none (the hooks fail on any). Which identity acts is decided by what the shell exports, so look before every plan. What each setting did in a test with a stubbed `az`, no network, azurerm 5.11.0 and OpenTofu 1.13.1 (the backend's order is also read from its source; the quoted az error is the real az 2.90.0's, run with an empty config dir; none of it ran against Microsoft Entra ID):

| In the shell | Effect |
|---|---|
| nothing below, `az login` done | provider and backend run `az account get-access-token`; no other credential is read |
| `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` | provider and backend use that service principal and ignore the az session |
| `ARM_USE_MSI=true` | a managed identity beats the CLI |
| `ARM_ACCESS_KEY` or `ARM_SAS_TOKEN` | the backend uses the key or token instead of Entra ID, before any other method (`use_azuread_auth = true` does not stop it, and the generated block sets neither argument). The account refuses requests signed with an account key (SAS tokens that rely on one included), so they fail with 403 (Microsoft Learn, not evaluated) instead of working |
| `ARM_TENANT_ID` next to `az login` | the backend's token request carries tenant and subscription and az 2.90.0 answers `ERROR: Please specify only one of subscription and tenant, not both`: unset it (a service principal needs it). The provider block may carry both |
| `ARM_SUBSCRIPTION_ID` | ignored: the generated `subscription_id` wins in the provider and in the backend |
| `ARM_ENVIRONMENT`, `ARM_METADATA_HOST` (backend), `ARM_METADATA_HOSTNAME` (provider) | the generated blocks set neither `environment` nor `metadata_host`, so a stray export points the backend or the provider at another cloud or endpoint. The backend reads `ARM_METADATA_HOST` and the provider `ARM_METADATA_HOSTNAME`, so an `ARM_METADATA_HOSTNAME` left over from the e2e setup (`e2e.sh` exports it) redirects only the provider. Unset them: only the Azure public cloud is covered (read from the OpenTofu 1.13.1 backend source and the azurerm documentation, not run) |

Failures to expect (texts marked observed were seen in the sandbox above; the others follow from Microsoft's documentation or the source and were not evaluated):

| Message | Cause |
|---|---|
| `Error: No valid azure auth methods found` at `init`, after diagnostics that include `Error using the az command ... Please run 'az login'` (observed) | `az` is not logged in |
| `Error looking for command az in your PATH` (observed) | `az` is not installed and no other method is configured |
| `ERROR: Please specify only one of subscription and tenant, not both` inside the backend's error (observed with az 2.90.0) | `ARM_TENANT_ID` exported next to `az login` (table above) |
| `the provided subscription ID "<id>" is not known by Azure CLI` at `plan` (observed) | the az session does not list the pinned subscription: a placeholder id, or another login |
| HTTP 403 from the blob endpoint at `init` | the identity lacks Storage Blob Data Contributor on the state resource group, or the assignment has not taken effect yet (up to 10 minutes), or `ARM_ACCESS_KEY` or `ARM_SAS_TOKEN` is exported |
| `Error acquiring the state lock`, `state blob is already locked` (observed on emulators) | a lock is held ([Operate](#operate)) |
| `An argument named "<name>" is not expected here` at `init` (observed) | a backend generator error: `validate` never reads the backend block |

## Operate

Run from `stacks/<environment>`, signed in with `az login` or with that environment's service principal or managed identity in the `ARM_*` variables ([Credentials](#bootstrap) in Bootstrap): the identity in your shell belongs to that environment, and `terramate run` at the project root would span every environment with it. Export `TF_PLUGIN_CACHE_DIR` first ([Prerequisites](#prerequisites)).

```bash
cd stacks/<environment>
terramate run -- tofu init                                       # first time, and after lock or provider changes
terramate run --no-tags state-backend -- tofu plan -out=tfplan   # then read every stack's plan
terramate run --no-tags state-backend -- tofu apply tfplan       # applies exactly the reviewed plans
```

- Routine runs leave `state-backend` out. Plan and apply it only with the bootstrap identity ([Deployer RBAC](#deployer-rbac)) (`terramate run --tags state-backend -- ...`, same plan-then-apply flow), when `modules/state-backend` or its globals change; adding or removing a principal in `state_contributor_principal_ids` is such a change.
- Never `-auto-approve`. A stale or already applied plan is refused.
- `-detailed-exitcode` is unusable under `terramate run`: exit code 2 counts as failure.
- Safeguards stay on: `terramate run` refuses an uncommitted or untracked tree, outdated generated code and a checkout behind its remote (if you add an `origin`, push `main` to it before the first `terramate run`: the git safeguard calls `git ls-remote`; without a remote the check is skipped). Do not use `-X`; `tfplan` is gitignored, so it does not trip them.
- A run that died (closed terminal, timeout) leaves its lock: the state blob holds a lease without an end, and the next run in that stack stops with `Error acquiring the state lock`, `state blob is already locked` and a `Lock Info:` block (`ID`, `Path`, ...). First make sure no other run holds it: ask whoever the block names and check your pipeline. Then, in that stack's directory with the environment's credentials, run `tofu force-unlock <LOCK_ID>` with the `ID` from the message and answer `yes`; a wrong id is refused (`does not match existing lock`) and the lock stays. The held-lock refusal is a step of `make e2e`; `force-unlock` is not: `tofu force-unlock -force` was tried on floci-az and on Azurite while the rehearsal was designed; nothing of it ran against Azure. No `Lock Info:` block (the error ends `blob metadata "terraformlockid" was empty`): the lease was taken but its metadata is missing, so `force-unlock` cannot work; after the same check that no other run holds it, break the lease: `az storage blob lease break --auth-mode login --account-name <account> --container-name tfstate --blob-name stacks/<stack id>/tofu.tfstate` (read from the OpenTofu 1.13.1 source and `az` help; not run against Azure). Never `-lock=false` as a way around it.
- History: the account keeps blob versions (versioning on) and soft-deletes blobs and containers for 30 days; the lifecycle policy deletes versions 90 days after their creation. A state write creates a version, and so does every lock and unlock: the backend sets the lock metadata on the state blob and clears it again, and Microsoft Learn lists Set Blob Metadata among the writes that create a version. Not every version is a state write, then, and every plan leaves versions: tell the state from before an apply by time and content. Read them in the Azure portal or with the Blob service REST API (not run).

Destroy, only after the destroy plan was shown and confirmed:

```bash
terramate run --no-tags state-backend --reverse -- tofu plan -destroy -out=tfplan   # read every resource it deletes
terramate run --no-tags state-backend --reverse -- tofu apply tfplan
```

- Protected environments (`protect_destroy = true`, prod by default): `tofu destroy` and `plan -destroy` fail with `Resource instance cannot be destroyed`. Flip `protect_destroy` in a reviewed pull request and run `make generate` (the guard files disappear in the diff) before planning the destroy; when the work is done, revert the flip and run `make generate` in a second reviewed pull request. The guard protects a stack only once an apply has created it: after turning `protect_destroy` on for live stacks, or reverting a flip, apply that environment before relying on it. Limit: `-target` and `-exclude` plan destroys past the guard. OpenTofu 1.13 prints `-exclude="terraform_data.destroy_guard"` in the refusal itself: do not follow that hint.
- `state-backend` stays out of the destroy (`--no-tags state-backend` above): `prevent_destroy` on its resource group, account and container makes its destroy plan fail, and removing the guard is a code change in the module (and in the `module-prevent-destroy` count). The lock `cannot-delete-state` on the account is the second guard, against everything that bypasses OpenTofu: while it exists, Azure Resource Manager refuses to delete the account, its container and its policy. Remove it first (it is the module's `azurerm_management_lock.state`; a role with `Microsoft.Authorization/locks/*`: Owner and User Access Administrator, among others) before decommissioning. It does not cover the blobs: data-plane deletes and writes are not blocked by a lock (Microsoft Learn), versioning and soft delete are the net there.

## End-to-end rehearsal (`make e2e`)

Optional, not part of `check-all`: it replays [Bootstrap](#bootstrap), [Operate](#operate) and Destroy with this project's own files against [floci-az](https://github.com/floci-io/floci-az), a free local Azure emulator in Docker. Run it after changing generators, the state-backend module or the version pins, or to try a newer floci-az image.

```bash
make e2e                  # about 6 minutes; needs macOS with Docker Desktop, curl, git, the pinned terramate (make setup) and the project's git checkout; OpenTofu itself runs in a container
E2E_VERBOSE=1 make e2e    # the same, streaming the output of every step
```

It works on a throwaway copy of your tracked and unignored files (your tree and `.terraform` directories stay untouched), against a floci-az container on a random `127.0.0.1` port (no Docker socket, removed with its volume on exit). Terramate runs on the host, OpenTofu does not: `tofu` is a shim that runs the pinned image `ghcr.io/opentofu/opentofu:<the version in .tool-versions>` in a second container that shares the emulator's network namespace. Two facts force that: the backend's blob URL is fixed to `https://<account>.blob.core.windows.net`, so the emulator has to answer there over TLS (`FLOCI_AZ_TLS_ENABLED`, its CA in `SSL_CERT_FILE`, one hosts entry per state account), and the azurerm provider on macOS ignores `SSL_CERT_FILE` (observed: `x509: certificate signed by unknown authority` with and without it). For every environment under `stacks/`:

- Bootstrap as above (local state, apply, `-migrate-state -force-copy`, clean plan), the migrated state read back through the azurerm backend (`tofu state list` prints `azurerm_storage_container.state`) and the state blob under its generated key. Each `state-backend` apply takes about 42 s: the provider polls every write it makes (about 10 s each, 20 s for a resource group).
- Operate: saved-plan `terramate run` init, plan and apply (about 72 s for the `network` stack), the state blob of each stack under its key, then a second plan that must be clean (`-detailed-exitcode`: Terramate counts exit code 2, changes, as a failure, so one clean stack cannot hide a dirty one).
- On the first `state-backend` stack of the environment, a held lock (`tofu console` keeps the lease on the state blob) refuses a second plan (`state blob is already locked`) and is then released. On every exit, a failing run included, the script releases the console and waits for it before it removes the emulator, so the console's unlock still reaches the emulator.
- Destroy: the reverse destroy of an unprotected environment; the guard's refusal where `protect_destroy = true`; for every `state-backend` the `prevent_destroy` refusal of all three resources. The destroy plan names only the container: a destroy plan stops at its first refusal and skips what depends on it, so the container, the first to go, hides the account and the resource group. A replace plan of the account and one of the resource group are run too, each refused with its own resource named (`Resource instance module.state_backend.azurerm_storage_account.state has prevent_destroy set`, then the same for `azurerm_resource_group.state`; the text wraps at 78 columns, so the script reads the output as one line). The mock tests cannot see `prevent_destroy`; this is what notices one lost from any of the three.
- Once, before the first apply, a tripwire drill: with `ARM_METADATA_HOSTNAME` unset a plan must die at the dead proxy (`proxyconnect tcp`, towards `login.microsoftonline.com`); it takes about 16 s (token retries).

The copy gets a gitignored `modules/state-backend/e2e_override.tf` for what floci-az cannot do, each observed. It answers every `Microsoft.Authorization` route with 404 `ResourceNotFound`, so no role assignment can be applied; it answers the GET of the management lock and of the lifecycle policy with the storage account itself, so the provider reports both as already existing; and it echoes a fixed storage account (a PUT with `Standard_GRS`, HTTPS-only and TLS 1.2 comes back `Standard_LRS`, HTTPS-only off, TLS 1.0, shared keys and local users on, `Account` key types, no blob properties), which the first plan after the migration showed as a replacement and as changes. The override therefore sets the role assignments aside (`for_each` over an empty set), sets the lock and the policy to `count = 0` and gives the storage account `ignore_changes` for `account_replication_type`, `default_to_oauth_authentication`, `https_traffic_only_enabled`, `infrastructure_encryption_enabled`, `local_user_enabled`, `min_tls_version`, `public_network_access`, `queue_encryption_key_type`, `shared_access_key_enabled`, `table_encryption_key_type` and `blob_properties` (`prevent_destroy` survives: lifecycle blocks merge). Nothing else needed one: `default_outbound_access_enabled = false` applies and reads back, and the account's anonymous-access and cross-tenant settings echo correctly. What the override costs is in the table below.

Each step prints `..` and its label when it starts and `ok` and the label with its seconds when it passes, so the applies that take a minute are not silent; a passing run ends with `e2e: all checks passed in <n>s; floci-az removed on exit, Azure never contacted`. A failing step shows the last 30 lines of its output (with `E2E_VERBOSE=1` all of it is already on screen) and stops the run with `e2e: FAILED: <label>`. A project without generated stack files fails (`e2e: no stacks/<environment>/<region>/<stack> with a generated azurerm backend: run make generate`) instead of passing with nothing checked. The shipped tree runs 38 steps (dev 20, prod 18: the tripwire drill runs once).

Measured on macOS (arm64) with Docker 29.9.2: 347 s with all 38 steps ok, both images cached and the provider cache warm; before the two replace plans per environment were added (each takes 1 to 2 s), 353 s and 347 s (consecutive runs, provider cache warm) and 356 s (empty plugin cache). Six steps take most of the time: the tripwire drill (16 s), each `state-backend` apply (42 s), each `network` apply (72 and 73 s) and the destroy apply of `dev` (72 s); every other step takes 2 s or less. The first run, or a run with an empty plugin cache, also downloads the provider for linux next to the one for macOS (`init` then takes about 5 s instead of 0 to 1 s; the lock files do not change, so Terramate's safeguards stay quiet; an Intel host would fetch the amd64 build: not run). Cold image pulls were not measured: the emulator image is 130.9 MB on disk and the OpenTofu image 136.9 MB, and the script prints `e2e: pulling <image>` when the OpenTofu image is missing.

It cannot reach Azure: the environment is scrubbed (no `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `MSI_*`, `IDENTITY_*`, `ACTIONS_ID_TOKEN_REQUEST_*`, `SYSTEM_ACCESSTOKEN`, `CI_JOB_TOKEN`, `CI_JOB_JWT`, `CI_JOB_JWT_V2`, `CI_REGISTRY_PASSWORD`, `GOOGLE_*`, `GCLOUD_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `GITLAB_*`, `TF_*`, `GIT_*`, proxy or token variable), the only credentials are fake (`ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` and an `ARM_ACCESS_KEY` of any base64 value; `ARM_USE_CLI=false`, so `az` is never called), `ARM_METADATA_HOSTNAME` is the provider's only redirect (the emulator's loopback port, seen from inside its network namespace), the state accounts' blob host names resolve to the emulator alone, and every other host dies at a dead proxy, proven by a `curl` before the run and by the drill during it. The network is needed for the OpenTofu registry, GitHub and the two images only (provider downloads and image pulls).

| It shows | It cannot show |
|---|---|
| OpenTofu 1.13.1, azurerm 5.11.0 and Terramate accept the generated backend, provider, versions and locals blocks and the module call: Bootstrap with local state and the migration into the container the stack itself created, the state blob under `stacks/<stack id>/tofu.tfstate` | the Entra ID path, of the backend and of the provider: the run uses an `ARM_ACCESS_KEY` (the backend checks it before Entra ID: read in OpenTofu 1.13.1) and a fake client secret, so `use_azuread_auth = true` is parsed and never exercised |
| resource group, storage account, container, virtual network, network security group, two subnets (`default_outbound_access_enabled = false`) and the associations apply, a second plan is clean, and saved-plan `terramate run` and the reverse destroy of an unprotected environment work under Terramate's safeguards | RBAC: no role assignment exists, no data-plane authorization, no 403, no propagation delay; whether Storage Blob Data Contributor at the resource group is enough for `init`, locking and writing is untested |
| the state lock is a blob lease: a second operation is refused and the lock released | the CanNotDelete lock and its blocking of deletes, the lifecycle policy, blob versioning and soft delete (the emulator stores no blob properties) |
| the destroy guard and `prevent_destroy` really fail under this OpenTofu | the account's hardening (GRS, TLS 1.2, HTTPS only, shared keys and local users off, OAuth by default, infrastructure encryption, public network access): offline only, in the module tests, trivy and checkov |
| an unredirected provider dies at the dead proxy | real Azure: naming collisions, quotas, region availability (GRS in the region), policy, resource provider registration, throttling, the platform's default NSG rules (the emulator returns none); nothing here replaces a first apply in a sandbox subscription |

Knobs, all optional environment variables:

| Variable | Default | Use |
|---|---|---|
| `E2E_IMAGE` | `floci/floci-az:nightly-10232026@sha256:e97e84516a74a5c4256783b08734bb8df8bbc88268dd784c2253033195ceb398` | pin another tag or digest. A dated nightly, because floci-az 0.15.0 (the newest release, and `latest`, when this was written) answers 200 for a blob container that does not exist, and `azurerm_storage_container` then fails with `already exists` (observed); floci-az #523 fixes it and nightly-10232026 is the first image that has it: move to the first release that carries the fix after a re-run |
| `E2E_VERBOSE` | unset | `1` streams the output of every step live; any other value: only a failing step shows its last 30 lines |
| `TF_PLUGIN_CACHE_DIR` | `~/.terraform.d/plugin-cache` | the provider cache that the OpenTofu container mounts; read before the scrub, and it receives the linux build of the provider |
| `TMPDIR` | the system default | where the scratch copy lives |

Run on macOS with Docker Desktop only: it is the only host this was verified on (sharing a container's network namespace on a Linux host is untested). A new image can change the result: the emulator default is pinned by digest, never `latest`, and the OpenTofu image follows `.tool-versions`. The price is a dated nightly until a floci-az release carries #523, and two images (about 270 MB) to pull.

## Grow the tree

| Add | How |
|---|---|
| stack | `terramate create`, then write `main.tf` |
| region | copy `stacks/<environment>/<region>` to `stacks/<environment>/<new region>` (the folder name is the region), edit `vnet_cidr` in `network/main.tf`, bootstrap its `state-backend` |
| environment | copy `stacks/<environment>` to `stacks/<new environment>` (the folder name is the environment name), set `subscription_id` and `state_contributor_principal_ids` (and `protect_destroy`: `true` if protected, else `false`), bootstrap each region |

New stack:

```bash
terramate create stacks/<environment>/<region>/<stack> --name <stack> --description "..." --after ../state-backend
# write main.tf (and outputs.tf) in the new directory; it already has the generated backend, provider, versions and locals
(cd stacks/<environment>/<region>/<stack> && cp ../state-backend/.terraform.lock.hcl . && tofu init -backend=false)    # keeps the locked provider; commit the lock file
```

`terramate create --tags <tag>` sets the stack's tags; only `state-backend` uses one.

New region or environment, by copying:

```bash
cp -R stacks/<existing> stacks/<new>      # a region instead: stacks/<environment>/<existing> and stacks/<environment>/<new>, in every line
find stacks/<new> -name .terraform -type d -prune -exec rm -rf {} +
find stacks/<new> -name stack.tm.hcl -exec sed -i.bak '/^[[:space:]]*id[[:space:]]*=/d' {} + && find stacks/<new> -name '*.bak' -delete
$EDITOR stacks/<new>/globals.tm.hcl       # an environment: subscription_id, state_contributor_principal_ids (a region needs no edit: the folder name is the region)
make generate                             # new ids = new state keys (copied ids fail with "duplicated ID"), then writes the new backend files; commit them
```

The lock files are copied along and stay valid (same providers). Commit, then bootstrap the new `state-backend` stacks.

- Edit `vnet_cidr` in each copied `network/main.tf`: the copy keeps the source's range. There is no zone list to edit: the stack names no availability zone. The location must be open to the subscription: `az account list-locations --query "[].name" -o tsv`.
- State keys are stack ids, so a moved stack keeps its state only within the same subscription and region: the storage account comes from `subscription_id` and `region`.
- `environment` and `region` are the first two folder names under `stacks/` (`globals.tm.hcl`): add a new level (for example `<env>/`) below `<region>/`, and adjust the relative `source` of any hand-written stack that calls a local module.
- Every stack gets `local.location` and `local.tags`. tflint (`terraform_unused_declarations`) flags each of the two that a stack leaves unused; a note in `generate.tm.hcl` says so. A resource that takes `tags` gets `tags = local.tags`, and `location = local.location`.

## Upgrades

Each of these in its own pull request.

| What | Where | Then |
|---|---|---|
| OpenTofu, Terramate | `.tool-versions`; `terramate.tm.hcl` `required_version` when the Terramate minor changes | `make setup` (installs the pins), `make doctor` |
| Homebrew tools (trivy, checkov, terraform-docs, tenv, pre-commit, terraform-mcp-server) | the `Brewfile` lists them without versions | `brew upgrade <name>`, yours to run (`make setup` installs what is missing and keeps installed formulae; the doctor only checks that they run), then `make doctor` and `make check-all` |
| Azure provider constraint | `azurerm_provider_version` in `globals.tm.hcl`; for modules `modules/*/versions.tf` | `make generate`, then `make relock` |
| Registry module | exact `version` in the stack's `main.tf` (OpenTofu intersects its own provider floor with `azurerm_provider_version`; nothing is promoted into the global) | `make relock` |
| Hook revisions, tflint ruleset | `.pre-commit-config.yaml` (plain tags), the plugin `version` in `.tflint.hcl` | `make update` (newest tag on each hook repository's default branch: for gitleaks that can lag its newest release), then `make check-all` |
| terraform-skill | `.agents/skills/terraform-skill` | `make skill`, then review `git diff -- .agents/skills` ([Skill](#skill)) |
| floci-az and OpenTofu images of the rehearsal | `E2E_IMAGE` in `e2e.sh`; the OpenTofu image follows `.tool-versions` | `make e2e` with the new tag ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)) |

`make relock` runs `tofu init -backend=false -upgrade` in every stack (`terramate run --disable-safeguards=git`, needed because `make generate` just dirtied the tree; the outdated-code safeguard stays on) and in every `modules/*/`. Finish with `make check-all`.

`make update` runs `pre-commit autoupdate` (plain tags, not SHAs), moves the azurerm ruleset in `.tflint.hcl` to the newest release tag of its source repository (`tflint ruleset <old> -> <new>`, or `tflint ruleset already at <v>`) and builds the hook environments of the new revisions (`pre-commit install-hooks`). It always verifies TLS and leaves OpenTofu, Terramate and the providers alone. Its last line is `review "git diff", run "make check-all", commit`.

## Deployer RBAC

Least-privilege access for the identities that run `terramate run`; replace the placeholders. The `state-backend` module assigns **Storage Blob Data Contributor** to every id in `state_contributor_principal_ids`, at the scope of the state resource group (it holds only the account, so the role reaches the account and its container). The backend authenticates with Entra ID only and the account has no keys, so this data-plane role is what lets an identity list, read, write and lease the state blobs: the role carries `blobs/read`, `blobs/write`, `blobs/add/action` and `blobs/delete`, which are what List Blobs, Get Blob, Put Blob and Lease Blob need according to Microsoft Learn; Owner and Contributor carry no blob data actions.

| Identity | Role | Scope | For |
|---|---|---|---|
| everyone who runs `terramate run`, the bootstrap identity included | Storage Blob Data Contributor | the state resource group `rg-<project>-tfstate-<region>`; the module creates it from `state_contributor_principal_ids` | the state blobs and their leases |
| the bootstrap identity (once, and whenever `state-backend` changes) | Owner, or Contributor plus User Access Administrator | the subscription | the resource group, account, container, lifecycle policy, role assignments and lock. Contributor cannot write role assignments or locks; Role Based Access Control Administrator writes role assignments only |
| whoever applies the workload stacks (`network`) | Contributor | the subscription | the resource group, virtual network, network security group, subnets and association the stack creates. Inference, not evaluated: Contributor on the subscription creates the resource group and Network Contributor on that group would suffice for the rest; a narrower custom role is yours to define |

`state_contributor_principal_ids` takes Entra ID object ids, not application (client) ids: `az ad signed-in-user show --query id -o tsv` for yourself, `az ad sp show --id <client id> --query id -o tsv` for a service principal, the object id of a group or the `principalId` of a managed identity otherwise. To add or remove an identity later, edit the list, run `make generate`, commit, then plan and apply `state-backend` with the bootstrap identity ([Operate](#operate)). The assignments sit at the resource group because the lock on the account blocks deleting role assignments at or below the account (Microsoft Learn), which removing a principal would otherwise run into. Add what the stacks you write manage (more resource types, more scopes).

Not evaluated by Azure: the table follows Microsoft's built-in role definitions (Microsoft Learn, read on 2026-10-24) and the ARM calls of the module, and has never been tried against a real subscription, so try it in a sandbox subscription before relying on it.

## Design decisions

1. **Subscription = environment**: `stacks/<environment>/<region>/<stack>`, one state storage account per subscription and region; blast radius follows subscription boundaries.
2. **State key = stack id** (`stacks/<id>/tofu.tfstate`): moving a folder cannot orphan state; ids come from `make generate` (`terramate create --ensure-stack-ids`) and are never copied, so every project gets fresh state keys.
3. **`azurerm` backend with Entra ID authentication, no keys**: `use_azuread_auth = true`, and the account refuses shared keys, so the state is reachable only with an Entra ID token and a blob data role: no key to leak or rotate. The generated blocks pin `subscription_id`, carry no credentials and no `tenant_id` (with both the az CLI token request fails). There is no counterpart of `allowed_account_ids` on AWS: the pinned `subscription_id` is the only selector, and a value in code beats `ARM_SUBSCRIPTION_ID` and the az default subscription (observed with a stubbed az); `generated-backend` and `generated-provider` keep the pin in place. The backend's pin only selects the CLI token: the account is addressed by its global name, so nothing checks that it lives in the pinned subscription. With a service principal a wrong pin should fail with 403 at the first Resource Manager call (not evaluated).
4. **Hardened state account**: Entra ID only (above), no anonymous access (`allow_nested_items_to_be_public = false`, a private container), HTTPS only with TLS 1.2 as the minimum (the only value azurerm 5.x accepts), no cross-tenant replication, `GRS` (set in the module, not an input: checkov `CKV_AZURE_206` fails LRS and ZRS, observed; a region without a pair needs `ZRS` there and an inline checkov skip for `CKV_AZURE_206`), blob versioning, 30-day soft delete of blobs and containers, versions deleted after 90 days by a lifecycle policy, and infrastructure encryption (a second layer under Microsoft-managed keys, only selectable when the account is created). The public endpoint stays on: with Entra ID as the only way in, network rules or a private endpoint would lock out laptops and CI runners unless you provide a network path; a customer-managed key needs a Key Vault with purge protection. Both are decisions for your organisation, so `modules/state-backend/main.tf` carries three `#trivy:ignore` (`AVD-AZU-0012` network rules, `AVD-AZU-0057` queue logging, which no state needs and `queue_properties` no longer configures in azurerm 5.x, `AVD-AZU-0060` customer-managed key) and five `#checkov:skip` (`CKV2_AZURE_1`, `CKV2_AZURE_33`, `CKV_AZURE_33`, `CKV_AZURE_59`, `CKV2_AZURE_21`), each with its reason.
5. **A CanNotDelete lock on the account, the role assignments at the resource group**: the lock is the control-plane counterpart of `prevent_destroy`; the module creates it last and destroys it first. It protects the account, its container and its policy from being deleted through Resource Manager, not the blobs (data-plane operations are not blocked by locks): versioning and soft delete are the net for those. The role assignments sit one scope up because a lock on the account blocks deleting role assignments at or below it.
6. **No client-side state encryption by default**: the key would have to pre-exist and its loss would mean state loss; Microsoft-managed keys with infrastructure encryption, versioning and TLS-only already cover the account. To enable it, follow OpenTofu's [State and Plan Encryption](https://opentofu.org/docs/language/state/encryption/) before a stack's first apply (existing state needs its migration path) and leave out the `state-backend` stacks (their state would depend on the key they create).
7. **Backend, provider, versions and locals are generated from globals, and greps guard the generator**: a dropped security line (Entra ID auth, the subscription pin) would otherwise regenerate everywhere silently. `validate` never reads the backend block.
8. **`language { compatible_with }` gates the OpenTofu version**: OpenTofu 1.12+ does not enforce `required_version` in `.tf` files.
9. **Lock files committed for stacks and modules, `-lockfile=readonly` in every hook**: reproducible installs; `tofu init` 1.12+ records hashes for all platforms (15 `h1:` and 15 `zh:` for azurerm 5.11.0 from registry.opentofu.org). The provider comes from the OpenTofu registry, which serves its own build of each release, signed with its own key (0C0AF313E5FD9F80 for 5.11.0; registry.terraform.io serves another build under HashiCorp's key 34365D9472D7468F): hashes recorded against one registry do not match the other's build (the archive checksums of the darwin_arm64 builds differ, a374b4d8… against b183835a…).
10. **`state-backend` is plain resources with plan-only mock tests** (6 runs) that assert the hardening, the geo-redundant replication, the Standard StorageV2 account, the private container, the account and container names the generated backend addresses and the account's resource group, versioning and both soft-delete periods, the 90-day version policy, the CanNotDelete lock on the account, each role assignment's principal, role and resource-group scope, and a failing run for every input validation, but not `prevent_destroy` (the `module-prevent-destroy` hook counts its lines; `make e2e` proves it on the resource group, the account and the container). **`network` is plain `azurerm` resources, not the Azure Verified Module** `Azure/avm-res-network-virtualnetwork/azurerm` (0.22.3 when compared, measured in fresh inits): it builds the network from `azapi`, so the stack would carry four providers (a 140-line lock file against 39 lines and 650 MB against 244 MB of `.terraform`), one of them (`modtm`) unsigned on the OpenTofu registry and sending telemetry by default (subscription and tenant ids, module source and version, to `aka.ms`); trivy and checkov cannot see inside downloaded modules, and `azapi` would need its own provider block pinned to the subscription. Plain resources keep one provider, one pin and full scanner visibility.
11. **Destroy guard**: `protect_destroy` generates a `prevent_destroy` resource into every stack of a protected environment, since Terramate has none; `-target` and `-exclude` bypass it.
12. **Location and tags are generated locals**: azurerm has no `default_tags`, so `local.location` and `local.tags` come from the same globals as the folder names and every resource passes them on; no `.tf` holds a region literal, which makes a copied region need no edit besides its CIDR.

## Not covered

- Real Azure: nothing was ever applied to a subscription. Never exercised: the azurerm backend's Entra ID path, Storage Blob Data Contributor at the resource group being enough for `init`, locking and writing (role propagation included), the CanNotDelete lock and what it blocks, the lifecycle policy, blob versioning and soft delete, the account's hardening as Azure applies it, resource provider registration, and applying the `network` stack. `make e2e` runs Bootstrap, state migration, plan and apply (the `network` stack included) and the destroy guard against the floci-az emulator with these files: it shows that OpenTofu, the provider and Terramate accept the generated blocks, not that Azure does.
- The rehearsal's own gaps, each from floci-az ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e) has the reasons): no role assignments and no authorization, so no RBAC; no management lock; no lifecycle policy; blob properties accepted and not stored; a fixed storage account echo (LRS, TLS 1.0, shared keys on, ...), so replication, TLS minimum and key settings are ignored in the copy and checked only offline; the Entra ID path of the backend replaced by an access key. Of the module's six resource types the rehearsal applies three (resource group, storage account, container); the role assignments, the lock and the policy are set aside in its copy.
- Registry-module internals and inputs are not scanned (`terraform_trivy` runs with `--tf-exclude-downloaded-modules`; checkov does not read downloaded modules): the exact version pin is the control. No registry module ships.
- `terraform_trivy` scans with the checks bundle it downloads from `mirror.gcr.io` (a few megabytes, re-checked once the cache is a day old, kept in trivy's cache: `~/Library/Caches/trivy` on macOS, `~/.cache/trivy` on Linux). When the download or the re-check fails it logs `Falling back to embedded checks` (hidden by pre-commit while the hook passes; a cache older than a day is not used then either), scans with the checks built into the installed trivy and still exits 0: the same tree can pass in one environment and fail in another once a new check ships. Two known causes: no network, and a `credsStore` in `~/.docker/config.json` (Docker Desktop) whose helper (`docker-credential-desktop`) is not on `PATH`, as in a trimmed agent environment (`error getting credentials`). `trivy conf . --debug` shows which one applies.
- Mocks prove module logic, not provider behaviour: `tofu test` runs plan-only against `mock_provider`.
- `prevent_destroy` and other lifecycle arguments are invisible to the mock tests (`make e2e` proves `prevent_destroy` on the resource group, the account and the container, and nothing else; the `module-prevent-destroy` hook only counts the `prevent_destroy = true` lines of `modules/state-backend/main.tf`): review the module diff.
- `validate` and `test` never read backend blocks (`init -backend=false`): the `generated-*` greps cover the generated text. After changing a backend generator, run `tofu init -input=false` in one stack with the credential variables unset and `AZURE_CONFIG_DIR` pointing at an empty directory. It must fail only with `No valid azure auth methods found` (an `az` that is not logged in) or `Error looking for command az in your PATH`; a schema problem is reported before that, as `An argument named "<name>" is not expected here`. A real `tofu init` is the only full check.
- Nothing in the repository stops an exported `ARM_ACCESS_KEY` or `ARM_SAS_TOKEN` from overriding Entra ID authentication in the backend: only the account's disabled shared keys do, and that is Azure's behaviour, not evaluated here.
- The tflint azurerm ruleset has no write-only or ephemeral-resource rules: nothing flags a secret that lands in state. `AGENTS.md` and review do.
- The `generated-*` greps pin the subscription id but cannot tell whether the identity running OpenTofu may use it, or whether the state account lives in it.
- Client-side state encryption is off.
- Only the Azure public cloud: the generated blocks set no `environment` or `metadata_host`.
- gitleaks knows token formats, not passwords: it does not flag a password embedded in a URL (`https://user:password@host`).
- Taken at their newest release when installed or updated: the hooks, the tflint ruleset, terraform-skill and the Homebrew tools. A new upstream version can change what a check or your agent does without any change in this repository: review the `make update` and `make skill` diff before committing. The MCP side changes without a diff to review: `microsoft-learn` is a third-party hosted service (rate limits not evaluated, needs the network, tools can change at any time) and `terraform-registry` reads registry.terraform.io.
- Supply chain: pre-commit downloads a Go toolchain for gitleaks without hashes; checkov and trivy come from Homebrew, Terramate is verified by checksum only; the `terraform-registry` MCP server (its entry unsets `TFE_TOKEN` and `TFE_ADDRESS`, see [Agent tooling](#agent-tooling)) and the hooks that git starts run with your shell's environment (`make check`, `check-all`, `test`, `relock` and `doctor` unset the variables listed in [Checks](#checks) first). `make setup` and `make update` build the hook environments with the cloud variables and the GitHub tokens unset.
- `make setup`, `make update`, `make skill`, `make relock`, `make check`, `make check-all` and `make test` force TLS verification for their git fetches (pre-commit's clone of a hook revision it does not have yet and `tofu init`'s clone of a `git::` module source included), whatever your git config says, except Homebrew's tap clone (`terraform-linters/tap`, only while it is not installed): Homebrew drops `GIT_*` variables, so that clone uses your git configuration. The git hooks that `make hooks` installs force nothing: after pulling a hook update, run `make check` once before you commit. A path-scoped override (`http.https://github.com/<owner>/.sslVerify=false`) is more specific and wins; git older than 2.31 ignores the mechanism for the git calls of pre-commit and `tofu init` (direct git calls are unaffected); a TLS-intercepting network makes them fail.
- Verified on macOS (arm64) only: Linux and WSL2 were not run for this folder.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: `terraform_fmt`, `terraform_providers_lock`, `terraform_tflint`, `terraform_docs`, `terraform_validate`, `terraform_trivy`, `terraform_checkov`.
- [terraform-provider-azurerm](https://github.com/hashicorp/terraform-provider-azurerm) (MPL-2.0), [tflint-ruleset-azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm) and [floci-az](https://github.com/floci-io/floci-az): the provider of the stacks, the lint ruleset, and the emulator of `make e2e`.
- [terraform-aws-modules](https://github.com/terraform-aws-modules/terraform-aws-vpc): `.editorconfig` follows theirs.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the Response Contract and rules in `AGENTS.md`, and the skill itself.
