# OpenTofu + Terramate on Google Cloud

[OpenTofu](https://opentofu.org) for the code, [Terramate](https://terramate.io) for stacks, code generation and run order, [pre-commit](https://pre-commit.com) as the only check runner. `make help` lists the local entry points; coding agents read [AGENTS.md](AGENTS.md).

- A stack is a directory with a `stack.tm.hcl`: one OpenTofu root module with its own state.
- Shipped: the stacks `state-backend` and `network` for every environment and region (defaults: environments `dev` and `prod`, each one Google Cloud project, region `europe-west3`; [Parameters](#parameters) changes them).
- Every check runs without cloud credentials. Nothing has been applied to a real Google Cloud project (see [Not covered](#not-covered)); `make e2e` replays Bootstrap, Operate and Destroy against a local emulator ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)). Unless you replaced them, the project ids `example-dev` and `example-prod` are placeholders. Replace them first, they feed the bucket names and the project every stack talks to. Nothing refuses a wrong project the way the `allowed_account_ids` of the AWS template refuses a wrong account: a wrong id fails where your credentials have no access and goes through where they have ([Design decisions](#design-decisions); not evaluated).

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
e2e.sh                   optional floci-gcp rehearsal (`make e2e`)
AGENTS.md  README.md     rules for coding agents; this file
modules/state-backend/   Cloud KMS key ring and key, Cloud Storage bucket; tests/ (mock provider); README.md filled by terraform-docs
stacks/
  dev/                   globals.tm.hcl: project_id, protect_destroy (the folder name is environment)
    europe-west3/        the folder name is region
      state-backend/     stack.tm.hcl (tag state-backend) + generated files
      network/           stack.tm.hcl, main.tf, outputs.tf + generated files
  prod/                  same shape; protect_destroy = true adds the destroy guard
```

Terramate always treats the git root as the project root, so the root-only settings in `terramate.tm.hcl` (`required_version`, `telemetry`, ...) only work in that file; `config.run.env` also works in subfolders.

Globals per level; lower levels add to or override higher ones:

| Level | File | Globals |
|---|---|---|
| project | [`globals.tm.hcl`](globals.tm.hcl) | `project`, `opentofu_version`, `google_provider_version`, `environment` and `region` (the folder names of `stacks/<environment>/<region>/`), `state_bucket`, `state_kms_key_ring`, `state_kms_key`, `default_labels` (`managed_by` = `terramate`, `project` = `project`, and `environment` = `environment`); values are in the file |
| environment | `stacks/<environment>/globals.tm.hcl` | `project_id` (the Google Cloud project ID, asserted in `generate.tm.hcl`); `protect_destroy` (`true` for a protected environment, else `false`; required: a missing or misspelt key fails `make generate`) |
| stack | `stack.tm.hcl` | `stack {}`: `name`, `description`, `tags`, `after`, `id` |

`generate.tm.hcl` writes these files into every stack below it. They are committed and never edited by hand: change `generate.tm.hcl` or a globals file, run `make generate` and commit the result (the `terramate` hook runs `terramate generate` with `--detailed-exit-code` and fails when it had to write files). The `id` of a stack is assigned by `make generate` and is the state prefix.

| Generated file | Content | Written for |
|---|---|---|
| `_terramate_generated_backend.tf` | gcs backend: bucket `state_bucket`, prefix `stacks/<stack id>` (the state object is `default.tfstate` and the lock object `default.tflock` below it); no credentials, no `kms_encryption_key`, no project (the backend has no such attribute) | every stack |
| `_terramate_generated_provider.tf` | `provider "google"`: `project`, `region`, `default_labels`; no credentials | every stack |
| `_terramate_generated_versions.tf` | `required_version`, `required_providers`, `language { compatible_with }` | every stack |
| `_terramate_generated_state_backend.tf` | `module "state_backend"`; bucket, key ring and key names come from the same globals as the backend | tag `state-backend` |
| `_terramate_generated_destroy_guard.tf` | `terraform_data` resource with `prevent_destroy` | `protect_destroy = true` |

| Stack | Runs after | Content |
|---|---|---|
| `state-backend` | | the generated module call: bucket `<project>-tfstate-<project_id>-<region>`, key ring `<project>-tfstate` and key `tfstate` |
| `network` | `../state-backend` | plain provider resources, no registry module: the custom-mode VPC network `main` (regional routing, no automatic subnetworks) and the subnetwork `private` in the stack's region, the first /20 of `vpc_cidr` (`cidrsubnet(local.vpc_cidr, 4, 0)`), with Private Google Access and flow logs (5-second aggregation, sampling 0.5, all metadata); outputs `network_id` and `private_subnet_id`; default CIDRs dev `10.10.0.0/16`, prod `10.20.0.0/16` |

`modules/state-backend`: Cloud KMS key ring and key, and the Cloud Storage bucket for state with that key as its default encryption; behavior and inputs are documented in [its README](modules/state-backend/README.md).

## Prerequisites

```bash
make setup    # Brewfile packages (installed ones are kept), the OpenTofu and Terramate pins via tenv, the tflint ruleset, hook environments; ends with make doctor
make doctor   # one line per tool: ok, MISSING or WRONG; installs nothing, makes no network call, changes nothing in the project; any problem is a non-zero exit
make update   # hook revisions and the tflint ruleset to their newest releases (OpenTofu, Terramate and providers stay pinned); then review git diff, make check-all, commit
make hooks    # the git hooks (pre-commit, pre-push, commit-msg); run it after the first commit
```

- `make setup` needs [Homebrew](https://brew.sh) on macOS 15+ (Apple Silicon), Linux (x86_64 or arm64, glibc) or WSL2; on Linux and WSL first run `sudo apt-get update && sudo apt-get install -y build-essential procps curl file git unzip` (Homebrew's own requirements on Linux, plus `unzip` for the tflint cask). The first run needs network and takes minutes (downloads and caches: Homebrew formulae, `~/.tenv`, `~/.tflint.d`, the Go toolchain and Python packages of the hook environments in `~/.cache`, the Google provider in `~/.terraform.d/plugin-cache`; the total was not measured for this folder); later runs work offline, except that trivy then scans with its embedded checks ([Not covered](#not-covered)).
- `make check`, `check-all`, `test` and `relock` export `TF_PLUGIN_CACHE_DIR` (default `~/.terraform.d/plugin-cache`, created) to share provider binaries across stacks and modules. Interactive `tofu` and `terramate run` commands need the export themselves, and so do the git hooks: `terraform_validate` on `git push` does not export it, so a fresh clone downloads the Google provider (about 123 MB unpacked per directory, measured for 8.8.0 on macOS arm64) into every stack and module directory (5 here). Put `export TF_PLUGIN_CACHE_DIR=$HOME/.terraform.d/plugin-cache` (and `mkdir -p "$TF_PLUGIN_CACHE_DIR"`) in your shell profile, or run `make check-all` once: it leaves `.terraform` in place. A directory without a lock file downloads the provider once even with a warm cache; locked inits reuse the cache.
- When the anonymous GitHub API quota (60 requests per hour per IP) is exhausted, run `TENV_GITHUB_TOKEN=<token> GITHUB_TOKEN=<token> make setup` (the same for `make update`): tenv ignores `GITHUB_TOKEN`, `tflint --init` downloads the Google ruleset from GitHub. Never print or commit tokens.
- Run `terramate` and `tofu` from the project root or below it: tenv finds the pins by walking up from the working directory (`terramate -C` from outside the project ignores them). A missing pinned tool makes the tenv shim exit 42: run `make setup`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, ...); the `commit-msg` hook enforces it.
- Optional: `export CHECKPOINT_DISABLE=1` stops Terramate's update check in interactive runs (the Makefile and the hooks set it).
- The Brewfile has no cloud CLI. [Bootstrap](#bootstrap) needs `gcloud` (Google's [installation guide](https://docs.cloud.google.com/sdk/docs/install-sdk); Homebrew cask `gcloud-cli`) for its first commands, the API enablement and the login; nothing else in this project calls it.
- To operate, a machine needs HTTPS to the Google APIs of the stacks (Cloud Storage for the state and the bucket, Cloud KMS, Compute Engine) and, for Application Default Credentials from `gcloud`, to Google's token endpoint (hosts as Google documents them; not evaluated against Google Cloud). The provider also calls `openidconnect.googleapis.com` (userinfo) on every run, hard-coded, and carries on when that fails (observed with a refusing `HTTPS_PROXY`, provider 8.8.0).

| Tool | Version | Provided by |
|---|---|---|
| OpenTofu, Terramate | pinned in `.tool-versions`; `terramate.tm.hcl` sets the Terramate floor | installed by tenv |
| pre-commit | 4.4.0 or newer (4.7.0 verified) | brew |
| tflint | 0.61.0 or newer (0.61.0 verified); the Google ruleset version in `.tflint.hcl` (tflint requires one; 0.40.0 when this folder was written), newest via `make update` | the `terraform-linters/tap/tflint` cask; the ruleset is fetched by `tflint --init` |
| trivy, terraform-docs, tenv, terraform-mcp-server | newest at install (0.76.0, 0.24.0, 4.15.1, 1.3.0 verified) | brew |
| checkov | Homebrew's current formula: 3.3.30 on 2026-10-24, the version the checks of this folder were verified with (from PyPI through `uvx`: the verifying Mac had no Homebrew checkov); the formula can lag PyPI. The `terraform_checkov` hook runs the system binary | brew |
| gitleaks | newest hook release (`make update`) | built by pre-commit on first use |

## Make targets

`make help` lists the targets. `check`, `check-all` and `test` stop with "untracked files are not checked" and list up to five of them while git shows untracked files: `git add -A` them or gitignore them. Hooks only see tracked files: pre-commit skips an untracked one and still exits 0. `make e2e` is not part of `check-all`: it needs Docker (verified with Docker Desktop on macOS only) and takes about 30 seconds ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)).

In the template repository (this folder lies inside another repository's work tree, so it is not a project: a project is its own git repository), `check`, `check-all`, `test` and `e2e` print `template checkout: running <target> in a throwaway project` and run in a copy of the tracked and unignored files in a scratch git repository (`make generate`, then the target), removed on every exit, Ctrl-C included; they need no `git add`. What the hooks rewrote or created in the copy is applied to the checkout as one patch (review `git diff` and `git status`, then rerun); stack ids and generated files never come back, a patch that does not apply is printed on stderr instead, and the exit code is the target's. `generate`, `relock`, `skill` and `hooks` refuse there (`this folder is a template inside <path>`); a project copied into a subfolder of another repository gets the same treatment: `git init` it.

## Parameters

The wizard of the template's RUNBOOK.md (a checkout of the template; its commit is in the first line of this file) asks these rows once; they are also the guide for later edits. Paths are relative to the project root.

| Parameter | Default | Rule | How to change (project-root paths) |
|---|---|---|---|
| project | basename of the target directory, lowercased, every run of other characters → `-`, trimmed; if the result breaks the rule: ask | `^[a-z][a-z0-9-]*[a-z0-9]$`; the state bucket name `<project>-tfstate-<project_id>-<region>` at most 63 characters, not starting with `goog` and not containing `google` or a lookalike such as `g00gle` (all asserted by generate.tm.hcl); unique among your projects in the same Google Cloud project and region (bucket and key ring collide otherwise, and a key ring can never be deleted) | `project` in `globals.tm.hcl`, then `make generate` |
| environments | `dev` (`example-dev`), `prod` (`example-prod`) — placeholders: replace the project ids | name `^[a-z][a-z0-9-]{0,19}$`, unique; it is also the label value `environment`, and generate.tm.hcl asserts that label values use lowercase letters, digits, `_` and `-`; `project_id`: the project ID `^[a-z][a-z0-9-]{4,28}[a-z0-9]$` (asserted), not the project number or display name, distinct. Whether the project exists and Google accepts the ID cannot be checked offline | per environment `stacks/<name>/globals.tm.hcl` (`project_id`; the folder name is the environment name). Rename: `mv stacks/<old> stacks/<new>`; add: copy `stacks/<existing>` to `stacks/<new>` (once `make generate` has run, delete the copied `id = ...` lines in its `stack.tm.hcl` files, recipe in [Grow the tree](#grow-the-tree)), set its `project_id`, give it a new `vpc_cidr`, `make generate`; remove: delete `stacks/<name>` |
| protect_destroy | `true` for environments whose name starts with `prod`, else `false` | boolean, set in every environment | `protect_destroy = true` or `false` in `stacks/<name>/globals.tm.hcl` |
| region | `europe-west3` (all environments) | `^[a-z]+-[a-z]+[0-9]+$`: a Google Cloud region, not a zone, multi-region or dual-region (asserted by generate.tm.hcl and the module). The state bucket and the key ring live in it, so Cloud Storage and Cloud KMS must offer it: no offline check can tell | per environment `mv stacks/<environment>/europe-west3 stacks/<environment>/<region>` (the folder name is the region; the stacks take it from the provider, no other file names it), then `make generate` |
| VPC CIDR | `10.10.0.0/16` (dev), `10.20.0.0/16` (prod), then `10.30.0.0/16`, ... | `^10\.[0-9]{1,3}\.0\.0/16$`, distinct | `vpc_cidr` in each `network/main.tf` |
| Google provider | keep the locked 8.8.1 (verified) | `keep` or `latest` (newest 8.x that registry.opentofu.org serves: `curl -fsS https://registry.opentofu.org/v1/providers/hashicorp/google/versions`; it can trail registry.terraform.io: on 2026-10-23 it answered 404 for 8.8.1 for a while after the Terraform registry published it); the constraint `>= 8.0, < 9.0` stays | `latest`: `make relock` after `make generate` |

Version pins of OpenTofu and Terramate are generic (step 2 of the template's RUNBOOK): `.tool-versions` lines `opentofu X.Y.Z` / `terramate X.Y.Z`; Terramate also `required_version = "~> X.Y.Z"` in `terramate.tm.hcl`; rule `^[0-9]+\.[0-9]+\.[0-9]+$`, OpenTofu >= 1.12.0.

Derived by `make generate` (the RUNBOOK shows them back): per environment and region the state bucket `<project>-tfstate-<project_id>-<region>`, the key ring `<project>-tfstate` and the key `tfstate`, and the state prefix of every stack, `stacks/<stack id>`.

Placeholder values the RUNBOOK leftover scan looks for: `example`, `europe-west3`.

## Checks

`.pre-commit-config.yaml`, in execution order. "Both" means pre-commit and pre-push: the fast set re-runs at push to catch `git commit --no-verify`. `make check` runs the commit stage on every tracked file, `make check-all` both stages.

| Hook id | Source | Stage | Checks |
|---|---|---|---|
| `check-added-large-files`, `check-merge-conflict`, `check-yaml`, `end-of-file-fixer`, `mixed-line-ending` (lf), `trailing-whitespace` | pre-commit-hooks | both | hygiene; `check-added-large-files` runs with `--enforce-all` and `check-merge-conflict` with `--assume-in-merge` so both also work under `--all-files`; the three fixers skip the skill copy (`.agents/skills/`) |
| `gitleaks` | gitleaks | both | secrets in the staged changes (blind under `--all-files`) |
| `gitleaks-history` | gitleaks | pre-push | secrets in every commit (`gitleaks git --redact --verbose`), runs even when no file survives |
| `conventional-pre-commit` | conventional-pre-commit | commit-msg | Conventional Commits message |
| `terramate` | local | both | `terramate fmt`, `generate`, `list --run-order`: fails on rewritten `.tm.hcl`, stale or hand-edited generated files, duplicate stack ids, `after` cycles or typos, failed asserts (project name, project id, region, bucket name length and `goog`/`google`, label keys and values), a stack without `_terramate_generated_{backend,provider,versions}.tf`; prints `hint: run "make generate"` when a stack has no id |
| `generated-versions` | local (pygrep) | both | generated versions still has the top-level `language { compatible_with { opentofu = ... } }` gate (OpenTofu ignores `required_version` in `.tf` files) |
| `generated-backend` | local (pygrep) | both | generated backend still has, line-anchored, a literal `bucket` of 3 to 63 characters (lowercase letters, digits, `-` and `_`, starting and ending with a letter or digit) and `prefix = "stacks/<36-character id>"`, and no `credentials`, `access_token`, `encryption_key` or `kms_encryption_key` line (each of the four, added to a generated backend in a scratch copy, made the hook fail) |
| `generated-provider` | local (pygrep) | both | generated provider still has, line-anchored, a literal `project` (a project ID) and `region` and `default_labels = {`, all at exactly two spaces of indent (a `project` label key inside `default_labels` sits deeper and does not count), and no `credentials` or `access_token` line |
| `forbidden-files` | local | both | rejects state files, plans, crash logs, `.terraform/`, `.tofu`, `.tofu.json` and `.tofutest.hcl` files and override files (`override.tf`, `*_override.tf`, `.json` forms): they silently replace the generated backend, provider and destroy guard |
| `module-prevent-destroy` | local (pygrep) | both | `modules/state-backend/main.tf` still has 3 `prevent_destroy = true` lines (key ring, key and bucket): `tofu test` cannot see lifecycle arguments; lower the count only in a reviewed change that removes a guard on purpose, never just to pass the hook |
| `tofu-test` | local | pre-push | `tofu test` in every module with mock providers; fails when a module has no tests, runs none, or leaves `errored_test.tfstate` |
| `terraform_fmt` | pre-commit-terraform | both | `tofu fmt` |
| `terraform_providers_lock` | pre-commit-terraform | both | every provider in every lock file has at least as many `h1:` hashes as configured platforms (darwin and linux, amd64 and arm64) and a `zh:` hash; it counts hashes, it does not check which platforms they belong to (offline) |
| `terraform_tflint` | pre-commit-terraform | both | tflint with preset `all`, the Google ruleset (`deep_check = false`: deep checks call Google APIs and need credentials) and exact registry-module versions; the ruleset has no write-only or ephemeral-resource rules |
| `terraform_docs` | pre-commit-terraform | both | regenerates `modules/*/README.md` between the `BEGIN_TF_DOCS` and `END_TF_DOCS` markers |
| `terraform_validate` | pre-commit-terraform | pre-push | `tofu validate`, serially, in every directory under `make check-all` and in the directories of changed files on a push; a directory without `.terraform` first gets `tofu init -backend=false -lockfile=readonly`, so the stacks' gcs backend is never contacted (it exports no `TF_PLUGIN_CACHE_DIR`: see [Prerequisites](#prerequisites)); needs no credentials and no placeholder variables: the generated stacks validated under an empty environment |
| `terraform_trivy` | pre-commit-terraform | both | `trivy config`, MEDIUM and above, `.terraform` and downloaded registry-module internals excluded: once at the project root under `make check` and `check-all`, per directory of changed files on a commit or push; one inline `#trivy:ignore:GCP-0077` (bucket access logging) |
| `terraform_checkov` | pre-commit-terraform | pre-push | the Homebrew checkov, terraform framework, `--skip-download`: once at the project root under `check-all`, inside each directory of changed files on a push; `CKV_TF_1` is skipped in the hook, every other skip is an inline `#checkov:skip` with a reason (`grep -rn checkov:skip .`: `CKV_GCP_62`, bucket access logging, and `CKV2_GCP_18`, the network without a firewall rule of its own) |

- A hook that rewrites files (`end-of-file-fixer`, `mixed-line-ending`, `trailing-whitespace`, `terraform_fmt`, `terraform_docs`, `terramate`) fails the run: review the change, `git add` it, run again. `terramate fmt` formats `*.tm.hcl` files up front: run it after editing one by hand.
- `trivy` and `checkov` are system tools: they must be on the `PATH` of whatever runs git (no hook environment builds them; a GUI git client or a minimal CI image often lacks Homebrew's `bin`). Missing: `checkov: command not found` (exit 127) or `'trivy' is required by 'terraform_trivy' pre-commit hook but it is not discoverable in the system's PATH`. `make doctor` finds both.
- Network use of the pre-commit-terraform hooks: trivy fetches its checks bundle from `mirror.gcr.io` at most once a day and still runs offline, with its embedded checks ([Not covered](#not-covered)); checkov (the hook sets `CKV_SKIP_PACKAGE_UPDATE_CHECK=true`) makes no request.
- Scanner results on the shipped tree (checkov 3.3.30, trivy 0.76.0): `state-backend` passes 7 checkov checks, among them `CKV_GCP_82` (key deletion protection, the scanner check that sees the key's `prevent_destroy`), `CKV_GCP_43` (key rotation within 90 days), `CKV_GCP_114` (public access prevention), `CKV_GCP_29` (uniform bucket-level access) and `CKV_GCP_78` (versioning), and skips `CKV_GCP_62`; `network` passes `CKV_GCP_26` (flow logs) and `CKV_GCP_74` (Private Google Access) and skips `CKV2_GCP_18`; trivy reports `GCP-0077` on the bucket, ignored inline. Each skip was proven by removing it: the hook then fails. An inline `#checkov:skip=<id>:<reason>` goes inside the resource block; `#trivy:ignore:<id>` counts only directly above the `resource` line (inside the block it has no effect).
- `make check`, `check-all`, `test`, `relock` and `doctor` unset every `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `MSI_*`, `IDENTITY_*`, `ACTIONS_ID_TOKEN_REQUEST_*`, `GOOGLE_*`, `GCLOUD_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `TF_HTTP_*`, `TF_VAR_*` and `GITLAB_*` variable, plus `SYSTEM_ACCESSTOKEN`, `CI_JOB_TOKEN`, `CI_JOB_JWT`, `CI_JOB_JWT_V2`, `CI_REGISTRY_PASSWORD`, `TF_ENCRYPTION`, `TENV_GITHUB_TOKEN`, `GH_TOKEN` and `HOMEBREW_GITHUB_API_TOKEN` (not `GITHUB_TOKEN`: `terraform_tflint` runs `tflint --init`, which reads it), before pre-commit, tflint, tofu or a provider binary starts. Variables only: a login cached in a config dir (`~/.config/gcloud`, `~/.aws`, az, `~/.govmomi`) is not isolated; only the `tofu-test` hook points `GOOGLE_APPLICATION_CREDENTIALS` (and the AWS config and credentials files) at `/dev/null` and the az, azd and gcloud config dirs at an empty temp dir. `GOOGLE_APPLICATION_CREDENTIALS=/dev/null` is there because `CLOUDSDK_CONFIG` does not move the Application Default Credentials file of `gcloud auth application-default login`: Go clients read `~/.config/gcloud/application_default_credentials.json` whatever it says, and `/dev/null` makes them fail closed (`unexpected end of JSON input`) instead of falling back to that file or the metadata server (tried with the provider against local stubs). The git hooks that `make hooks` installs run with the environment of the process that runs git; inside them only `tofu-test` scrubs itself. `tofu validate` starts the provider binary and does not configure it; it passed under an empty environment, and nothing enforces that it stays offline (not measured); trivy and checkov only read files. The prefix list must stay in step in the Makefile `SCRUB` (`INSTALL_HOOKS` uses it too), the `tofu-test` hook and `e2e.sh`.

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
| Google Developer Knowledge MCP | `initialize` and `tools/list` answer without credentials, a `tools/call` needs an API key (it answered 401 without one: checked 2026-10-23 against `https://developerknowledge.googleapis.com/mcp`) | `terraform-registry` ([Agent tooling](#agent-tooling)) |

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
- Plan and apply need credentials and are out of scope for the template; the runbook is under [Operate](#operate).

## Agent tooling

Project scope: instructions in [AGENTS.md](AGENTS.md); MCP servers in `.mcp.json`, read as is by Claude Code and omp (verified) and, per their documentation, by GitHub Copilot, VS Code and Devin; the skill `terraform-skill` ([Skill](#skill)).

| Server | Gives the agent | Where it runs | Credentials |
|---|---|---|---|
| `terraform-registry` | Terraform registry lookups: provider and module versions, resource schemas, docs (9 read-only tools) | local binary | none |

The provider is `hashicorp/google`: `search_providers` and `get_provider_details` for `google_storage_bucket` (provider version 8.8.0) returned the resource's documentation (30,379 characters, including `default_kms_key_name`, `public_access_prevention` and `soft_delete_policy`), and `search_modules` found `terraform-google-modules/network/google` 18.3.1 (terraform-mcp-server 1.3.0, checked 2026-10-23). The server queries registry.terraform.io, not registry.opentofu.org: on 2026-10-23 it named google 8.8.1 while the OpenTofu registry still answered 404 for that version, so the lock file and `make relock` decide what is installed.

No documentation server for Google Cloud ships. Google's own, the Developer Knowledge MCP (`https://developerknowledge.googleapis.com/mcp`), answers `initialize` and `tools/list` without credentials (three tools: `search_documents`, `answer_query`, `get_documents`), but a `tools/call` returned 401 without credentials (checked 2026-10-23); its documentation asks for an API key (`X-Goog-Api-Key` header) or an OAuth access token, and the Developer Knowledge API enabled in a project ([docs](https://developers.google.com/knowledge/mcp)): a credential, so it stays out of `.mcp.json`; add it to your own MCP config if you want it, and every query then leaves your machine. A keyless third-party server answered without authentication (not shipped, answer quality not evaluated, every query leaves your machine): Context7 (`https://mcp.context7.com/mcp`).

Why the `terraform-registry` command looks like this: `--toolsets=registry` keeps the 9 read-only registry tools (without it a TFE token in `~/.terraform.d/credentials.tfrc.json` exposes 56 tools, 19 of them without a read-only hint); `env -u TFE_TOKEN -u TFE_ADDRESS HOME=/nonexistent` stops the binary from reading and sending that token, and makes it log `failed to create TFE client ... /nonexistent` to stderr on every start: by design, not a failure.

Cloud API access (credentials, Application Default Credentials, impersonation) is not shipped: the entry above is lookup-only and credential-free. If you add a credentialed server yourself, keep it out of `.mcp.json` in the repository.

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

Once per environment and region, with credentials that may create the bucket, the key ring and the key in that environment's Google Cloud project ([Deployer IAM](#deployer-iam)). Until the bucket exists every other stack of that environment and region fails at `tofu init`. Use plain `tofu` here: the generated gcs backend points at a bucket that does not exist yet, so a gitignored `backend_override.tf` swaps in local state for the first apply.

On the Google Cloud side, once per project; the template creates none of it, and none of it was evaluated against Google Cloud:

1. The project exists and is linked to a billing account; `project_id` is its project ID.
2. Enable the APIs the stacks use: `gcloud services enable cloudkms.googleapis.com compute.googleapis.com serviceusage.googleapis.com storage.googleapis.com --project <project_id>`. A new project also starts with a `default` VPC network whose pre-populated firewall rules allow SSH, RDP and ICMP from 0.0.0.0/0: delete it, or enforce the `compute.skipDefaultNetworkCreation` organization policy, which keeps projects that inherit it from getting one (Google's VPC and firewall documentation; not evaluated).
3. The generated blocks name no credentials, and the hooks fail on a `credentials`, `access_token`, `encryption_key` or `kms_encryption_key` line, so credentials come from the environment of whoever runs tofu: look at your shell before a plan. On a workstation run `gcloud auth application-default login`. The provider and the backend both read the file it writes (`~/.config/gcloud/application_default_credentials.json`) and the file `GOOGLE_APPLICATION_CREDENTIALS` names. For every attribute the generated block leaves unset, the backend also reads `GOOGLE_BACKEND_CREDENTIALS` or `GOOGLE_CREDENTIALS`, `GOOGLE_OAUTH_ACCESS_TOKEN`, `GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT` or `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`, `GOOGLE_BACKEND_STORAGE_CUSTOM_ENDPOINT` or `GOOGLE_STORAGE_CUSTOM_ENDPOINT`, `GOOGLE_BACKEND_UNIVERSE_DOMAIN`, `GOOGLE_ENCRYPTION_KEY` and `GOOGLE_KMS_ENCRYPTION_KEY` (read from the OpenTofu 1.13.1 source; the last two would add an encryption key to the state writes), and `STORAGE_EMULATOR_HOST`, which Google's Go storage client reads, points the backend at that host without any authentication (observed against a local stub). The backend does not read `GOOGLE_CLOUD_KEYFILE_JSON` and `GCLOUD_KEYFILE_JSON`, the provider does (observed against local stubs, provider 8.8.0 and OpenTofu 1.13.1), so a stack that authenticates only through those fails at `tofu init`.
4. Credentials from `gcloud` belong to a project that Google owns, not yours. `gcloud auth application-default set-quota-project <project_id>` stores your project as the quota project in that file, but the provider builds its clients from a token source and the source of its reference guide carries a note that the quota project is not currently read from the file, so do not rely on it alone. The provider's documented route for such credentials is `user_project_override = true` plus `billing_project`; the generated provider sets neither, and the provider reads both from the environment while its block leaves them unset (`USER_PROJECT_OVERRIDE=true`, `GOOGLE_BILLING_PROJECT=<project_id>`: read from the provider source, not run); the caller then needs `serviceusage.services.use` on that project. Whether your credentials need any of this was not evaluated.
5. The identity that runs the bootstrap needs the bucket and key permissions in [Deployer IAM](#deployer-iam), including `resourcemanager.projects.get` for the lookup of the Cloud Storage service agent that the module grants the key to.

First set the real `project_id` in `stacks/<environment>/globals.tm.hcl`, run `make generate` and commit: the placeholder ids are baked into the committed generated files (the bucket name too), and plain `tofu` has no outdated-code safeguard.

```bash
cd stacks/<environment>/<region>/state-backend
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
tofu init
tofu plan -out=tfplan     # review
tofu apply tfplan && rm backend_override.tf   # a failed apply keeps the override, so the next line cannot overwrite an existing state
tofu init -migrate-state -force-copy
tofu plan -detailed-exitcode && [ ! -e backend_override.tf ] && rm -f terraform.tfstate* tfplan   # the local state goes only after the migration and a clean plan (exit code 0)
```

- git cannot show a forgotten `backend_override.tf` (it is ignored): check that it is gone. Never commit it: the `forbidden-files` hook rejects tracked override files, which would silently replace the generated backend.
- Stop if the migration fails: the local state is the only record of the bucket, the key ring and the key.
- The first apply can fail at the bucket with a permission error on the Cloud KMS key although the module grants the Cloud Storage service agent first: IAM changes propagate eventually, and the bucket waits for the grant (`depends_on`) but not for its propagation. Run `tofu plan -out=tfplan` and `tofu apply tfplan && rm backend_override.tf` again after a minute, then the rest of the block (not evaluated: no real project was used).
- The stack now keeps its own state in the bucket it created, under `stacks/<stack id>/default.tfstate` (the gcs backend names objects `<prefix>/<workspace>.tfstate`, and the workspace is `default`). `prevent_destroy` on bucket, key ring and key and `force_destroy = false` make decommissioning a deliberate code change.
- Cloud KMS never deletes key rings or keys (documented by Google): destroying a key ring only forgets it, and destroying a key forgets it and schedules its versions for destruction, after which data encrypted with it is unreadable. To bootstrap the same names again after a decommissioning, import the existing key ring and key first, with temporary `import` blocks in the stack (ids as the provider documents them; not run): `to = module.state_backend.google_kms_key_ring.state` with `id = "projects/<project_id>/locations/<region>/keyRings/<project>-tfstate"`, and `to = module.state_backend.google_kms_crypto_key.state` with `id = "projects/<project_id>/locations/<region>/keyRings/<project>-tfstate/cryptoKeys/tfstate"`; or choose other names (`state_kms_key_ring`, `state_kms_key` in `globals.tm.hcl`).
- Then initialise the other stacks: `cd stacks/<environment> && terramate run -- tofu init`.

## Operate

Run from `stacks/<environment>`: credentials and the Google Cloud project are per environment, and `terramate run` at the project root would span every environment. The generated provider pins `project` and `region`, and they beat `GOOGLE_PROJECT` and `GOOGLE_REGION` (read from the provider source), but nothing refuses credentials of another project: IAM alone decides what a call may do, and which credentials act is decided by what your shell exports ([Bootstrap](#bootstrap), 3). Export `TF_PLUGIN_CACHE_DIR` first ([Prerequisites](#prerequisites)).

```bash
cd stacks/<environment>
terramate run -- tofu init                                       # first time, and after lock or provider changes
terramate run --no-tags state-backend -- tofu plan -out=tfplan   # then read every stack's plan
terramate run --no-tags state-backend -- tofu apply tfplan       # applies exactly the reviewed plans
```

- Routine runs leave `state-backend` out. Plan and apply it only with bootstrap-level credentials (`terramate run --tags state-backend -- ...`, same plan-then-apply flow), when `modules/state-backend` or its globals change.
- Never `-auto-approve`. A stale or already applied plan is refused.
- `-detailed-exitcode` is unusable under `terramate run`: exit code 2 counts as failure.
- Safeguards stay on: `terramate run` refuses an uncommitted or untracked tree, outdated generated code and a checkout behind its remote (if you add an `origin`, push `main` to it before the first `terramate run`: the git safeguard calls `git ls-remote`; without a remote the check is skipped). Do not use `-X`; `tfplan` is gitignored, so it does not trip them.
- A run that died (closed terminal, timeout) leaves its lock object `stacks/<id>/default.tflock` in the state bucket, and the next run in that stack stops with `Error acquiring the state lock` (`googleapi: Error 412 ... conditionNotMet`) and a `Lock Info:` block (`ID`, `Who`, `Created`); the `ID` is the generation number of the lock object and `Who` is `<user>@<host>` of the process that holds it (observed against floci-gcp). Locks never expire: one survived `kill -9` (observed against a fake Cloud Storage server, not the real service). First make sure no other run holds it: ask whoever `Who` names and check your pipeline. Then, in that stack's directory with the project's credentials, run `tofu force-unlock <LOCK_ID>` with the `ID` from the message and answer `yes`; a wrong id is refused (412) and the lock stays. Never `-lock=false` as a way around it.
- History: the bucket is versioned, so every state write leaves a noncurrent generation of `default.tfstate`, deleted 90 days after it became noncurrent (the soft delete default of 7 days, left alone, keeps a deleted generation 7 days longer; documented, not evaluated). The deployer's `roles/storage.objectUser` includes `storage.objects.delete`, which also deletes noncurrent generations, so the history is only as safe as the deployer: soft delete is the only net behind it, and a bucket retention policy or object holds would add one (an organisation choice, neither set here nor evaluated; [Deployer IAM](#deployer-iam)). `gcloud storage ls --all-versions gs://<bucket>/stacks/<stack id>/default.tfstate` lists the generations (the flag is in Google's command reference; not run).

Destroy, only after the destroy plan was shown and confirmed:

```bash
terramate run --no-tags state-backend --reverse -- tofu plan -destroy -out=tfplan   # read every resource it deletes
terramate run --no-tags state-backend --reverse -- tofu apply tfplan
```

- Protected environments (`protect_destroy = true`, prod by default): `tofu destroy` and `plan -destroy` fail with `Resource instance cannot be destroyed`. Flip `protect_destroy` in a reviewed pull request and run `make generate` (the guard files disappear in the diff) before planning the destroy; when the work is done, revert the flip and run `make generate` in a second reviewed pull request. The guard protects a stack only once an apply has created it: after turning `protect_destroy` on for live stacks, or reverting a flip, apply that environment before relying on it. Limit: `-target` and `-exclude` plan destroys past the guard. OpenTofu 1.13 prints `-exclude="terraform_data.destroy_guard"` in the refusal itself: do not follow that hint.
- `state-backend` stays out of the destroy (`--no-tags state-backend` above): `prevent_destroy` on its bucket, key ring and key makes its destroy plan fail, and removing the guard is a code change in the module (and in the `module-prevent-destroy` count).

## End-to-end rehearsal (`make e2e`)

Optional, not part of `check-all`: it replays [Bootstrap](#bootstrap), [Operate](#operate) and Destroy with this project's own files against [floci-gcp](https://github.com/floci-io/floci-gcp), a free local Google Cloud emulator in Docker. Run it after changing generators, the state-backend module or the version pins, or to try a newer floci-gcp image.

```bash
make e2e                  # about 30 seconds (20 to 27 s measured with the image and the provider cached); needs Docker (Docker Desktop on macOS is the only host verified), curl, the pinned tofu and terramate (make setup) and the project's git checkout
E2E_VERBOSE=1 make e2e    # the same, streaming the output of every step
```

It works on a throwaway copy of your tracked and unignored files (your tree and `.terraform` directories stay untouched), against a floci-gcp container on a random `127.0.0.1` port (no Docker socket, removed with its volume on exit). For every environment under `stacks/`:

- Bootstrap as above (local state, apply, `-migrate-state -force-copy`, clean plan), a state object under the stack's generated prefix, and a GET for the key: floci-gcp stores neither the bucket's default key nor its name, so the key's existence is all that can be checked.
- Operate: saved-plan `terramate run` init, plan and apply of the workload stacks, a state object under each stack's prefix, then a second plan that must show `No changes`. Once per run, a plan without the Compute endpoint variable must die at the dead proxy (`proxyconnect tcp`).
- Locks, on the first `state-backend` stack: a held lock (`tofu console` on a FIFO) refuses a second plan (`conditionNotMet`), `tofu force-unlock` with the lock object's generation, which is the lock `ID`, frees it, and a plan runs again. On every exit, a failing run included, the script releases the console and waits for it before it removes the container: a console that loses its backend retries forever.
- Destroy: the reverse destroy of an unprotected environment, plan then apply of the saved plan; the guard's refusal where `protect_destroy = true`; for every `state-backend` the `prevent_destroy` refusal of all three resources: the destroy plan names only the bucket (observed: a failed resource stops the ones that wait for it), so a replace plan of the key and one of the key ring are run too, each refused with its own resource named.

Each step prints `..` and its label when it starts and `ok` and the label when it passes, so a slow step is not silent; a passing run ends with `e2e: all checks passed in <n>s; floci-gcp removed on exit, Google Cloud never contacted`. A failing step shows the last 30 lines of its output (with `E2E_VERBOSE=1` all of it is already on screen) and stops the run with `e2e: FAILED: <label>`. A project without generated stack files fails (`e2e: no stacks/<environment>/<region>/ with generated files: run make generate`) instead of passing with nothing checked. The shipped tree runs 40 steps (dev 21, prod 19: the tripwire drill runs once).

It cannot reach Google Cloud: the environment is scrubbed (no `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `MSI_*`, `IDENTITY_*`, `ACTIONS_ID_TOKEN_REQUEST_*`, `GOOGLE_*`, `GCLOUD_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `GITLAB_*`, `TF_*`, `GIT_*`, proxy or token variable (`GITHUB_TOKEN`, `GH_TOKEN`, `TENV_GITHUB_TOKEN`, `HOMEBREW_GITHUB_API_TOKEN`), no `SYSTEM_ACCESSTOKEN`, `CI_JOB_TOKEN`, `CI_JOB_JWT`, `CI_JOB_JWT_V2` or `CI_REGISTRY_PASSWORD`), `GOOGLE_APPLICATION_CREDENTIALS=/dev/null` keeps your application default credentials out (without the fake token the provider fails with `unexpected end of JSON input` instead of using them), the only credential is a fake access token (`GOOGLE_OAUTH_ACCESS_TOKEN`), the only redirects are `GOOGLE_STORAGE_CUSTOM_ENDPOINT` (it serves the provider and the gcs backend alike), `GOOGLE_COMPUTE_CUSTOM_ENDPOINT` and `GOOGLE_KMS_CUSTOM_ENDPOINT` (loopback, preflight-checked at `/health`), and every other host dies at a dead proxy (`HTTPS_PROXY`, `HTTP_PROXY` and `ALL_PROXY` at `127.0.0.1:9`), proven by a `curl` before the run and by the plan without the Compute endpoint during it. An audit proxy in place of the dead one saw no Google host during a whole run (measured once: with the `universe_domain` override below it saw only `tripwire.invalid`, the `curl` proof, and `compute.e2e.invalid`, the drill; without the override seven `CONNECT openidconnect.googleapis.com:443`). The network is needed for registry.opentofu.org and GitHub (provider downloads) and, on the first run, for Docker Hub (the image: 63 MB compressed, 199 MB on disk).

Two kinds of gitignored override files exist in the copy only (the `*_override.tf` ignore rule keeps them away from git and Terramate's safeguards):

- `e2e_override.tf` in every stack sets `poll_interval = "100ms"` (the provider polls Compute operations every 10 s otherwise: a run without it took 81 s instead of about 20 s) and a `universe_domain` other than googleapis.com. The latter stops the provider's own hard-coded call to `openidconnect.googleapis.com`, so nothing at all is sent towards Google, and turns every service without an endpoint variable into `https://<service>.e2e.invalid`.
- `modules/state-backend/e2e_override.tf` leaves out what floci-gcp 0.11.0 does not emulate: the KMS IAM grant (`count = 0`, otherwise the apply fails with `CryptoKey not found` at `getIamPolicy`), and `ignore_changes` for the key's rotation period and labels and for the bucket's default key (each override was removed once and broke the run). Its `lifecycle` blocks merge with the module's `prevent_destroy`, so the destroy refusals above still hold; the state-backend plans print a harmless `Redundant ignore_changes element` warning for two label attributes. The overrides become redundant, not wrong, when floci-gcp closes those gaps.

| It shows | It cannot show |
|---|---|
| `tofu`, the provider and Terramate accept the generated backend and provider blocks (`bucket`, `prefix`, `project`, `region`, `default_labels`) and the destroy guard; every stack's state object lands under `stacks/<id>/default.tfstate` | IAM and organization policies, API enablement, billing and quotas: floci-gcp does not enforce IAM by default and accepts any token and project; Google's own name and location validation |
| bootstrap, state migration, saved-plan apply, a clean second plan and the reverse destroy work under Terramate's safeguards; the bucket (versioning, uniform bucket-level access, public access prevention, the 90-day rule), key ring and key are accepted and read back without drift, the service agent lookup works, and the `network` stack applies | that the bucket is encrypted with the key, the service agent's grant on the key, key rotation and key labels: the overrides drop them and only a GET shows that the key exists; the enforcement of public access prevention, soft delete, and IAM propagation on a first real apply |
| state locking is a conditional write: a held lock refuses a second plan (`conditionNotMet`) and `force-unlock` by the lock's generation frees it | lock-object semantics of the real service beyond that message; real region availability, global bucket-name uniqueness, provider wait times (`poll_interval = "100ms"`), cost; a foreign project is not refused (no setting could refuse it) |
| the destroy guard and the `prevent_destroy` of the bucket, the key and the key ring really fail under this OpenTofu | real Google Cloud: nothing here replaces a first apply in a sandbox project |

Knobs, all optional environment variables:

| Variable | Default | Use |
|---|---|---|
| `E2E_IMAGE` | `floci/floci-gcp:0.11.0` | pin another tag or digest; 0.11.0 is what it ran against (the `latest` tag had the same digest on 2026-10-23, and the `nightly` image of that day passed too; 0.10.0 is the first release with Compute support; floci-gcp publishes stable releases on the 15th and the last day of each month) |
| `E2E_VERBOSE` | unset | `1` streams the output of every step live (a full run is about 1,300 lines); any other value: only a failing step shows its last 30 lines |

Run it with Docker Desktop on macOS: the only host it was verified on (Apple Silicon, Docker 29.9.2). Docker Engine on Linux is expected to work, since nothing in the script is macOS-specific (loopback addresses only, a multi-arch image), but it was not run. A run with an empty plugin cache (the 123 MB provider downloaded once) took 28 s; the time of the first image pull was not measured. A new image can change the result: the default is a pinned tag, not `latest`.

## Grow the tree

| Add | How |
|---|---|
| stack | `terramate create`, then write `main.tf` |
| region | copy `stacks/<environment>/<region>` to `stacks/<environment>/<new region>` (the folder name is the region), rename or drop its `network` (see below), bootstrap its `state-backend` |
| environment | copy `stacks/<environment>` to `stacks/<new environment>` (the folder name is the environment name), set `project_id` (and `protect_destroy`: `true` if protected, else `false`), bootstrap each region |

New stack:

```bash
terramate create stacks/<environment>/<region>/<stack> --name <stack> --description "..." --after ../state-backend
# write main.tf (and outputs.tf) in the new directory; it already has the generated backend, provider and versions
(cd stacks/<environment>/<region>/<stack> && cp ../state-backend/.terraform.lock.hcl . && tofu init -backend=false)    # keeps the locked provider; commit the lock file
```

`terramate create --tags <tag>` sets the stack's tags; only `state-backend` uses one.

New region or environment, by copying:

```bash
cp -R stacks/<existing> stacks/<new>      # a region instead: stacks/<environment>/<existing> and stacks/<environment>/<new>, in every line
find stacks/<new> -name .terraform -type d -prune -exec rm -rf {} +
find stacks/<new> -name stack.tm.hcl -exec sed -i.bak '/^[[:space:]]*id[[:space:]]*=/d' {} + && find stacks/<new> -name '*.bak' -delete
$EDITOR stacks/<new>/globals.tm.hcl       # an environment: project_id (a region needs no edit: the folder name is the region)
make generate                             # new ids = new state prefixes (copied ids fail with "duplicated ID"), then writes the new backend files; commit them
```

The lock files are copied along and stay valid (same providers). Commit, then bootstrap the new `state-backend` stacks.

- Leave `project` and `region` out of hand-written resources: the generated provider supplies both, so a copied environment follows its own `project_id`.
- Edit `vpc_cidr` in each copied `network/main.tf`: the copy keeps the source's range.
- A VPC network is a global Google Cloud resource with a name that is unique per project: the `network` stack copied into a second region of the same environment would create a second network `main` and fail at apply (documented Google Cloud behaviour; not run here). In the copy, rename the network, or keep one `network` stack and give the other regions only subnetworks.
- State prefixes are stack ids, so a moved stack keeps its state only within the same project and region: the bucket comes from `project_id` and `region`.
- `environment` and `region` are the first two folder names under `stacks/` (`globals.tm.hcl`): add a new level (for example `<env>/`) below `<region>/`, and adjust the relative `source` of any hand-written stack that calls a local module.

## Upgrades

Each of these in its own pull request.

| What | Where | Then |
|---|---|---|
| OpenTofu, Terramate | `.tool-versions`; `terramate.tm.hcl` `required_version` when the Terramate minor changes | `make setup` (installs the pins), `make doctor` |
| Homebrew tools (trivy, checkov, terraform-docs, tenv, pre-commit, terraform-mcp-server) | the `Brewfile` lists them without versions | `brew upgrade <name>`, yours to run (`make setup` installs what is missing and keeps installed formulae; the doctor only checks that they run), then `make doctor` and `make check-all` |
| Google provider constraint | `google_provider_version` in `globals.tm.hcl`; for modules `modules/*/versions.tf` | `make generate`, then `make relock` |
| Registry module (none ships) | exact `version` in the stack's `main.tf` (OpenTofu intersects its own provider floor with `google_provider_version`; nothing is promoted into the global) | `make relock` |
| Hook revisions, tflint ruleset | `.pre-commit-config.yaml` (plain tags), the plugin `version` in `.tflint.hcl` | `make update` (newest tag on each hook repository's default branch: for gitleaks that can lag its newest release), then `make check-all` |
| terraform-skill | `.agents/skills/terraform-skill` | `make skill`, then review `git diff -- .agents/skills` ([Skill](#skill)) |
| floci-gcp image of the rehearsal | `E2E_IMAGE` in `e2e.sh` | `make e2e` with the new tag ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)) |

`make relock` runs `tofu init -backend=false -upgrade` in every stack (`terramate run --disable-safeguards=git`, needed because `make generate` just dirtied the tree; the outdated-code safeguard stays on) and in every `modules/*/`. Finish with `make check-all`.

`make update` runs `pre-commit autoupdate` (plain tags, not SHAs), moves the Google ruleset in `.tflint.hcl` to the newest release tag of its source repository (`tflint ruleset <old> -> <new>`, or `tflint ruleset already at <v>`) and builds the hook environments of the new revisions (`pre-commit install-hooks`). It always verifies TLS and leaves OpenTofu, Terramate and the providers alone. Its last line is `review "git diff", run "make check-all", commit`.

## Deployer IAM

Least-privilege state access for the identity that runs `terramate run`, and what the bootstrap identity needs; replace the placeholders. Google Cloud grants roles to principals on resources, so this is a table and one command instead of a policy document. Everything below is from Google's role documentation and the backend's access pattern: not evaluated against Google Cloud, so try it with a test identity in a sandbox project before relying on it.

| Identity | Role or permission | On | Why |
|---|---|---|---|
| deployer (`terramate run`) | `roles/storage.objectUser` | the state bucket `<project>-tfstate-<project_id>-<region>` | the backend lists, reads, writes and deletes the state objects and the `default.tflock` lock objects under `stacks/` |
| deployer | the roles of what the stacks manage, for `network` for example `roles/compute.networkAdmin` | the project | VPC network and subnetwork |
| bootstrap (`state-backend`) | bucket creation and configuration, for example `roles/storage.admin` | the project | the bucket with its versioning, lifecycle rule and default key |
| bootstrap | key ring and key creation plus `cloudkms.cryptoKeys.setIamPolicy`, for example `roles/cloudkms.admin` | the project | the key ring, the key and the grant to the service agent |
| bootstrap | `resourcemanager.projects.get` | the project | the lookup of the Cloud Storage service agent (`roles/storage.admin` includes it) |

```bash
gcloud storage buckets add-iam-policy-binding gs://<project>-tfstate-<project_id>-<region> \
  --member=serviceAccount:<deployer>@<project_id>.iam.gserviceaccount.com --role=roles/storage.objectUser
```

The bucket's default key is used by the Cloud Storage service agent (`service-<project number>@gs-project-accounts.iam.gserviceaccount.com`), which the module grants `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key; callers need no Cloud KMS role (Google's documentation of customer-managed keys; not evaluated). The deployer role covers the workload stacks only: it cannot plan `state-backend`.

`roles/storage.objectUser` includes `storage.objects.delete` (Google's role documentation), which the backend needs to release its lock, and a noncurrent generation is deleted by naming its generation number (Google's Object Versioning documentation): a deployer can erase the state history, so versioning guards against mistakes, not against the deployer. Soft delete (7 days by default) is the only net behind it. A bucket retention policy or object holds would add one; whether to set them is an organisation choice, and neither is set here nor evaluated.

## Design decisions

1. **Project = environment**: `stacks/<environment>/<region>/<stack>`, one Google Cloud project per environment, one state bucket and one Cloud KMS key per project and region; blast radius follows project boundaries.
2. **State prefix = stack id** (`stacks/<id>/default.tfstate`): moving a folder cannot orphan state; ids come from `make generate` (`terramate create --ensure-stack-ids`) and are never copied, so every project gets fresh state prefixes. The gcs backend names its objects `<prefix>/<workspace>.tfstate` and `.tflock`, so the name is always `default` (no `tofu.tfstate`).
3. **gcs backend with the bucket's default key, no `kms_encryption_key`, no credentials in code**: a lock is a conditional object create (`ifGenerationMatch=0`), so no extra service. `kms_encryption_key` would send the key with the state write only (the lock write falls back to the bucket's default), duplicate the key path and break when the locations differ, so the bucket default covers both objects. Neither the provider's nor the backend's `credentials` is marked sensitive, so credentials come from the environment (Application Default Credentials in practice, [Bootstrap](#bootstrap) 3) and the `generated-*` hooks fail on a credentials line, the backend one on `encryption_key` and `kms_encryption_key` too.
4. **No counterpart of `allowed_account_ids`**: the backend has no project attribute and credentials are not bound to a project. The generated provider pins `project` and `region` (they beat the environment), the bucket name carries the project ID, and impersonating one deployer service account per environment would be the closest analogue (`impersonate_service_account` in the provider and the backend; not shipped, not evaluated). Until then a wrong project is stopped by IAM alone.
5. **No client-side state encryption by default**: the key must pre-exist and its loss would mean state loss; the Cloud KMS default key, versioning, uniform bucket-level access and public access prevention already cover the bucket. To enable it, follow OpenTofu's [State and Plan Encryption](https://opentofu.org/docs/language/state/encryption/) before a stack's first apply (existing state needs its migration path) and leave out the `state-backend` stacks (their state would depend on the key they create); reusing the bucket's Cloud KMS key gives no second access gate and no isolation between stacks.
6. **Backend, provider and versions are generated from globals, and greps guard the generator**: a dropped line would otherwise regenerate everywhere silently.
7. **`language { compatible_with }` gates the OpenTofu version**: OpenTofu 1.12+ does not enforce `required_version` in `.tf` files.
8. **Lock files committed for stacks and modules, `-lockfile=readonly` in every hook**: reproducible installs; `tofu init` 1.12+ records hashes for all platforms (15 `h1:` hashes per lock file here). `hashicorp/google` on registry.opentofu.org is OpenTofu's own build of the provider, signed with OpenTofu's key (`signed, key ID 0C0AF313E5FD9F80` in the `tofu init` output); registry.terraform.io serves HashiCorp's build with different hashes, and lock entries are per registry address. `google-beta` is not used: every attribute these stacks need is in `google`.
9. **`state-backend` is plain resources with plan-only mock tests** (11 runs: two positive runs with different names and regions, so that a value fixed in the module fails one of them, and nine `expect_failures` runs, which cover every input validation) that assert the names (a 63-character bucket name included), the locations, `force_destroy = false`, uniform bucket-level access, public access prevention, versioning, the key as the bucket's default encryption, the key in the key ring, one region for both, the 90-day rotation, the service agent's encrypt and decrypt grant and the single 90-day rule that deletes noncurrent versions, but not `prevent_destroy` (the `module-prevent-destroy` hook counts the three lines, checkov's `CKV_GCP_82` sees the key's, [Checks](#checks); `make e2e` shows all three refusals) and not the bucket's `depends_on` on the KMS grant, which no test can see (review only). Access logging needs a log bucket of its own: its check is skipped inline in `terraform_trivy` (`GCP-0077`) and `terraform_checkov` (`CKV_GCP_62`) with that reason; add one per organisation.
10. **Regional bucket and key ring, undeletable key ring**: Cloud Storage rejects a default key from another location, so one region serves both and multi-region and dual-region names fail the input validation. The key rotates every 90 days and earlier key versions stay enabled, so older state versions stay readable. Key rings and keys can never be deleted in Cloud KMS: `prevent_destroy` makes that explicit, because a destroy would forget the key ring and, for the key, also schedule its versions for destruction, which makes everything encrypted with it unreadable.
11. **Plain `network` resources, no registry module**: `terraform-google-modules/network/google` 18.3.1 declares `google-beta` and sets it on the network resource, so its network would use an unconfigured second provider that ignores the `google` block's project, labels and credentials settings (observed with provider 8.8.0 against local stubs); plain resources keep one provider, one lock entry and resources the scanners can read (the hooks do not scan module internals).
12. **Lowercase labels**: `default_labels` (`managed_by`, `project`, `environment`) use lowercase keys and values, asserted: Google Cloud labels accept no uppercase keys, and plan only notices that on resource-level labels (a key `Environment` failed there; the same key in the provider's `default_labels` passed `validate` and `plan`). The provider adds `goog-terraform-provisioned = true` to labelled resources by itself.
13. **No provider `deletion_policy`, no `user_project_override` or `billing_project`**: `prevent_destroy` and the destroy guard protect the stacks; a provider-level `deletion_policy` reaches only resources that have the attribute (verified for the bucket and the network; `google_kms_key_ring` has none in 8.8.0) and would replace their per-resource defaults. Quota settings depend on who runs tofu: see [Bootstrap](#bootstrap).
14. **Destroy guard**: `protect_destroy` generates a `prevent_destroy` resource into every stack of a protected environment, since Terramate has none; `-target` and `-exclude` bypass it.

## Not covered

- Real Google Cloud: the gcs backend against the real service, the bucket's default key with the service agent's grant and IAM propagation, IAM and organization policies as Google evaluates them, API enablement, quotas, billing and applying the `network` stack were never exercised; no real project was ever used. `make e2e` runs Bootstrap, state migration, plan and apply (the `network` stack included) and the destroy guard against the floci-gcp emulator with these files and a few module overrides for emulator gaps: it shows that OpenTofu, the provider and Terramate accept the generated blocks, not that Google Cloud does.
- Locking was observed against a fake Cloud Storage server and floci-gcp only (conditional create, 412 `conditionNotMet`, force-unlock by generation, a lock that survives `kill -9`); the missing-bucket and foreign-bucket error texts of the real service are unknown.
- No project pin: the gcs backend has no project attribute, the provider has no counterpart of `allowed_account_ids` and credentials are not bound to a project, so nothing refuses a wrong or foreign project except IAM, and `make e2e` has no step for it. The closest analogue, one deployer service account per environment through `impersonate_service_account` in the provider and the backend, is not shipped ([Design decisions](#design-decisions), 4).
- Registry-module internals and inputs are not scanned (`terraform_trivy` runs with `--tf-exclude-downloaded-modules`; checkov does not read downloaded modules): the exact version pin is the control. No module ships.
- `terraform_trivy` scans with the checks bundle it downloads from `mirror.gcr.io` (a few megabytes, re-checked once the cache is a day old, kept in trivy's cache: `~/Library/Caches/trivy` on macOS, `~/.cache/trivy` on Linux). When the download or the re-check fails it logs `Falling back to embedded checks` (hidden by pre-commit while the hook passes; a cache older than a day is not used then either), scans with the checks built into the installed trivy and still exits 0: the same tree can pass in one environment and fail in another once a new check ships. Two known causes: no network, and a `credsStore` in `~/.docker/config.json` (Docker Desktop) whose helper (`docker-credential-desktop`) is not on `PATH`, as in a trimmed agent environment (`error getting credentials`). `trivy conf . --debug` shows which one applies.
- Mocks prove module logic, not provider behaviour: `tofu test` runs plan-only against `mock_provider`.
- `prevent_destroy`, the other lifecycle arguments and the bucket's `depends_on` on the KMS grant are invisible to `tofu test`: the `module-prevent-destroy` hook counts the three `prevent_destroy = true` lines, and the rest is a review of the module diff. `make e2e` refuses a destroy or a replacement of each of the three resources, so it shows `prevent_destroy`; it cannot show the order of the grant, which its module override drops.
- `validate` and `test` never read backend blocks (`init -backend=false`): the `generated-*` greps cover the generated text. After changing a backend generator, run `tofu init -input=false` in one stack without credentials (`env -i HOME="$(mktemp -d)" TENV_ROOT="${TENV_ROOT:-$HOME/.tenv}" PATH="$PATH" tofu init -input=false`: the empty `HOME` hides the gcloud Application Default Credentials file, and `TENV_ROOT` keeps tenv's installs reachable; without it the tenv shim exits 42). It must fail only with the credential error `storage.NewClient() failed: dialing: credentials: could not find default credentials` (observed with OpenTofu 1.13.1). A schema problem is reported before it, as `Unsupported argument` (not run for this backend). A real `tofu init` is the only full check.
- Nothing server-side forces the key: the bucket's default key applies to writes that name no other key, and `encryption { google_managed_encryption_enforcement_config { restriction_mode = "FullyRestricted" } }` (in the 8.8.0 schema; it would reject writes without a customer-managed key) is not set and was not tried; only the `generated-backend` check keeps `encryption_key` and `kms_encryption_key` out.
- Bucket policies and IAM are asserted as configuration; only Google Cloud evaluates their effect. No bucket setting requires TLS: the `constraints/storage.secureHttpTransport` organization policy does (Google's documentation), and nothing here sets it.
- The bucket has no access logging (a skipped check, [Design decisions](#design-decisions) 9).
- The Google tflint ruleset checks enumerated arguments of compute resources and the like, but nothing of buckets or Cloud KMS (`storage_class = "BOGUS"` was not flagged): `terraform_trivy` and `terraform_checkov` carry those.
- The quota-project settings that user credentials may need ([Bootstrap](#bootstrap), 4), the first-apply IAM propagation, and the roles in [Deployer IAM](#deployer-iam) were never run against Google Cloud.
- Client-side state encryption is off.
- gitleaks knows token formats, not passwords: it does not flag a password embedded in a URL (`https://user:password@host`).
- Taken at their newest release when installed or updated: the hooks, the tflint ruleset, terraform-skill and the Homebrew tools. A new upstream version can change what a check or your agent does without any change in this repository: review the `make update` and `make skill` diff before committing. The MCP side changes without a diff to review: the `terraform-registry` server reads the public registry at registry.terraform.io, which can answer differently from registry.opentofu.org.
- Supply chain: pre-commit downloads a Go toolchain for gitleaks without hashes; checkov and trivy come from Homebrew, Terramate is verified by checksum only; the Google provider comes from registry.opentofu.org, signed with OpenTofu's key (checked by `tofu init`), and the lock file hashes are the control after the first download; the `terraform-registry` MCP server (its entry unsets `TFE_TOKEN` and `TFE_ADDRESS`, see [Agent tooling](#agent-tooling)) and the hooks that git starts run with your shell's environment (`make check`, `check-all`, `test`, `relock` and `doctor` unset the variables listed in [Checks](#checks) first). `make setup` and `make update` build the hook environments with the cloud variables and the GitHub tokens unset.
- `make setup`, `make update`, `make skill`, `make relock`, `make check`, `make check-all` and `make test` force TLS verification for their git fetches (pre-commit's clone of a hook revision it does not have yet and `tofu init`'s clone of a `git::` module source included), whatever your git config says, except Homebrew's tap clone (`terraform-linters/tap`, only while it is not installed): Homebrew drops `GIT_*` variables, so that clone uses your git configuration. The git hooks that `make hooks` installs force nothing: after pulling a hook update, run `make check` once before you commit. A path-scoped override (`http.https://github.com/<owner>/.sslVerify=false`) is more specific and wins; git older than 2.31 ignores the mechanism for the git calls of pre-commit and `tofu init` (direct git calls are unaffected); a TLS-intercepting network makes them fail.
- Verified on macOS (arm64) only: Linux and WSL2 were not run for this folder.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: `terraform_fmt`, `terraform_providers_lock`, `terraform_tflint`, `terraform_docs`, `terraform_validate`, `terraform_trivy`, `terraform_checkov`.
- [terraform-provider-google](https://github.com/hashicorp/terraform-provider-google) (MPL-2.0), as built for the OpenTofu registry from [opentofu/terraform-provider-google](https://github.com/opentofu/terraform-provider-google), and [floci-gcp](https://github.com/floci-io/floci-gcp) (MIT): the provider of the stacks and the emulator of `make e2e`.
- [terraform-aws-modules](https://github.com/terraform-aws-modules/terraform-aws-vpc): `.editorconfig` follows theirs.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the Response Contract and rules in `AGENTS.md`, and the skill itself.
