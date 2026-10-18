# OpenTofu + Terramate on VMware vSphere

[OpenTofu](https://opentofu.org) for the code, [Terramate](https://terramate.io) for stacks, code generation and run order, [pre-commit](https://pre-commit.com) as the only check runner. `make help` lists the local entry points; coding agents read [AGENTS.md](AGENTS.md).

- A stack is a directory with a `stack.tm.hcl`: one OpenTofu root module with its own state.
- State is [GitLab-managed OpenTofu state](https://docs.gitlab.com/user/infrastructure/iac/terraform_state/) over the `http` backend: one state per stack, named by the stack id, all in one GitLab project. There is no state stack and nothing to apply first ([Bootstrap](#bootstrap)).
- Shipped: the stack `folder` for every environment and datacenter (defaults: environments `dev` and `prod`, datacenter `example-dc`; [Parameters](#parameters) changes them). It creates the VM folder `<project>-<environment>` and is the only workload.
- Every check runs without vCenter or GitLab credentials. No real vCenter and no real GitLab has been used (see [Not covered](#not-covered)); `make e2e` replays Operate and Destroy against a vCenter simulator and a GitLab container ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)). Unless you replaced them, `example` (the project name, the datacenter `example-dc`, the hosts `vcenter-dev.example.com`, `vcenter-prod.example.com` and `gitlab.example.com`) and the GitLab project id `1111111111` are placeholders. Replace them first: they feed the state addresses, the vCenter each environment talks to and the datacenter lookup.

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
e2e.sh                   optional vcsim and GitLab rehearsal (`make e2e`)
AGENTS.md  README.md     rules for coding agents; this file
stacks/
  dev/                   globals.tm.hcl: vsphere_server (the folder name is the environment)
    example-dc/          the folder name is the vSphere datacenter
      folder/            stack.tm.hcl (tag folder) + generated files
  prod/                  same shape; protect_destroy = true adds the destroy guard
```

There is no `modules/` folder: the one shipped stack is generated from globals. A reusable module goes into `modules/<name>/` with `tests/*.tftest.hcl` and a README that `terraform-docs` fills; the `tofu-test` and `terraform_docs` hooks only run when files under `modules/` exist.

Terramate always treats the git root as the project root, so the root-only settings in `terramate.tm.hcl` (`required_version`, `telemetry`, ...) only work in that file; `config.run.env` also works in subfolders.

Globals per level; lower levels add to or override higher ones:

| Level | File | Globals |
|---|---|---|
| project | [`globals.tm.hcl`](globals.tm.hcl) | `project`, `opentofu_version`, `vsphere_provider_version`, `environment` and `datacenter` (the folder names of `stacks/<environment>/<datacenter>/`), `gitlab_url`, `gitlab_project_id`, `protect_destroy`, `vsphere_allow_unverified_ssl` (default `false`), `extra_providers` (default `{}`); values are in the file |
| environment | `stacks/<environment>/globals.tm.hcl` | `vsphere_server` (the vCenter of the environment, asserted in `generate.tm.hcl`); protected environments also `protect_destroy = true`; optionally `gitlab_project_id` for a separate state project and `vsphere_allow_unverified_ssl = true` for a lab ([Bootstrap](#bootstrap)) |
| datacenter | `stacks/<environment>/<datacenter>/globals.tm.hcl` (optional) | `datacenter = "<vSphere name>"` when the vSphere name is not usable as a folder name (a space, for example) |
| stack | `stacks/<environment>/<datacenter>/<stack>/globals.tm.hcl` (optional) | `extra_providers`: the non-vSphere providers of the stack, for example `{ routeros = { source = "terraform-routeros/routeros", version = "~> 1.92" } }` ([Grow the tree](#grow-the-tree) has the rules) |
| stack | `stack.tm.hcl` | `stack {}`: `name`, `description`, `tags`, `after`, `id` |

`generate.tm.hcl` writes these files into every stack below it. They are committed and never edited by hand: change `generate.tm.hcl` or a globals file, run `make generate` and commit the result (the `terramate` hook runs `terramate generate` with `--detailed-exit-code` and fails when it had to write files). The `id` of a stack is assigned by `make generate` and is its state name in GitLab.

| Generated file | Content | Written for |
|---|---|---|
| `_terramate_generated_backend.tf` | GitLab state: `backend "http"` with `address` = `<gitlab_url>/api/v4/projects/<gitlab_project_id>/terraform/state/<stack id>`, `lock_address` and `unlock_address` = the address + `/lock`, `lock_method = "POST"`, `unlock_method = "DELETE"`, `retry_wait_min = 5`; no credentials | every stack |
| `_terramate_generated_provider.tf` | `provider "vsphere"`: `vsphere_server` and `allow_unverified_ssl` (the global `vsphere_allow_unverified_ssl`, default `false`); no credentials | every stack |
| `_terramate_generated_versions.tf` | `required_version`, `required_providers` (`vmware/vsphere` plus the stack's `extra_providers`, in the one block OpenTofu allows per module), `language { compatible_with }` | every stack |
| `_terramate_generated_datacenter.tf` | `data "vsphere_datacenter" "this"`, looked up by the `datacenter` global | every stack |
| `_terramate_generated_folder.tf` | `vsphere_folder.vms`, a VM folder `<project>-<environment>` in that datacenter; output `folder_path` | tag `folder` |
| `_terramate_generated_destroy_guard.tf` | `terraform_data` resource with `prevent_destroy` | `protect_destroy = true` |

| Stack | Runs after | Content |
|---|---|---|
| `folder` | | the generated VM folder `<project>-<environment>` (type `vm`) at the root of the datacenter's VM folders; output `folder_path` |

## Prerequisites

```bash
make setup    # Brewfile packages (installed ones are kept), the OpenTofu and Terramate pins via tenv, the tflint ruleset, hook environments; ends with make doctor
make doctor   # one line per tool: ok, MISSING or WRONG; installs nothing, makes no network call, changes nothing in the project; any problem is a non-zero exit
make update   # hook revisions and the tflint ruleset to their newest releases (OpenTofu, Terramate and providers stay pinned); then review git diff, make check-all, commit
make hooks    # the git hooks (pre-commit, pre-push, commit-msg); run it after the first commit
```

- `make setup` needs [Homebrew](https://brew.sh) on macOS 15+ (Apple Silicon), Linux (x86_64 or arm64, glibc) or WSL2; on Linux and WSL first run `sudo apt-get update && sudo apt-get install -y build-essential procps curl file git unzip` (Homebrew's own requirements on Linux, plus `unzip` for the tflint cask). The first run needs network and takes minutes (downloads and caches: Homebrew formulae, `~/.tenv`, `~/.tflint.d`, the Go toolchain and Python packages of the hook environments in `~/.cache`, the vSphere provider in `~/.terraform.d/plugin-cache`; the total was not measured for this folder).
- `make check`, `check-all`, `test` and `relock` export `TF_PLUGIN_CACHE_DIR` (default `~/.terraform.d/plugin-cache`, created) to share provider binaries across stacks and modules. Interactive `tofu` and `terramate run` commands need the export themselves, and so do the git hooks: `terraform_validate` on `git push` does not export it, so a fresh clone downloads the vSphere provider (35 MB for one platform) into every stack directory (2 here). Put `export TF_PLUGIN_CACHE_DIR=$HOME/.terraform.d/plugin-cache` (and `mkdir -p "$TF_PLUGIN_CACHE_DIR"`) in your shell profile, or run `make check-all` once: it leaves `.terraform` in place. A directory without a lock file downloads the provider once even with a warm cache; locked inits reuse the cache.
- When the anonymous GitHub API quota (60 requests per hour per IP) is exhausted, run `TENV_GITHUB_TOKEN=<token> GITHUB_TOKEN=<token> make setup` (the same for `make update`): tenv ignores `GITHUB_TOKEN`, `tflint --init` downloads the terraform ruleset from GitHub. Never print or commit tokens.
- Run `terramate` and `tofu` from the project root or below it: tenv finds the pins by walking up from the working directory (`terramate -C` from outside the project ignores them). A missing pinned tool makes the tenv shim exit 42: run `make setup`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, ...); the `commit-msg` hook enforces it.
- Optional: `export CHECKPOINT_DISABLE=1` stops Terramate's update check in interactive runs (the Makefile and the hooks set it).
- To operate, a machine needs HTTPS to GitLab and to the vCenter of every environment it runs (port 443 unless `vsphere_server` names another), and it must trust their certificates, except the vCenter's of an environment that sets `vsphere_allow_unverified_ssl = true` ([Bootstrap](#bootstrap)). The provider and tofu use `HTTPS_PROXY` (or `https_proxy`), not `ALL_PROXY`, and `NO_PROXY`: with a proxy set, an internal vCenter needs a `NO_PROXY` entry (observed with a dead proxy against vcsim).

| Tool | Version | Provided by |
|---|---|---|
| OpenTofu, Terramate | pinned in `.tool-versions`; `terramate.tm.hcl` sets the Terramate floor | installed by tenv |
| pre-commit | 4.4.0 or newer (4.7.0 verified) | brew |
| tflint | 0.61.0 or newer (0.61.0 verified); the terraform ruleset named in `.tflint.hcl` by `source` and `version` (tflint requires the version once a source is set), newest via `make update`; with a `source`, tflint does not use its bundled copy (0.14.1 in tflint 0.61.0) | the `terraform-linters/tap/tflint` cask; the ruleset is fetched by `tflint --init` |
| terraform-docs, tenv, terraform-mcp-server | newest at install (0.24.0, 4.15.1, 1.3.0 verified) | brew |
| gitleaks | newest hook release (`make update`) | built by pre-commit on first use |

No trivy and no checkov: neither has vSphere checks ([Disabled tools](#disabled-tools)).

## Make targets

`make help` lists the targets. `check`, `check-all` and `test` stop with "nothing is tracked yet" until `git add -A` ran: hooks only see tracked files, and on an untracked tree every hook skips and pre-commit exits 0. `make test` has nothing to run until the project has a module: the `tofu-test` hook prints `(no files to check)Skipped` while no file lies under `modules/`. `make e2e` is not part of `check-all`: it runs on macOS with Docker Desktop only and takes minutes ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)).

In the template repository (this folder lies inside another repository's work tree, so it is not a project: a project is its own git repository), `check`, `check-all`, `test` and `e2e` print `template checkout: running <target> in a throwaway project` and run in a copy of the tracked and unignored files in a scratch git repository (`make generate`, then the target), removed on every exit, Ctrl-C included; they need no `git add`. What the hooks rewrote or created in the copy is applied to the checkout as one patch (review `git diff` and `git status`, then rerun); stack ids and generated files never come back, a patch that does not apply is printed on stderr instead, and the exit code is the target's. `generate`, `relock`, `skill` and `hooks` refuse there (`this folder is a template inside <path>`); a project copied into a subfolder of another repository gets the same treatment: `git init` it.

## Parameters

The wizard of the template's RUNBOOK.md (a checkout of the template; its commit is in the first line of this file) asks these rows once; they are also the guide for later edits. Paths are relative to the project root.

| Parameter | Default | Rule | How to change (project-root paths) |
|---|---|---|---|
| project | basename of the target directory, lowercased, every run of other characters → `-`, trimmed; if the result breaks the rule: ask | `^[a-z][a-z0-9-]*[a-z0-9]$`; `len(project) + 1 + len(environment) <= 79` for every environment: the VM folder `<project>-<environment>` must be shorter than 80 characters, the vSphere limit for an entity name (both asserted by generate.tm.hcl); unique among your projects in the same datacenter, or their folders collide (not evaluated) | `project` in `globals.tm.hcl`, then `make generate`. After an apply, a new name renames the folder in place (the provider documents a changed `path` as a rename; not run) |
| environments | `dev` (`vcenter-dev.example.com`), `prod` (`vcenter-prod.example.com`) — placeholders: replace the hosts | name `^[a-z]([a-z0-9-]*[a-z0-9])?$`, unique (asserted); `vsphere_server`: the vCenter's host name or IPv4 address, lowercase, at least one dot, optional `:port`, no scheme and no path (asserted), and a name its certificate lists. Environments may share a vCenter: their folders `<project>-<environment>` stay apart | per environment `stacks/<name>/globals.tm.hcl` (`vsphere_server`; the folder name is the environment name). Rename: `mv stacks/<old> stacks/<new>`; add: copy `stacks/<existing>` to `stacks/<new>` (once `make generate` has run, delete the copied `id = ...` lines in its `stack.tm.hcl` files, recipe in [Grow the tree](#grow-the-tree)), set its `vsphere_server`, `make generate`; remove: delete `stacks/<name>` |
| protect_destroy | `true` for environments whose name starts with `prod`, else absent | boolean | `protect_destroy = true` in `stacks/<name>/globals.tm.hcl` |
| vsphere_allow_unverified_ssl | `false` for every environment | boolean (asserted). `true` skips the certificate check of that environment's vCenter, for a lab whose certificate comes from a CA that no operator machine trusts, and only in a reviewed change: the provider then logs in to whoever answers. The generated value beats `VSPHERE_ALLOW_UNVERIFIED_SSL` both ways, so with `true` exporting `false` does not restore verification ([Bootstrap](#bootstrap)) | `vsphere_allow_unverified_ssl = true` in `stacks/<environment>/globals.tm.hcl`, then `make generate` |
| datacenter | `example-dc` (all environments) — placeholder: replace it | the vSphere datacenter's name, exactly as vCenter shows it; the folder name below `stacks/<environment>/` is that name, so a name that is no usable folder name (a space) keeps a safe folder name and sets `datacenter = "<vSphere name>"` in `stacks/<environment>/<folder>/globals.tm.hcl`. No offline check can tell whether it exists: the first plan fails when the lookup finds nothing. Ask the user for the names and always tell them to confirm them in the vSphere Client (their credentials) before the first plan | per environment `mv stacks/<environment>/example-dc stacks/<environment>/<datacenter>` |
| gitlab_url | `https://gitlab.example.com` — placeholder: replace it | `https://<host>[:port][/path]`, no trailing slash (asserted) | `gitlab_url` in `globals.tm.hcl`, then `make generate` |
| gitlab_project_id | `1111111111` — placeholder: replace it | the numeric id of the GitLab project that holds the states, digits only and no leading zero (asserted); on the project's overview page ("Project ID", menu Actions: Copy project ID). Not the project path: after a rename the path address stops working (on GitLab CE 19.4.2 the old path answered 301 on GET, and `tofu plan` and `apply` failed at the lock with 405; the numeric id kept working; a transfer was not tried). GitLab has no per-state permissions: every Developer of a project reads every state in it, so a prod project of its own needs its own id | `gitlab_project_id` in `globals.tm.hcl`, or per environment in `stacks/<environment>/globals.tm.hcl` (a separate prod state project), then `make generate`. Changing it after the first apply points the stacks at an empty state in the new project: move each state first with `tofu init -migrate-state` ([GitLab docs](https://docs.gitlab.com/user/infrastructure/iac/terraform_state/#migrate-to-a-gitlab-managed-opentofu-state); not run here) |
| vSphere provider | keep the locked 2.17.1 (verified) | `keep` or `latest` (newest 2.x: `curl -fsS https://registry.opentofu.org/v1/providers/vmware/vsphere/versions`); the constraint `>= 2.17, < 3.0` stays | `latest`: `make relock` after `make generate` |

When the RUNBOOK's remote row names a GitLab project, `gitlab_url` and `gitlab_project_id` default to its host and id only if the user chooses it as the state project, because every Developer of that project then reads every state ([Bootstrap](#bootstrap), step 1).

Version pins of OpenTofu and Terramate are generic (step 2 of the template's RUNBOOK): `.tool-versions` lines `opentofu X.Y.Z` / `terramate X.Y.Z`; Terramate also `required_version = "~> X.Y.Z"` in `terramate.tm.hcl`; rule `^[0-9]+\.[0-9]+\.[0-9]+$`, OpenTofu >= 1.12.0.

Derived by `make generate` (the RUNBOOK shows them back): the VM folder `<project>-<environment>` of every environment, and the state address of every stack, `<gitlab_url>/api/v4/projects/<gitlab_project_id>/terraform/state/<stack id>`.

Placeholder values the RUNBOOK leftover scan looks for: `example`, `1111111111`.

## Checks

`.pre-commit-config.yaml`, in execution order. "Both" means pre-commit and pre-push: the fast set re-runs at push to catch `git commit --no-verify`. `make check` runs the commit stage on every tracked file, `make check-all` both stages.

| Hook id | Source | Stage | Checks |
|---|---|---|---|
| `check-added-large-files`, `check-merge-conflict`, `check-yaml`, `end-of-file-fixer`, `mixed-line-ending` (lf), `trailing-whitespace` | pre-commit-hooks | both | hygiene; `check-added-large-files` runs with `--enforce-all` and `check-merge-conflict` with `--assume-in-merge` so both also work under `--all-files`; the three fixers skip the skill copy (`.agents/skills/`) |
| `gitleaks` | gitleaks | both | secrets in the staged changes (blind under `--all-files`) |
| `gitleaks-history` | gitleaks | pre-push | secrets in every commit (`gitleaks git --redact --verbose`), runs even when no file survives |
| `conventional-pre-commit` | conventional-pre-commit | commit-msg | Conventional Commits message |
| `terramate` | local | both | `terramate fmt`, `generate`, `list --run-order`: fails on rewritten `.tm.hcl`, stale or hand-edited generated files, duplicate stack ids, `after` cycles or typos, failed asserts (project name, environment name, folder name length, vCenter host, GitLab URL and project id, a boolean `vsphere_allow_unverified_ssl`, no vSphere provider in `extra_providers` under any name: the key `vsphere` or a `…/vsphere` source), a stack without `_terramate_generated_{backend,provider,versions,datacenter}.tf`; prints `hint: run "make generate"` when a stack has no id |
| `generated-versions` | local (pygrep) | both | generated versions still has the top-level `language { compatible_with { opentofu = ... } }` gate (OpenTofu ignores `required_version` in `.tf` files) |
| `generated-backend` | local (pygrep) | both | generated backend still has, line-anchored, `address` = `https://.../api/v4/projects/<digits>/terraform/state/<36-character id>` (a `user:token@` in the URL fails), `lock_address` and `unlock_address` = the same address + `/lock`, `lock_method = "POST"` and `unlock_method = "DELETE"`, and no `username`, `password`, `headers`, `skip_cert_verification` or `client_private_key_pem` line |
| `generated-provider` | local (pygrep) | both | generated provider still has, line-anchored, `vsphere_server = "<lowercase host[:port]>"` and `allow_unverified_ssl = true` or `false` (a literal), and no `user` or `password` line |
| `no-unverified-tls` | local (pygrep) | both | every `.tf` except the generated providers under `stacks/` (`generated-provider` owns those), line by line: fails on an `allow_unverified_ssl` or `skip_cert_verification` assignment whose value is not the literal `false` (`true`, a variable, a local, a hand-written provider alias, a one-line block); comment lines are ignored |
| `vsphere-provider-source` | local (pygrep) | both | every `.terraform.lock.hcl`: fails on any vsphere provider other than `registry.<host>/vmware/vsphere` (`hashicorp/vsphere` and `opentofu/vsphere` fail): a module that requires `hashicorp/vsphere`, or names no source (which means `hashicorp/vsphere`), brings a second provider that is configured from `VSPHERE_*` alone: not the pinned vCenter, TLS settings taken from the environment |
| `forbidden-files` | local | both | rejects state files, plans, crash logs, `.terraform/`, `.tofu` files and override files (`override.tf`, `*_override.tf`, `.json` forms): they silently replace the generated backend, provider and destroy guard |
| `tofu-test` | local | pre-push | `tofu test` in every module with mock providers; fails when a module has no tests, runs none, or leaves `errored_test.tfstate`; runs only when files under `modules/` exist (this folder ships none) |
| `terraform_fmt` | pre-commit-terraform | both | `tofu fmt` |
| `terraform_providers_lock` | pre-commit-terraform | both | every provider in every lock file has at least as many `h1:` hashes as configured platforms (darwin and linux, amd64 and arm64) and a `zh:` hash; it counts hashes, it does not check which platforms they belong to (offline) |
| `terraform_tflint` | pre-commit-terraform | both | tflint with preset `all` of the terraform ruleset (no vSphere ruleset exists) and exact registry-module versions |
| `terraform_docs` | pre-commit-terraform | both | regenerates `modules/*/README.md` between the `BEGIN_TF_DOCS` and `END_TF_DOCS` markers (only for modules) |
| `terraform_validate` | pre-commit-terraform | pre-push | `tofu validate`, serially, in every directory under `make check-all` and in the directories of changed files on a push; a directory without `.terraform` first gets `tofu init -backend=false -lockfile=readonly`, so the stacks' GitLab backend is never contacted (it exports no `TF_PLUGIN_CACHE_DIR`: see [Prerequisites](#prerequisites)); the hook sets `VSPHERE_USER` and `VSPHERE_PASSWORD` to `validate-placeholder` for its run, because validate fails on the generated provider block without them (`Missing required argument`) although it makes no connection; a provider from `extra_providers` whose schema requires an argument needs its own `--env-vars=<VARIABLE>=validate-placeholder` there (`ROS_USERNAME` for RouterOS) for the same reason |

- A hook that rewrites files (`end-of-file-fixer`, `terraform_fmt`, `terraform_docs`, `terramate`) fails the run: review the change, `git add` it, run again. `terramate fmt` formats `*.tm.hcl` files up front: run it after editing one by hand.
- `tofu`, `terramate` (the tenv shims), `tflint` and `terraform-docs` are system tools: no hook environment builds them, so they must be on the `PATH` of whatever runs git (a GUI git client or a minimal CI image often lacks Homebrew's `bin`). `make doctor` finds all of them.
- Network use of the hooks: `tflint --init` (`make setup`, `make update`) downloads the terraform ruleset from GitHub, and a first `tofu init` downloads the provider. `tofu validate` makes no request: in a test with the provider 2.17.1, `init`, `validate`, `test`, `fmt` and `providers schema` made no connection to the configured `vsphere_server` (a counting listener saw none; `plan`, as the control, made one).
- `make check`, `check-all`, `test`, `relock` and `doctor` unset every `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `GOOGLE_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `TF_HTTP_*` and `GITLAB_*` variable, plus `TENV_GITHUB_TOKEN`, `GH_TOKEN` and `HOMEBREW_GITHUB_API_TOKEN` (not `GITHUB_TOKEN`: `tflint --init`, which `terraform_tflint` runs, reads it) before pre-commit, tflint, tofu or a provider binary starts. Variables only: logins cached in config dirs (`~/.aws`, az, gcloud, `~/.govmomi`) are not isolated, and only `tofu-test` points the az, azd and gcloud config dirs at an empty temp dir. The git hooks that `make hooks` installs run with the environment of the process that runs git; inside them only `tofu-test` scrubs itself. `tofu init` starts no provider binary (no plugin launch in a TRACE log); `tofu validate` starts it and tflint its ruleset plugin, with your variables inside the git hooks (`terraform_validate` with the two placeholders above; validate does not configure the provider and made no request in a test; nothing enforces that it stays offline). The variable list lives in three places that must stay in step: `SCRUB` in the Makefile (`make setup` and `make update` use it through `INSTALL_HOOKS`), the `tofu-test` hook and `e2e.sh`.

### Disabled tools

| Tool | Reason | Instead |
|---|---|---|
| `terraform_trivy`, `terraform_checkov` | zero vSphere checks. trivy-checks (`checks/cloud`) covers aws, azure, cloudstack, digitalocean, github, google, kubernetes, nifcloud, openstack and oracle; checkov's terraform resource checks have no vSphere or VMware directory. A sample with the provider block, four data sources, `vsphere_folder` and `vsphere_virtual_machine`: trivy `Misconfigurations 0` (its 51 successes are AWS, Azure and GCP checks passing vacuously), checkov `passed 0, failed 0, resource_count 0`, both exit 0; their positive control, an `aws_s3_bucket`, failed 6 and 7 checks. Custom checks work in both (trivy Rego, checkov YAML) but are code to maintain | `generated-backend`, `generated-provider`, `no-unverified-tls`, `vsphere-provider-source` |
| `terraform_tfsec` | deprecated | none |
| `terrascan` | archived 2025-11 | none |
| `terraform_docs_replace`, `terraform_docs_without_aggregate_type_defaults` | deprecated or duplicate | `terraform_docs` |
| `infracost_breakdown` | needs an Infracost API key and network | none |
| `tfupdate` | stack constraints are Terramate globals; module pins are bumped in reviewed pull requests | [Upgrades](#upgrades) |
| `terraform_wrapper_module_for_each` | for module-publisher repositories | none |
| `terragrunt_*` | Terramate is the orchestrator | none |
| terramate-io/pre-commit-hooks | run bare commands at the git root; pass when generated files are missing | local `terramate` |
| `detect-private-key` | gitleaks covers it | `gitleaks` |
| yamllint, markdownlint, typos | style only (`check-yaml` covers YAML syntax) | none |
| shellcheck | `e2e.sh` is the only shell file and is optional (`make e2e`) | none |
| a vSphere tflint ruleset | none exists: the terraform-linters organisation has the rulesets aws, azurerm, google, terraform, opa and template, and a GitHub search for `tflint-ruleset` repositories matching vsphere, vmware, vcenter, esxi, broadcom, nsx or govmomi finds none | the terraform ruleset; `no-unverified-tls` |
| `tflint-ruleset-opa` | experimental (its README: "frequent breaking changes"). A Rego policy that flagged `allow_unverified_ssl = true` and a `vsphere_virtual_machine` without `storage_policy_id` worked with a hand-placed plugin; its `tflint --init` install was not tried | `no-unverified-tls` |

## CI contract

No pipeline file ships. After `make setup` (the runner needs `tofu`, `terramate`, `tflint` and `terraform-docs` on its `PATH`), a pipeline gates on exactly this, with `SKIP` unset, a full clone (history scan), `GITHUB_TOKEN` exported for `tflint --init`, and network for the first downloads ([Checks](#checks)):

```bash
make check-all
git diff --exit-code
test -z "$(git status --porcelain)"
```

- `check-all` is one run of the pre-push stage, which holds every commit-stage hook too (`default_stages`). A bare `pre-commit run --all-files` would skip the push-only hooks, `gitleaks-history` among them (`gitleaks` only sees staged changes).
- The last two commands catch rewrites and new untracked files (READMEs) that a hook can create while still reporting success.
- This is the only authoritative gate. `--no-verify`, `SKIP` and a missing `make hooks` bypass the local hooks, and deletion-only commits skip every file-based hook (only `gitleaks-history` always runs).
- Plan and apply need credentials and are out of scope for the template; the runbook is under [Operate](#operate). A GitLab CI job reaches the state with its job token, verified in runner jobs on GitLab CE 19.4.2:
  - `TF_HTTP_USERNAME=gitlab-ci-token` and `TF_HTTP_PASSWORD=$CI_JOB_TOKEN`. Another username gets 401, and the `JOB-TOKEN` header does not work against this backend (401).
  - The job token has the role of the user who triggered the pipeline (GitLab docs): a Developer's pipeline reads the state and cannot lock, write, unlock or delete a version (403); a Maintainer's can. Plan and apply need Maintainer.
  - From a project other than the state project, the state project's job token allowlist must include the pipeline's project (by default it holds only the project itself) and the triggering user needs a role in the state project. Fine-grained job token policies (`READ_TERRAFORM_STATE`, `ADMIN_TERRAFORM_STATE`, generally available since GitLab 18.3) were not tried.
  - The runner trusts the vCenter's CA like any operator machine ([Bootstrap](#bootstrap)); the vCenter account belongs in masked and protected CI/CD variables.

## Agent tooling

Project scope: instructions in [AGENTS.md](AGENTS.md); MCP servers in `.mcp.json`, read as is by Claude Code and omp (verified) and, per their documentation, by GitHub Copilot, VS Code and Devin; the skill `terraform-skill` ([Skill](#skill)).

| Server | Gives the agent | Where it runs | Credentials |
|---|---|---|---|
| `terraform-registry` | Terraform registry lookups: provider and module versions, resource schemas, docs (9 read-only tools) | local binary | none |

The provider is `vmware/vsphere`, so lookups need the namespace `vmware`: `get_latest_provider_version` answered 2.17.1 for `vmware/vsphere` and 2.12.0 for `hashicorp/vsphere`, a frozen legacy listing. The server queries registry.terraform.io, not registry.opentofu.org (checked 2026-10-18, terraform-mcp-server 1.3.0).

No documentation server for vSphere ships, because no official one exists: techdocs.broadcom.com and developer.broadcom.com serve neither `/llms.txt` nor `/mcp` (404), and GitHub searches for MCP repositories under the vmware, vmware-samples and vmware-archive organisations found none (2026-10-18). Third-party servers that answered without authentication (not shipped, answer quality not evaluated, every query leaves your machine): Context7 (`https://mcp.context7.com/mcp`) and DeepWiki (`https://mcp.deepwiki.com/mcp`, AI-generated content). Add one to your own MCP config by hand if you want it.

Why the `terraform-registry` command looks like this: `--toolsets=registry` keeps the 9 read-only registry tools (without it a TFE token in `~/.terraform.d/credentials.tfrc.json` exposes 56 tools, 19 of them without a read-only hint); `env -u TFE_TOKEN -u TFE_ADDRESS HOME=/nonexistent` stops the binary from reading and sending that token, and makes it log `failed to create TFE client ... /nonexistent` to stderr on every start: by design, not a failure.

vCenter and GitLab API access (credentials, sessions) is not shipped: the entry above is lookup-only and credential-free. Third-party vCenter management MCP servers exist; they need vCenter credentials. If you add a credentialed server yourself, keep it out of `.mcp.json` in the repository.

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

No state stack and nothing applied first: the state lives in GitLab, and a stack's state record appears with its first lock or write (a plan creates it). What you set up, once per project (once more for a separate prod state project), is a GitLab project with a token, and for each vCenter the trust and an account. The GitLab facts below were measured on GitLab CE 19.4.2, the version `make e2e` runs; the vCenter side is not evaluated against a real vCenter.

**GitLab**

1. Create the state project. Private, with only the people who may read every state: any member with the Developer role or higher can download every state of the project ([GitLab docs](https://docs.gitlab.com/user/infrastructure/iac/terraform_state/)). On a self-managed instance state storage is on by default (the state API worked on a fresh CE 19.4.2 container without any setting); administrators can move it ([docs](https://docs.gitlab.com/administration/terraform_state/)).
2. In **Settings > General > Visibility, project features, permissions** keep **Infrastructure** enabled. Disabled, the state API answers 403 to everyone, an administrator included, and tofu prints `HTTP remote state endpoint invalid auth`.
3. Note the numeric project id: it is `gitlab_project_id` ([Parameters](#parameters)).
4. Create a project access token (**Settings > Access tokens > Add new token**) with the role **Maintainer** and the scope **api**, and an expiration date. Both are the minimum: lock, write, unlock and `force-unlock` need Maintainer, a plain `tofu plan` takes the lock too, and a `read_api` token can read but its lock call gets 403 `insufficient_scope`. Deploy tokens are never accepted. The token acts as its bot user (`project_<id>_bot_...`). It expires at midnight UTC on the chosen date (365 days when you leave the date empty, which is also the maximum unless an administrator raised it): note the date, because every operator and pipeline stops at once. Maintainers get an email 7 days before (and 30 and 60 days before on GitLab 17.6 and later). **Rotate** on the same page makes a new token with the same role and scope and revokes the old one at once: check the new token's expiry date, because through the API a rotated token lives one week unless you pass `expires_at` ([GitLab docs](https://docs.gitlab.com/api/project_access_tokens/#rotate-a-project-access-token)). A personal access token also works, but it carries your role in every project you can reach: do not.
5. Export the credentials in the shell that runs tofu, never in a file of the project:

| Variable | Value |
|---|---|
| `TF_HTTP_USERNAME` | any non-empty string (empty with a password set: no `Authorization` header, 401); exactly `gitlab-ci-token` with a CI job token |
| `TF_HTTP_PASSWORD` | the project access token |
| `VSPHERE_USER`, `VSPHERE_PASSWORD` | the vCenter account of the environment ([Deployer permissions](#deployer-permissions)) |

The generated blocks carry no credentials (the hooks fail on any) and `-backend-config` is not used: its values are stored in `.terraform` and in plan files. The environment cannot redirect a stack: a value in the block beats its `TF_HTTP_*` variable (observed: a block `address` beat `TF_HTTP_ADDRESS`), and the generated `vsphere_server` and `allow_unverified_ssl` beat `VSPHERE_SERVER` and `VSPHERE_ALLOW_UNVERIFIED_SSL` (observed against vcsim with the generated `false`; a generated `true` beat an exported `VSPHERE_ALLOW_UNVERIFIED_SSL=false` too, observed with provider 2.17.1 against a local HTTPS stub with a self-signed certificate: the handshake passed, so exporting `false` does not turn verification back on).

**vCenter**

TLS is verified unless an environment sets `vsphere_allow_unverified_ssl = true`, a reviewed decision for a lab whose vCenter certificate nothing trusts: the provider then logs in to whoever answers. The provider has no CA option (its only TLS argument is `allow_unverified_ssl`), so every machine that runs tofu must trust the certificate chain of each verified vCenter, and `vsphere_server` must be a name that the certificate lists. Unless you installed your own, vCenter's certificates come from its VMware Certificate Authority (VMCA), which no machine trusts yet.

1. Download the root certificates from the vCenter: open `https://<vcenter>/` and click **Download trusted root CA certificates** (bottom of the grey box on the right), or fetch `https://<vcenter>/certs/download.zip` ([Broadcom KB 330833](https://knowledge.broadcom.com/external/article/330833/how-to-download-and-install-vcenter-serv.html), which documents both). Check the root's fingerprint against a source you trust: this first download cannot verify itself.
2. Unzip it. The `certs` folder holds the root certificates (extensions `.0`, `.1`, ...) and their CRLs (`.r0`, `.r1`, ...): trust the certificates, ignore the CRLs.
3. Install the certificates into the trust store of the machine (standard OS commands, not completed or run here):
   - macOS: trust the root for TLS, meant for this one host (`-s`), in your own login keychain, with the command below. macOS asks for authorization in a dialog (per `man security`): run it in your own Terminal (started from an agent it waited 240 s and 300 s and no dialog appeared, observed; that it appears in your own Terminal was not tested here). `<vcenter>` is the host name of `vsphere_server` without a port, `<root>` the unzipped certificate file: `security add-trusted-cert -r trustRoot -p ssl -s <vcenter> -k ~/Library/Keychains/login.keychain-db <root>`. Check first, which changes no trust: `openssl s_client -connect <vcenter>:443 -servername <vcenter> </dev/null 2>/dev/null | openssl x509 > leaf.pem` (the port of `vsphere_server` instead of 443 when it names one), then `security verify-cert -c leaf.pem -r <root> -p ssl -n <vcenter> -L` (rc 0 and `certificate verification successful`; a wrong root gives `CSSMERR_TP_NOT_TRUSTED`, a wrong host name `Host name mismatch`; tested with a scratch CA). Undo: `security remove-trusted-cert <root>`. The vSphere provider uses the system verifier there: it ignored `SSL_CERT_FILE` and `SSL_CERT_DIR` (observed against vcsim, with a custom and with the default certificate). Neither that `-s` limits the trust to that host (`man security`: 'policy-specific string') nor that the provider accepts a host-scoped trust was tested: both need a trust change.
   - Linux (Debian, Ubuntu): copy each as `<name>.crt` to `/usr/local/share/ca-certificates/` and run `sudo update-ca-certificates`; Fedora and RHEL: `/etc/pki/ca-trust/source/anchors/` and `sudo update-ca-trust`. On Linux the provider also honours `SSL_CERT_FILE` and `SSL_CERT_DIR` (observed in a Linux container against vcsim with a CA-signed certificate).
4. When GitLab's certificate comes from a private CA too, trust that CA the same way. Only the system store serves both binaries on macOS: tofu honoured `SSL_CERT_FILE` there (against GitLab behind a private-CA TLS terminator), the provider did not. For the backend alone, `TF_HTTP_CLIENT_CA_CERTIFICATE_PEM` (the PEM text, not a path) also worked there; the generated block does not set that attribute, so the variable fills it.

Failures to expect (all texts observed, the TLS ones against vcsim):

| Message | Cause |
|---|---|
| `Error refreshing state`, `HTTP remote state endpoint requires auth` (at `init`) | no, wrong, revoked or expired token (401) |
| `HTTP remote state endpoint invalid auth` | a valid token that may not do it (403): role below Maintainer at the lock, a `read_api` scope, or **Infrastructure** disabled |
| `Error acquiring the state lock`, `Unexpected HTTP response code 404` | a token without access to the project. `init` still passes (404 reads as an empty state): only the lock proves access |
| `Unexpected HTTP response code 405` at the lock | a backend block without `lock_method = "POST"`, or a path-form address of a renamed project |
| `HTTP remote state already locked` | a lock is held ([Operate](#operate)) |
| `tls: failed to verify certificate: x509: certificate signed by unknown authority`, or on macOS for a custom CA `tls: failed to verify certificate: x509: “<name>” certificate is not trusted` (at `plan` and `apply`; `init` does not configure the provider) | the vCenter's CA is not trusted ([above](#bootstrap)) |
| `x509: certificate is valid for <names>, not <host>` | `vsphere_server` is not a name in the certificate |

First run, per environment (the first plan creates each stack's state record in GitLab; read the plan, a `folder` stack shows `Plan: 1 to add`, 2 with `protect_destroy` for the guard):

```bash
cd stacks/<environment>
terramate run -- tofu init
terramate run -- tofu plan -out=tfplan
```

## Operate

Run from `stacks/<environment>`: the vCenter credentials in your shell belong to that environment, and `terramate run` at the project root would present them to the vCenter of every environment (and a separate prod state project needs its own token). Export `TF_PLUGIN_CACHE_DIR` first ([Prerequisites](#prerequisites)).

```bash
cd stacks/<environment>
terramate run -- tofu init                                       # first time, and after lock or provider changes
terramate run -- tofu plan -out=tfplan                           # then read every stack's plan
terramate run -- tofu apply tfplan                               # applies exactly the reviewed plans
```

- Credentials only through the environment ([Bootstrap](#bootstrap)). Never `VSPHERE_CLIENT_DEBUG` (it writes the SOAP calls to `~/.govmomi/debug`, world-readable, with the session cookie in the response headers) and never `VSPHERE_PERSIST_SESSION` (it writes the cookie to `~/.govmomi/sessions`) in a shared shell. The provider does not log out: without session persistence every run leaves a vCenter session until it times out (provider docs; vCenter's own limit applies).
- Never `-auto-approve`. A stale or already applied plan is refused.
- Never `-lock=false`. A token without access to the project reads 404 as an empty state: `plan -lock=false` then shows `Plan: 1 to add` for an object that exists (observed with a one-resource stack). The lock is what proves access. A Developer can only run such a plan (the lock needs Maintainer): do not hand out `-lock=false` as a workaround, give the role.
- `-detailed-exitcode` is unusable under `terramate run`: exit code 2 counts as failure.
- Safeguards stay on: `terramate run` refuses an uncommitted or untracked tree, outdated generated code and a checkout behind its remote (if you add an `origin`, push `main` to it before the first `terramate run`: the git safeguard calls `git ls-remote`; without a remote the check is skipped). Do not use `-X`; `tfplan` is gitignored, so it does not trip them.
- A stuck lock: a run that died (closed terminal, `kill -9`, timeout) leaves its lock, and GitLab has no lock timeout. The next plan or apply in that stack stops with `Error acquiring the state lock`, `HTTP remote state already locked: ID=<LOCK_ID>` and a `Lock Info:` block (`ID`, `Path`, `Operation`, `Who`, `Version`, `Created`). `Who` is a GitLab username, not `user@host`: a project access token is its bot user (not run). First make sure no other run holds the lock: ask whoever `Who` names and check your pipelines. Then, in that stack's directory with a Maintainer token, run `tofu force-unlock <LOCK_ID>` with the `ID` from the message and answer `yes`; a wrong id is refused (`Failed to unlock state: Unexpected HTTP response code 409`) and the lock stays. **Operate > Terraform states > Actions > Unlock** in GitLab does the same without the id. A normal exit releases the lock.
- History: every write is a state version, numbered by `serial`. `GET <gitlab_url>/api/v4/projects/<id>/terraform/state/<stack id>/versions/<serial>` returns one (Developer or higher; there is no REST list of versions, and the UI downloads only the latest). `DELETE` on a version needs Maintainer, and deleting the latest one rolls the state back to the previous serial (observed on CE 19.4.2: after deleting serial 40 the state was serial 39). That is a rollback of the record, not of vSphere: the next plan shows the difference. Download the versions you may need before deleting any; GitLab keeps every version and has no retention setting.
- GitLab lists the states by stack id (**Operate > Terraform states**, with their lock status). `grep -rn '^ *id *=' stacks --include=stack.tm.hcl` maps an id to its stack.

Destroy, only after the destroy plan was shown and confirmed:

```bash
terramate run --reverse -- tofu plan -destroy -out=tfplan   # read every resource it deletes
terramate run --reverse -- tofu apply tfplan
```

- Protected environments (`protect_destroy = true`, prod by default): `tofu destroy` and `plan -destroy` fail with `Resource instance cannot be destroyed`. Flip `protect_destroy` in a reviewed pull request and run `make generate` (the guard files disappear in the diff) before planning the destroy; when the work is done, revert the flip and run `make generate` in a second reviewed pull request. Limit: `-target` and `-exclude` plan destroys past the guard. OpenTofu 1.13 prints `-exclude="terraform_data.destroy_guard"` in the refusal itself: do not follow that hint.
- vCenter's own folder destroy removes every VM inside the folder from disk ([vSphere API](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.Folder.html)). The provider refuses to do that: deleting a non-empty `vsphere_folder` fails with `folder is not empty, please remove all items before deleting` (read from the provider source, v2.17.1; not run). Stacks that put VMs into the folder declare `--after ../folder`, so the reverse destroy removes them first.
- A destroy leaves each stack's state record, now empty, in GitLab (OpenTofu writes the empty state, it does not delete the record; not run). Remove it in **Operate > Terraform states** (Maintainer) when the stack is gone for good.

## End-to-end rehearsal (`make e2e`)

Optional, not part of `check-all`: it replays [Operate](#operate) and Destroy with this project's own files against [vcsim](https://github.com/vmware/govmomi/tree/main/vcsim), the vCenter simulator of govmomi, and [GitLab CE](https://hub.docker.com/r/gitlab/gitlab-ce), both in Docker. It runs only the stacks tagged `folder` (`terramate list --tags folder`, `terramate run --tags folder`; "stack" below means one of them): a workload stack adopts VMs, templates and OVAs that vcsim does not have, so it is never rehearsed, and a green run says nothing about it. Do not tag another stack `folder` to opt it in: the tag also makes `make generate` write the folder resource into it. A script, not [Bootstrap](#bootstrap), creates the GitLab project and tokens it needs (as an administrator), so the token role and the CA trust of Bootstrap are not rehearsed. Run it after changing generators or the version pins, or to try newer images.

```bash
make e2e                  # about 3 minutes (4 on the first run, which pulls about 1.5 GB); needs macOS with Docker Desktop (about 3.5 GiB of free memory for GitLab), docker, curl, git, the pinned tofu and terramate (make setup) and the project's git checkout
E2E_VERBOSE=1 make e2e    # the same, streaming the output of every step (it prints the throwaway GitLab's root token, useless after the run)
```

It works on a throwaway copy of your tracked and unignored files (your tree and `.terraform` directories stay untouched), against a GitLab and a vcsim container on random `127.0.0.1` ports (no Docker socket, no mount, no inherited environment; removed with their volumes on every exit). GitLab starts first because it is the slow one (about 2 minutes until `/-/readiness?all=1` answers); vcsim starts with an empty inventory (`-dc 0`). "First stack" below is the first stack whose generated provider verifies certificates (`allow_unverified_ssl = false`), and the first stack of the tree when none does. The shipped tree runs 31 steps (30 when no stack verifies, because the TLS drill is skipped):

- vcsim gets every datacenter that the generated `_terramate_generated_datacenter.tf` files of these stacks name (one per distinct name), from a scratch module with the stacks' provider pin and lock and local state; the provider waits 5 s per datacenter, a hard-coded delay.
- Tripwire drill, first stack: with the generated backend untouched, `tofu init` must die at the dead proxy (`proxyconnect`); it runs without retries and with a data directory of its own.
- GitLab gets a root token (`gitlab-rails runner`, 30 s: the password grant is off, so there is no other way in), a private project for the states, and a user `outsider` who is not a member of it, with an `api` token of their own.
- Per stack, a gitignored `e2e_override.tf` (the `*_override.tf` ignore rule keeps it away from Terramate's safeguards) derived from the generated files: the backend half is the generated block with `https://<gitlab host>/api/v4/projects/<id>/` replaced by `http://127.0.0.1:<port>/api/v4/projects/<e2e project id>/` in `address`, `lock_address` and `unlock_address` (same state name, lock paths and methods; the script dies unless exactly three URLs were rewritten); the provider half sets `vsphere_server = "127.0.0.1:<port>"` and `allow_unverified_ssl = true`. The first stack gets only the backend half until the drills below have run; then every stack gets both.
- Tripwire drill, with only the backend redirected: `tofu plan` must die at the proxy on the stack's own vCenter host (`proxyconnect`, and the host is in the message).
- TLS drill, only while the first stack verifies (when none does, the run prints `--   TLS drill skipped: every stack sets vsphere_allow_unverified_ssl = true` and goes on), still with only the backend redirected and a provider override that sets only `vsphere_server` to vcsim: `VSPHERE_ALLOW_UNVERIFIED_SSL=true tofu plan` (exported for that one command) must fail with `x509:`, and the message must name vcsim's `127.0.0.1:<port>`. The generated `allow_unverified_ssl = false` beats the variable; on macOS the message is `Error: error setting up new vSphere SOAP client: Post "https://127.0.0.1:<port>/sdk": tls: failed to verify certificate: x509: certificate signed by unknown authority`.
- Operate, per environment from `stacks/<environment>`: saved-plan `terramate run --tags folder` init, plan and apply; every stack's state exists in GitLab under its generated name (a REST `GET` returns a body with a `lineage`); a second plan shows `No changes` (`-detailed-exitcode`, which would fail `terramate run` on exit code 2).
- On the first stack of each environment: a held lock (`tofu console` on a fifo) refuses a second plan with `HTTP remote state already locked` (GitLab answers 409) and is then released; the token of the non-member is refused at the lock with `Unexpected HTTP response code 404` and never plans on an empty state.
- Destroy: the reverse destroy of an unprotected environment; the guard's refusal where `protect_destroy = true` (`Resource instance terraform_data.destroy_guard has prevent_destroy`).

Each step prints `..` and its label when it starts and `ok` and the label when it passes, so the minutes of waiting for GitLab are not silent; a passing run ends with `e2e: all checks passed in <n>s; vcsim and GitLab removed on exit, your vCenter and GitLab never contacted`. A failing step shows the last 30 lines of its output (with `E2E_VERBOSE=1` all of it is already on screen) and stops the run with `e2e: FAILED: <label>`. A project that cannot be rehearsed fails before any container starts: `e2e: no folder stack (tag folder) under stacks/<environment>/<datacenter>/ in the project`, `e2e: <stack> has no generated <file> file: run make generate`, or `e2e: <stack> has no .terraform.lock.hcl: run make relock`. The lock files must exist: an `init` that creates one makes `terramate run` stop with `repository has untracked files`.

Measured on macOS (arm64) with Docker Desktop 29.8.2 (7.75 GiB, 10 CPUs): 171 to 186 s with the images cached (the later runs include the TLS drill), 239 s in the one run that pulled them (GitLab 67 s, vcsim 2 s). GitLab's boot is about 2 minutes of it (ready 119 to 123 s after the wait step starts) and the root token 30 s; the vcsim datacenters take 5 to 6 s, and everything after them, both environments, took about 13 s in the runs before the TLS drill. GitLab peaked at 3.15 to 3.29 GiB in five runs (about 2.5 GiB at rest) and vcsim used about 70 MiB; the images take 3.74 GB and 39 MB of disk. No run left a container, volume or temporary directory behind.

It cannot reach a real vCenter or GitLab: the script unsets every `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `GOOGLE_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `GITLAB_*`, `TF_*`, `GIT_*`, proxy and token variable, the only credentials are fake vCenter ones and the tokens of the throwaway GitLab, the only redirects are the override files that point at loopback ports, and every other host dies at a dead proxy (`HTTPS_PROXY`, `HTTP_PROXY` and `ALL_PROXY` at `127.0.0.1:9`), proven by a `curl` before the run and by the two drills during it. A run with hostile variables (`VSPHERE_SERVER`, `GOVC_URL`, `TF_HTTP_ADDRESS`, `HTTPS_PROXY` and `AWS_ENDPOINT_URL` pointing at a loopback canary, `TF_CLI_ARGS_plan=-lock=false`, tokens) passed, and the canary saw no connection. The network is needed for registry.opentofu.org, github.com and release-assets.githubusercontent.com (the provider zip and its checksums redirect there; without it `init` dies at the proxy), and for Docker Hub: the Docker daemon pulls the images, and the dead proxy does not touch it.

| It shows | It cannot show |
|---|---|
| `tofu`, the provider and Terramate accept the generated backend, provider, versions, datacenter, folder and guard blocks under Terramate's safeguards; the folder is created in vcsim, a second plan has no drift, the destroy works; the generated provider of a verifying stack (the default) keeps verifying certificates (with `VSPHERE_ALLOW_UNVERIFIED_SSL=true` exported, a plan against vcsim still fails with `x509`) | a real vCenter: vcsim reports 6.5.0; privileges, roles, name rules, timings and version-dependent provider paths are untested, and only `data.vsphere_datacenter` and `vsphere_folder` were exercised; any stack not tagged `folder`, which is never run |
| GitLab CE 19.4.2 accepts the generated `http` backend and keeps one state per stack id under the generated name; a held lock refuses a second plan and is released; a non-member is refused at the lock instead of planning on an empty state | GitLab roles: every happy-path call uses root, an administrator, so the Maintainer minimum and the Developer and job token behaviour come from the separate measurement in [Deployer permissions](#deployer-permissions), not from the rehearsal; also your GitLab's TLS, settings and protected-state rules |
| an unredirected backend or vCenter host dies at the dead proxy | a successful verified connection: vcsim's certificate is self-signed and nothing trusts it here, so only the refusal path runs (not even that when every stack sets `vsphere_allow_unverified_ssl = true`), and the rehearsal's own overrides use plain HTTP to GitLab and `allow_unverified_ssl = true`. No real vCenter certificate chain or VMCA trust is exercised; `generated-provider` (the generated file) and `no-unverified-tls` (every other `.tf`) guard the setting |
| the destroy guard refuses a protected environment; an unprotected one is destroyed | provider behaviour that vcsim does not model (its known drifts: [Not covered](#not-covered)) |

Knobs, all optional environment variables:

| Variable | Default | Use |
|---|---|---|
| `E2E_VCSIM_IMAGE` | `vmware/vcsim:v0.56.0` | pin another tag or digest. v0.56.0 is the govmomi release that provider 2.17 builds on; `latest` is an older build (v0.55.2 on 2026-10-18). The image exists for linux/amd64 only: Docker Desktop on Apple Silicon runs it under emulation (about 0.9 s to answer against 0.65 s native) |
| `E2E_GITLAB_IMAGE` | `gitlab/gitlab-ce:19.4.2-ce.0` | pin another tag to try a newer GitLab (19.5.0-ce.0 existed on 2026-10-15); the image is multi-arch |
| `E2E_VERBOSE` | unset | `1` streams the output of every step live (493 lines for the shipped tree, with make's); any other value: only a failing step shows its last 30 lines |

Run on macOS with Docker Desktop only: it is the only host this was verified on. A new image can change the result: both defaults are pinned tags, never `latest`.

## Grow the tree

| Add | How |
|---|---|
| stack | `terramate create`, then write `main.tf` |
| datacenter | copy `stacks/<environment>/<datacenter>` to `stacks/<environment>/<new datacenter>` (the folder name is the datacenter name), then `make generate` |
| environment | copy `stacks/<environment>` to `stacks/<new environment>` (the folder name is the environment name), set its `vsphere_server` (and `protect_destroy = true` if protected) |

New stack:

```bash
terramate create stacks/<environment>/<datacenter>/<stack> --name <stack> --description "..." --after ../folder
# write main.tf (and outputs.tf) in the new directory; it already has the generated backend, provider, versions and datacenter lookup
(cd stacks/<environment>/<datacenter>/<stack> && tofu init -backend=false)    # creates .terraform.lock.hcl; commit it
```

`--after ../folder` runs the stack after the folder (and, in a reverse destroy, before it): drop it for a stack that does not use the folder. `terramate create` cannot set tags (its `--tags` is a filter): add `tags = [...]` to `stack.tm.hcl` by hand; only `folder` uses one.

New datacenter or environment, by copying:

```bash
cp -R stacks/<existing> stacks/<new>      # a datacenter instead: stacks/<environment>/<existing> and stacks/<environment>/<new>, in every line
find stacks/<new> -name .terraform -type d -prune -exec rm -rf {} +
find stacks/<new> -name stack.tm.hcl -exec sed -i.bak '/^[[:space:]]*id[[:space:]]*=/d' {} + && find stacks/<new> -name '*.bak' -delete
$EDITOR stacks/<new>/globals.tm.hcl       # an environment: vsphere_server (a datacenter needs no edit: the folder name is the datacenter)
make generate                             # new ids = new state names (copied ids fail with "duplicated ID"), then writes the new backend files; commit them
```

The lock files are copied along and stay valid (same providers). Commit, then plan the new stacks ([Operate](#operate)).

- Every stack gets `data.vsphere_datacenter.this`: place objects with `data.vsphere_datacenter.this.id`. tflint (`terraform_unused_declarations`) flags a stack that never uses it, a vCenter-wide stack for example; a note in `generate.tm.hcl` says to add a stack-tag condition for the first such stack.
- `folder_path` is the output to pass on as the folder of a VM (not evaluated). Registry modules for VMs: see [Design decisions](#design-decisions) before adopting one.
- State names are stack ids, so a moved stack keeps its state, and a stack moved to another environment or datacenter then plans with that state against a different vCenter or datacenter: copy instead of moving across (not run).
- `environment` and `datacenter` are the first two folder names under `stacks/` (`globals.tm.hcl`): add a new level below `<datacenter>/` (the stack level) and adjust the relative `source` of any hand-written stack that calls a local module.
- A copied environment keeps the source's `vsphere_allow_unverified_ssl` (set in its `globals.tm.hcl`): the copy of a lab environment skips the certificate check too, until you change it.
- Another provider goes into `extra_providers` in the stack's own `globals.tm.hcl` (shape: the stack row under [Layout](#layout)); then `make generate` and `make relock`. `make generate` merges it into the one generated `required_providers` block (a hand-written second block fails `init` with `Duplicate required providers configuration`). One level only: a lower level replaces the whole value instead of merging, and a self-reference (`tm_merge(global.extra_providers, ...)`) fails; an assert refuses a vSphere provider under any name (the key `vsphere` or a `…/vsphere` source), because `vsphere_provider_version` pins that provider. Before the relock, `terraform_validate` fails on the missing lock entry while `terraform_providers_lock` passes (tested in a scratch copy with `hashicorp/random`).
- The credentials of that provider come from its own environment variables, never from code. A provider whose schema requires an argument also needs its own `--env-vars` line on `terraform_validate`, and its variable prefix goes into the unset lists (the placeholder form and the places: [Checks](#checks)). Its own TLS switches (`insecure`, `skip_tls_verify`) are reviewed like code: `no-unverified-tls` knows only `allow_unverified_ssl` and `skip_cert_verification`.

### Adopt existing infrastructure

Objects that an older root module already manages can move into a stack without being recreated: the stack imports them, then the old root forgets them. The mechanism was run with `terraform_data` on OpenTofu 1.13.1, not against a vCenter. The agent never runs tofu in another repository: the steps in the old root are the user's.

```hcl
# in the stack, imports.tf: one block per object, the resource written at the address the old root used
import {
  to = <address>
  id = "<id>"
}

# in the old root, only after the stack's next plan shows `No changes` (step 5)
removed {
  from = <address>
  lifecycle {
    destroy = false
  }
}
```

1. Per object, an `import` block in the stack's `imports.tf` at the old resource address (`id` is the import id that the resource's provider documents).
2. The first plan must show the imports, in a protected environment also the generated `terraform_data.destroy_guard`, and in-place changes you can explain (an import followed by a change is normal: `Plan: 1 to import, 0 to add, 1 to change, 0 to destroy` in the test). Never a destroy or a replacement of an imported object: stop.
3. Apply from a reviewed saved plan ([Operate](#operate)).
4. From then on nobody applies in the old root module, and its CI is disabled: both states list the object (observed in the test), so a run there would act on what the stack now owns.
5. Retire the old ownership only after the stack's next plan shows `No changes`: in the old root, replace each adopted resource with the `removed` block above. Keep `lifecycle` explicit: `destroy = true` destroys (`1 to destroy` in the test, against `1 to forget` with `false`). The old root must run OpenTofu or Terraform 1.7 or newer, and its provider stays configured, because the plan still refreshes. Its plan must show `0 to destroy` and say that the object will not be destroyed (OpenTofu: `will be removed from the OpenTofu state but will not be destroyed`). One reviewed apply, by the user.
6. Never delete an old state while it lists resources. A GitLab state that is empty after step 5 may be deleted (Maintainer, **Operate > Terraform states**; the deletion removes every version and cannot be undone), but only after its last serials are kept outside the repository (the `GET .../versions/<serial>` of [Operate](#operate); old states hold secrets in plaintext, and `forbidden-files` rejects a `*.tfstate` that lands in the repository). Archive the old project last; whether an archived project still accepts state writes is unverified.

## Upgrades

Each of these in its own pull request.

| What | Where | Then |
|---|---|---|
| OpenTofu, Terramate | `.tool-versions`; `terramate.tm.hcl` `required_version` when the Terramate minor changes | `make setup` (installs the pins), `make doctor` |
| Homebrew tools (terraform-docs, tenv, pre-commit, terraform-mcp-server) | the `Brewfile` lists them without versions | `brew upgrade <name>`, yours to run (`make setup` installs what is missing and keeps installed formulae; the doctor only checks that they run), then `make doctor` and `make check-all` |
| vSphere provider constraint | `vsphere_provider_version` in `globals.tm.hcl`; for modules `modules/*/versions.tf` | `make generate`, then `make relock` |
| Non-vSphere provider | the `version` in `extra_providers` of the stack's `globals.tm.hcl` | `make generate`, then `make relock` |
| Registry module | exact `version` in the stack's `main.tf` (OpenTofu intersects its own provider floor with `vsphere_provider_version`; nothing is promoted into the global) | `make relock` |
| Hook revisions, tflint ruleset | `.pre-commit-config.yaml` (plain tags), the plugin `version` in `.tflint.hcl` | `make update` (newest tag on each hook repository's default branch: for gitleaks that can lag its newest release), then `make check-all` |
| terraform-skill | `.agents/skills/terraform-skill` | `make skill`, then review `git diff -- .agents/skills` ([Skill](#skill)) |
| vcsim and GitLab images of the rehearsal | `E2E_VCSIM_IMAGE` and `E2E_GITLAB_IMAGE` in `e2e.sh` | `make e2e` with the new tag ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)); a newer GitLab than the rehearsed 19.4.2 is yours to try |

`make relock` runs `tofu init -backend=false -upgrade` in every stack (`terramate run --disable-safeguards=git`, needed because `make generate` just dirtied the tree; the outdated-code safeguard stays on) and in every `modules/*/` (none ship). Finish with `make check-all`.

`make update` runs `pre-commit autoupdate` (plain tags, not SHAs), moves the terraform ruleset in `.tflint.hcl` to the newest release tag of its source repository (`tflint ruleset <old> -> <new>`, or `tflint ruleset already at <v>`) and builds the hook environments of the new revisions (`pre-commit install-hooks`). It always verifies TLS and leaves OpenTofu, Terramate and the providers alone. Its last line is `review "git diff", run "make check-all", commit`.

## Deployer permissions

Least privilege for whoever runs `terramate run`: a GitLab token for the state and a vCenter account for the objects. There are no placeholders to replace.

**GitLab**: the role and scope of the token in the state project. Measured on GitLab CE 19.4.2 with project members of each role and a non-member (`make e2e` rehearses root, an administrator, and a non-member only); the scope is `api`, because a `read_api` token cannot lock (403 `insufficient_scope`). Owner behaves like Maintainer per the GitLab docs (not run).

| Role in the state project | `tofu init` | `tofu plan` and `apply` (both take the lock) | `force-unlock`, delete a state or a version | `GET .../versions/<serial>` |
|---|---|---|---|---|
| Guest, Reporter | fails: `Error refreshing state` | refused (403): `HTTP remote state endpoint invalid auth` | refused (403) | refused (403) |
| Developer | passes | refused at the lock (403) | refused (403) | allowed |
| Maintainer | passes | allowed | allowed | allowed |
| not a member | passes: 404 reads as an empty state | refused at the lock: `Unexpected HTTP response code 404` | 404 | 404 |

A Developer can read states and run `plan -lock=false` (no lock, no write), the flag this project forbids ([Operate](#operate)). Project access tokens carry the role you pick for them; one token per state project.

**vCenter**: the account of an environment, for the `folder` stack. Not evaluated against a real vCenter: the table follows the privilege names in [Broadcom's Folder privileges](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere/8-0/vsphere-security/defined-privileges/folder-privileges.html) and the notes in the provider's docs; try it with a test account in a sandbox datacenter before relying on it.

| For | Privilege (API name) | Assign on |
|---|---|---|
| the datacenter lookup and every read | `System.Anonymous`, `System.Read`, `System.View`: the built-in Read-only role, and what every new custom role starts with ([Broadcom](https://techdocs.broadcom.com/us/en/vmware-cis/aria/aria-operations/8-16/vmware-aria-operations-configuration-guide-8-16/connect-to-data-sources/vsphere/configuring-a-vcenter-server-cloud-account-in-vrealize-operations/privileges-required-for-configuring-a-vcenter-adapter-instance.html)). The provider also reads tags and events: its docs ask for access to both | the datacenter, propagated |
| creating the VM folder | `Folder.Create` | the datacenter's `vm` folder, propagated |
| renaming it (a changed project or environment name) | `Folder.Rename` | the same |
| deleting it (destroy) | `Folder.Delete`, on the folder and on its parent | the same |
| moving it (only when its `path` gets another parent: this template never does) | `Folder.Move`, at source and destination | the same |

Add what the stacks you write manage (VMs, datastores, networks, tags). The provider needs a vCenter account with API write access: the free ESXi hypervisor is not supported (provider docs).

## Design decisions

1. **Environment = one vCenter binding**: `stacks/<environment>/<datacenter>/<stack>`. Each environment pins one vCenter (`vsphere_server`); environments may share one. Credentials, protection and, if you want it, the state project follow the environment, so you operate one environment at a time. No workspaces: the `http` backend has none (`tofu workspace new` fails with `workspaces not supported`).
2. **GitLab-managed state, one state per stack, named by the stack id**: no bucket to bootstrap or pay for, and locking, versions and access control come with the GitLab project. Moving a folder cannot orphan state; ids come from `make generate` (`terramate create --ensure-stack-ids`) and are never copied, so every project gets fresh state names. The cost is a dependency: GitLab must be up for every plan and apply, and a GitLab that runs on the vSphere these stacks manage cannot be recovered through them (GitLab docs: "If the instance goes offline, you cannot access or decrypt your state files").
3. **`lock_method = "POST"`, `unlock_method = "DELETE"` and an `unlock_address`**: OpenTofu's defaults (`LOCK`, `UNLOCK`) get GitLab's 405, and without `unlock_address` OpenTofu takes the lock and never releases it (read from its source, not run). `generated-backend` checks all three.
4. **TLS is verified unless a reviewed global says otherwise**: the generated provider sets `allow_unverified_ssl` from `vsphere_allow_unverified_ssl` (default `false`; a boolean, asserted; a value in code beats `VSPHERE_ALLOW_UNVERIFIED_SSL`), `generated-provider` requires a literal `true` or `false`, `no-unverified-tls` keeps every other `.tf` at the literal `false`, and `generated-backend` fails on `skip_cert_verification` (GitLab's TLS has no knob). With the default, a drill in `make e2e` shows it (a plan with the variable exported still fails on vcsim's certificate). You trust the vCenter's CA instead. The cost: every machine that runs tofu needs it, and on macOS `make e2e` cannot verify a connection (the provider ignores `SSL_CERT_FILE` there), so after that drill the rehearsal runs the provider with `allow_unverified_ssl = true` on loopback only. A lab whose CA nothing trusts sets the global to `true` for that environment, in a reviewed change: nothing then stops a machine on the path from impersonating the vCenter and reading the credentials the provider logs in with (inferred, not tested), and exporting `VSPHERE_ALLOW_UNVERIFIED_SSL=false` does not restore verification.
5. **Credentials only from the environment**: the generators emit no user, password or token and the hooks fail on any. The provider's arguments are neither `sensitive` nor write-only (`password` included), so routing them through variables would only move the secret around.
6. **Backend, provider and versions are generated from globals, and greps guard the generator**: a dropped line (the TLS setting, a lock method, the stack-id address) would otherwise regenerate everywhere silently.
7. **`language { compatible_with }` gates the OpenTofu version**: OpenTofu 1.12+ does not enforce `required_version` in `.tf` files.
8. **Lock files committed for stacks and modules, `-lockfile=readonly` in every hook**: reproducible installs; `tofu init` 1.12+ records hashes for all platforms (13 here). `vmware/vsphere` is unsigned on the OpenTofu registry (`Signature validation was skipped due to the registry not containing GPG keys for this provider`), so these hashes are the only integrity control, and the first download is trusted. The source is `vmware/vsphere` everywhere: the same release is also served as `hashicorp/vsphere` on the OpenTofu registry, built from a fork with different artifacts, and `hashicorp/vsphere` is frozen at 2.12.0 on registry.terraform.io; `vmware` is the canonical namespace ([provider issue 2386](https://github.com/vmware/terraform-provider-vsphere/issues/2386)). The constraint `>= 2.17, < 3.0` is locked at 2.17.1, the release the checks and the rehearsal ran with.
9. **Destroy guard**: `protect_destroy` generates a `prevent_destroy` resource into every stack of a protected environment, since Terramate has none; `-target` and `-exclude` bypass it.
10. **One workload stack, no modules, no scanners**: the `folder` stack proves the wiring (state, provider, TLS, datacenter lookup, privileges) and nothing speculative ships. trivy and checkov are gone because they have no vSphere checks; the guards that matter are greps. Registry modules need care: the most-used VM module, `Terraform-VMWare-Modules/vm/vsphere` (192,368 downloads), was last released on 2023-11-05 and requires `hashicorp/vsphere`: next to a root on `vmware/vsphere`, an explicit `providers` mapping fails (`Provider type mismatch`) and without one the module brings a second provider (the `vsphere-provider-source` hook). The other vSphere modules are small, or brand new and unvetted (21 `microsoftexpert/*` modules published on 2026-07-20, 6 to 9 downloads each; not evaluated).
11. **No client-side state encryption by default**: GitLab encrypts states at rest and TLS covers transit, but anyone with the Developer role downloads them in plaintext through the API, and the shipped stack stores no secret. Turn it on, following OpenTofu's [State and Plan Encryption](https://opentofu.org/docs/language/state/encryption/), before a stack stores a secret (VM customization passwords, `vsphere_host.password`: provider 2.17.1 has no ephemeral or write-only arguments), ideally before its first apply. Existing state needs a migration path, `fallback { method = method.unencrypted.migrate }` (without it the next command fails with `encountered unencrypted payload without unencrypted method configured`), and the first apply afterwards re-saves the state encrypted. Measured on GitLab CE 19.4.2 with OpenTofu 1.13.1:
   - `pbkdf2` with the passphrase from `TF_VAR_...` (or all of it in `TF_ENCRYPTION`, so the code holds only `enforced = true`): GitLab accepts the encrypted envelope; each command costs about 0.6 to 0.8 s more (init 0.84 s, apply 0.86 s, plan 1.02 s, against 0.1 to 0.4 s unencrypted); a passphrase under 16 characters is refused; a wrong one fails with `decryption failed for all provided methods`; losing it loses the state.
   - `tofu force-unlock` then needs the key; GitLab's UI unlock and `curl -X DELETE .../lock` do not.
   - The OpenBao key provider (transit) costs little (init 0.43 s, apply 0.17 s, plan 0.14 s) and survived a key rotation, but every command needs the transit privileges `datakey/plaintext` and `decrypt` on the key.
   - Ciphertext is about 4/3 the size of the plaintext: a GitLab maximum state size (`max_terraform_state_size_bytes`, default 0 for none; over it the save fails with `HTTP error: 413`) set for plaintext can reject it.
12. **No state protection rules**: GitLab's rules (feature flag `protected_terraform_states`, off by default) can only restrict: a `DEVELOPER` rule did not let a Developer lock or write, an administrator bypasses them, and a rule matches one exact state name. The boundary stays the project: give prod its own through the per-environment `gitlab_project_id`.

## Not covered

- A real vCenter: privileges, certificate chains, the datacenter lookup, creating, renaming and deleting the folder, and the vCenter versions the provider supports (8.x and 9.x per its docs) were never exercised. `make e2e` runs against vcsim, a simulator. An ESXi host without vCenter is not a target of this template (`vsphere_server` is a vCenter); the free ESXi hypervisor cannot be managed by the provider at all (it needs API write access: provider docs).
- A real GitLab beyond CE 19.4.2: the role matrix, locks, versions and messages above were measured there, on neither GitLab.com nor a GitLab behind a reverse proxy or object storage. The 19.6 docs differ from 19.4.2 in places (GraphQL `versions` and `terraformStateRestore` exist there, not in 19.4.2; the job token is not a JWT in 19.4.2-ce although the docs say it is by default).
- A verified TLS connection is not rehearsed. After its refusal drill (run on the first stack that verifies: with only `vsphere_server` redirected, the generated `false` still fails a plan on vcsim's self-signed certificate even with `VSPHERE_ALLOW_UNVERIFIED_SSL=true` exported: `x509: certificate signed by unknown authority`), `make e2e` speaks plain HTTP to GitLab on loopback and runs the provider with `allow_unverified_ssl = true` against vcsim, because on macOS the provider ignores `SSL_CERT_FILE` and has no CA option, and verified TLS against vcsim would need the whole run inside a Linux container. Where every stack sets `vsphere_allow_unverified_ssl = true` the drill is skipped, and the rehearsal never exercises the generated TLS setting. No run shows the generated `https` addresses and a trusted VMCA working together. Also observed against vcsim over TLS: the `x509` messages of [Bootstrap](#bootstrap). Plain-HTTP vcsim is impossible: the provider hard-codes `https://` (`http: server gave HTTP response to HTTPS client`).
- vcsim is not vCenter. It reports `VMware vCenter Server 6.5.0 build-5973321` whatever `-api-version` says, so the provider takes its pre-7.0 paths. The folder stack is unaffected; resources you may add next drift in a second plan or fail: tags (`associable_types` shows `urn:vim25:Folder` against `Folder`, apply then fails with `cannot remove type "urn:vim25:Folder"`; `ignore_changes = [associable_types]` silences it), resource pools (`scale_descendants_shares` goes from `"disabled"` to null; set it to `"disabled"`), cloned VMs (`swap_placement_policy` appears and apply fails with `*types.AlreadyUpgradedFault`; `ignore_changes = [swap_placement_policy]`) and `vsphere_compute_cluster` (apply fails at `/vsanHealth`, and the state can then be neither refreshed nor destroyed). Whether a real vCenter drifts the same way was not tested; the tag and VM drifts look like simulator gaps (inferred).
- Mocks prove module logic, not provider behaviour: `tofu test` runs plan-only against `mock_provider`. No module ships: the first one brings its tests ([AGENTS.md](AGENTS.md) lists the mock gotchas).
- `prevent_destroy` and other lifecycle arguments are invisible to tests: review the module diff.
- `validate` and `test` never read backend blocks (`init -backend=false`): the `generated-*` greps cover the generated text. After changing the backend generator, run `tofu init -input=false` in one stack with no `TF_HTTP_*` variable set, against your GitLab: it must fail only with `Error refreshing state` and `HTTP remote state endpoint requires auth`. A schema problem is reported before that, as `Unsupported argument` (observed offline: a bogus attribute fails before any request). A real `tofu init` with a token is the only full check.
- Nothing server-side stops a Maintainer from running `-lock=false`: only `AGENTS.md` and review keep it out.
- State access is project access: GitLab has no per-state permissions, and every Developer reads every state of the project (see decisions 11 and 12).
- GitLab encrypts states at rest with Lockbox, using a key derived from `db_key_base` and the project id: without that secret no state can be decrypted ([GitLab docs](https://docs.gitlab.com/administration/terraform_state/#decryption-process)). On a Linux package install it lives in `/etc/gitlab/gitlab-secrets.json`, which the GitLab backup does not include: back that file up with the instance (Docker: the configuration volume) ([GitLab docs](https://docs.gitlab.com/administration/backup_restore/backup_gitlab/#storing-configuration-files)). GitLab documents no rotation of that key.
- The project access token expires (the date is yours to track) and a revoked, rotated or expired token fails every operator and pipeline at `init` with `HTTP remote state endpoint requires auth`.
- Client-side state encryption is off ([Design decisions](#design-decisions) has the options and their measured cost).
- gitleaks knows token formats, not passwords: it does not flag a password embedded in a URL (`https://user:password@host`).
- Taken at their newest release when installed or updated: the hooks, the tflint ruleset (named in `.tflint.hcl`, moved by `make update`), terraform-skill and the Homebrew tools. A new upstream version can change what a check or your agent does without any change in this repository: review the `make update` and `make skill` diff before committing. The MCP side changes without a diff to review: the `terraform-registry` server reads the public registry at registry.terraform.io, which can answer differently from registry.opentofu.org.
- Supply chain: pre-commit downloads a Go toolchain for gitleaks without hashes, Terramate is verified by checksum only, `tflint --init` downloads the terraform ruleset from GitHub releases, and the vSphere provider is unsigned on the OpenTofu registry: the lock file hashes recorded at the first `init` are the only control ([Design decisions](#design-decisions), 8). The `terraform-registry` MCP server (its entry unsets `TFE_TOKEN` and `TFE_ADDRESS`, see [Agent tooling](#agent-tooling)) and the hooks that git starts run with your shell's environment (`make check`, `check-all`, `test`, `relock` and `doctor` unset the cloud, vSphere and GitLab variables first). `make setup` and `make update` build the hook environments with the cloud, vSphere, GitLab and GitHub token variables unset.
- `make setup`, `make update` and `make skill` force TLS verification for their git fetches, whatever your git config says, except Homebrew's tap clone (`terraform-linters/tap`, only while it is not installed): Homebrew drops `GIT_*` variables, so that clone uses your git configuration. A path-scoped override (`http.https://github.com/<owner>/.sslVerify=false`) is more specific and wins; git older than 2.31 ignores the mechanism for pre-commit's own git calls (direct git calls are unaffected); a TLS-intercepting network makes the three fail.
- Verified on macOS (arm64) only: Linux and WSL2 were not run for this folder.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: `terraform_fmt`, `terraform_providers_lock`, `terraform_tflint`, `terraform_docs`, `terraform_validate`.
- [terraform-provider-vsphere](https://github.com/vmware/terraform-provider-vsphere) (MPL-2.0), [vcsim](https://github.com/vmware/govmomi/tree/main/vcsim) of govmomi and [GitLab CE](https://gitlab.com/gitlab-org/gitlab-foss): the provider of the stacks, and the simulator and the server of `make e2e`.
- [terraform-aws-modules](https://github.com/terraform-aws-modules/terraform-aws-vpc): `.editorconfig` follows theirs.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the Response Contract and rules in `AGENTS.md`, and the skill itself.
