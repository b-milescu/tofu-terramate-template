# OpenTofu + Terramate on AWS

[OpenTofu](https://opentofu.org) for the code, [Terramate](https://terramate.io) for stacks, code generation and run order, [pre-commit](https://pre-commit.com) as the only check runner. `make help` lists the local entry points; coding agents read [AGENTS.md](AGENTS.md).

- A stack is a directory with a `stack.tm.hcl`: one OpenTofu root module with its own state.
- Shipped: the stacks `state-backend` and `network` for every account and region (defaults: accounts `dev` and `prod`, region `eu-central-1`; [Parameters](#parameters) changes them).
- Every check runs without cloud credentials. Nothing has been applied to a real AWS account (see [Not covered](#not-covered)); `make e2e` replays Bootstrap, Operate and Destroy against a local emulator ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)). Unless you replaced them, the account ids `111111111111` and `222222222222` are placeholders: `allowed_account_ids` makes `tofu init` refuse them. Replace them first, they feed the bucket names and the account pinning.

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
e2e.sh                  optional floci rehearsal (`make e2e`)
AGENTS.md  README.md     rules for coding agents; this file
modules/state-backend/   S3 bucket and KMS key; tests/ (mock provider); README.md filled by terraform-docs
stacks/
  dev/                   globals.tm.hcl: account_id (the folder name is account_name)
    eu-central-1/        the folder name is region
      state-backend/     stack.tm.hcl (tag state-backend) + generated files
      network/           stack.tm.hcl, main.tf, outputs.tf + generated files
  prod/                  same shape; protect_destroy = true adds the destroy guard
```

Terramate always treats the git root as the project root, so the root-only settings in `terramate.tm.hcl` (`required_version`, `telemetry`, ...) only work in that file; `config.run.env` also works in subfolders.

Globals per level; lower levels add to or override higher ones:

| Level | File | Globals |
|---|---|---|
| project | [`globals.tm.hcl`](globals.tm.hcl) | `project`, `opentofu_version`, `aws_provider_version`, `account_name` and `region` (the folder names of `stacks/<account>/<region>/`), `state_bucket`, `state_kms_alias`, `protect_destroy`, `default_tags` (`ManagedBy`, `Project` = `project`, and `Environment` = `account_name`); values are in the file |
| account | `stacks/<account>/globals.tm.hcl` | `account_id` (12 digits, asserted in `generate.tm.hcl`); protected accounts also `protect_destroy = true` |
| stack | `stack.tm.hcl` | `stack {}`: `name`, `description`, `tags`, `after`, `id` |

`generate.tm.hcl` writes these files into every stack below it. They are committed and never edited by hand: change `generate.tm.hcl` or a globals file, run `make generate` and commit the result (the `terramate` hook runs `terramate generate` with `--detailed-exit-code` and fails when it had to write files). The `id` of a stack is assigned by `make generate` and is the state key.

| Generated file | Content | Written for |
|---|---|---|
| `_terramate_generated_backend.tf` | S3 backend: bucket `state_bucket`, key `stacks/<stack id>/tofu.tfstate`, `encrypt`, KMS alias ARN, `use_lockfile`, `allowed_account_ids` | every stack |
| `_terramate_generated_provider.tf` | `provider "aws"`: `region`, `allowed_account_ids`, `default_tags` | every stack |
| `_terramate_generated_versions.tf` | `required_version`, `required_providers`, `language { compatible_with }` | every stack |
| `_terramate_generated_state_backend.tf` | `module "state_backend"`; bucket and alias come from the same globals as the backend | tag `state-backend` |
| `_terramate_generated_destroy_guard.tf` | `terraform_data` resource with `prevent_destroy` | `protect_destroy = true` |

| Stack | Runs after | Content |
|---|---|---|
| `state-backend` | | the generated module call: bucket `<project>-tfstate-<account_id>-<region>` and key alias `<project>-tfstate` |
| `network` | `../state-backend` | `terraform-aws-modules/vpc/aws` (exact version in each `main.tf`) over the zones listed in `azs`, private /20 and public /24 subnets, flow logs to CloudWatch Logs kept 365 days; outputs `vpc_id`, `private_subnet_ids`, `public_subnet_ids`; default CIDRs dev `10.10.0.0/16`, prod `10.20.0.0/16` |

`modules/state-backend`: S3 bucket and KMS key for state; behavior and inputs are documented in [its README](modules/state-backend/README.md).

## Prerequisites

```bash
make setup    # Brewfile packages (installed ones are kept), the OpenTofu and Terramate pins via tenv, the tflint ruleset, hook environments; ends with make doctor
make doctor   # one line per tool: ok, MISSING or WRONG; installs nothing, makes no network call, changes nothing in the project; any problem is a non-zero exit
make update   # hook revisions and the tflint ruleset to their newest releases (OpenTofu, Terramate and providers stay pinned); then review git diff, make check-all, commit
make hooks    # the git hooks (pre-commit, pre-push, commit-msg); run it after the first commit
```

- `make setup` needs [Homebrew](https://brew.sh) on macOS 15+ (Apple Silicon), Linux (x86_64 or arm64, glibc) or WSL2; on Linux and WSL first run `sudo apt-get update && sudo apt-get install -y build-essential procps curl file git unzip` (Homebrew's own requirements on Linux, plus `unzip` for the tflint cask). The first run needs network and takes minutes (about 3 GB of downloads and caches: Homebrew formulae, `~/.tenv`, `~/.tflint.d`, the Go toolchain and Python packages of the hook environments in `~/.cache`, the AWS provider in `~/.terraform.d/plugin-cache`); later runs work offline, except that trivy then scans with its embedded checks ([Not covered](#not-covered)).
- `make check`, `check-all`, `test` and `relock` export `TF_PLUGIN_CACHE_DIR` (default `~/.terraform.d/plugin-cache`, created) to share provider binaries across stacks and modules. Interactive `tofu` and `terramate run` commands need the export themselves, and so do the git hooks: `terraform_validate` on `git push` does not export it, so a fresh clone downloads the AWS provider into every stack and module directory (5 here: about 95 s and 3.9 GB measured). Put `export TF_PLUGIN_CACHE_DIR=$HOME/.terraform.d/plugin-cache` (and `mkdir -p "$TF_PLUGIN_CACHE_DIR"`) in your shell profile, or run `make check-all` once: it leaves `.terraform` in place. A directory without a lock file downloads the provider once even with a warm cache; locked inits reuse the cache.
- When the anonymous GitHub API quota (60 requests per hour per IP) is exhausted, run `TENV_GITHUB_TOKEN=<token> GITHUB_TOKEN=<token> make setup` (the same for `make update`): tenv ignores `GITHUB_TOKEN`, `tflint --init` downloads the AWS ruleset from GitHub. Never print or commit tokens.
- Run `terramate` and `tofu` from the project root or below it: tenv finds the pins by walking up from the working directory (`terramate -C` from outside the project ignores them). A missing pinned tool makes the tenv shim exit 42: run `make setup`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, ...); the `commit-msg` hook enforces it.
- Optional: `export CHECKPOINT_DISABLE=1` stops Terramate's update check in interactive runs (the Makefile and the hooks set it).

| Tool | Version | Provided by |
|---|---|---|
| OpenTofu, Terramate | pinned in `.tool-versions`; `terramate.tm.hcl` sets the Terramate floor | installed by tenv |
| pre-commit | 4.4.0 or newer (4.7.0 verified) | brew |
| tflint | 0.61.0 or newer (0.61.0 verified); the AWS ruleset version in `.tflint.hcl` (tflint requires one), newest via `make update` | the `terraform-linters/tap/tflint` cask; the ruleset is fetched by `tflint --init` |
| trivy, terraform-docs, tenv, terraform-mcp-server | newest at install (0.76.0, 0.24.0, 4.15.1, 1.3.0 verified) | brew |
| checkov | Homebrew's current formula: 3.3.20 verified on 2026-10-17, several patch releases behind PyPI (the formula lags) | brew; the `terraform_checkov` hook runs this system binary |
| gitleaks | newest hook release (`make update`) | built by pre-commit on first use |

## Make targets

`make help` lists the targets. `check`, `check-all` and `test` stop with "nothing is tracked yet" until `git add -A` ran: hooks only see tracked files, and on an untracked tree every hook skips and pre-commit exits 0. `make e2e` is not part of `check-all`: it runs on macOS with Docker Desktop only and takes minutes ([End-to-end rehearsal](#end-to-end-rehearsal-make-e2e)).

In the template repository (this folder lies inside another repository's work tree, so it is not a project: a project is its own git repository), `check`, `check-all`, `test` and `e2e` print `template checkout: running <target> in a throwaway project` and run in a copy of the tracked and unignored files in a scratch git repository (`make generate`, then the target), removed on every exit, Ctrl-C included; they need no `git add`. What the hooks rewrote or created in the copy is applied to the checkout as one patch (review `git diff` and `git status`, then rerun); stack ids and generated files never come back, a patch that does not apply is printed on stderr instead, and the exit code is the target's. `generate`, `relock`, `skill` and `hooks` refuse there (`this folder is a template inside <path>`); a project copied into a subfolder of another repository gets the same treatment: `git init` it.

## Parameters

The wizard of the template's RUNBOOK.md (a checkout of the template; its commit is in the first line of this file) asks these rows once; they are also the guide for later edits. Paths are relative to the project root.

| Parameter | Default | Rule | How to change (project-root paths) |
|---|---|---|---|
| project | basename of the target directory, lowercased, every run of other characters → `-`, trimmed; if the result breaks the rule: ask | `^[a-z][a-z0-9-]*[a-z0-9]$`; not starting `xn--`, `sthree-`, `amzn-s3-demo-`; `len(project) + 22 + len(region) <= 63` (all asserted by generate.tm.hcl); unique among your projects in the same AWS account and region (bucket and key alias collide otherwise) | `project` in `globals.tm.hcl`, then `make generate` |
| accounts | `dev` (`111111111111`), `prod` (`222222222222`) — placeholders: `allowed_account_ids` makes init refuse them until replaced | name `^[a-z][a-z0-9-]{0,19}$`, unique; id `^[0-9]{12}$` (asserted), distinct | per account `stacks/<name>/globals.tm.hcl` (`account_id`; the folder name is the account name). Rename: `mv stacks/<old> stacks/<new>`; add: copy `stacks/<existing>` to `stacks/<new>` (once `make generate` has run, delete the copied `id = ...` lines in its `stack.tm.hcl` files, recipe in [Grow the tree](#grow-the-tree)), set its `account_id`, give it a new `vpc_cidr`, `make generate`; remove: delete `stacks/<name>` |
| protect_destroy | `true` for accounts whose name starts with `prod`, else absent | boolean | `protect_destroy = true` in `stacks/<name>/globals.tm.hcl` |
| region | `eu-central-1` (all accounts) | `^[a-z]{2}-[a-z]+-[0-9]+$`; standard partition only (not `cn-*`, `us-gov-*`, `us-iso*`; asserted by generate.tm.hcl) | per account `mv stacks/<acct>/eu-central-1 stacks/<acct>/<region>` (the folder name is the region), every `eu-central-1` in its `network/main.tf` |
| availability zones | `<region>a`, `<region>b`, `<region>c` | 2 or 3 distinct names matching `^<region>[a-z]$` that exist in the account; no offline check can tell (only apply fails). Ask the user for the names when the region is `us-west-1` (two zones per account), `ca-central-1` or `ap-northeast-1`; always tell the user to confirm with `aws ec2 describe-availability-zones --region <region>` (their credentials) before the first plan | `azs` in each `network/main.tf` |
| VPC CIDR | `10.10.0.0/16` (dev), `10.20.0.0/16` (prod), then `10.30.0.0/16`, ... | `^10\.[0-9]{1,3}\.0\.0/16$`, distinct | `vpc_cidr` in each `network/main.tf` |
| AWS provider | keep the locked 6.69.1 (verified) | `keep` or `latest` (newest 6.x: `curl -fsS https://registry.opentofu.org/v1/providers/hashicorp/aws/versions`); the constraint `>= 6.0, < 7.0` stays | `latest`: `make relock` after `make generate` |

Version pins of OpenTofu and Terramate are generic (step 2 of the template's RUNBOOK): `.tool-versions` lines `opentofu X.Y.Z` / `terramate X.Y.Z`; Terramate also `required_version = "~> X.Y.Z"` in `terramate.tm.hcl`; rule `^[0-9]+\.[0-9]+\.[0-9]+$`, OpenTofu >= 1.12.0.

Placeholder values the RUNBOOK leftover scan looks for: `example`, `111111111111`, `222222222222`, `eu-central-1`.

## Checks

`.pre-commit-config.yaml`, in execution order. "Both" means pre-commit and pre-push: the fast set re-runs at push to catch `git commit --no-verify`. `make check` runs the commit stage on every tracked file, `make check-all` both stages.

| Hook id | Source | Stage | Checks |
|---|---|---|---|
| `check-added-large-files`, `check-merge-conflict`, `check-yaml`, `end-of-file-fixer`, `mixed-line-ending` (lf), `trailing-whitespace` | pre-commit-hooks | both | hygiene; `check-added-large-files` runs with `--enforce-all` and `check-merge-conflict` with `--assume-in-merge` so both also work under `--all-files`; the three fixers skip the skill copy (`.agents/skills/`) |
| `gitleaks` | gitleaks | both | secrets in the staged changes (blind under `--all-files`) |
| `gitleaks-history` | gitleaks | pre-push | secrets in every commit (`gitleaks git --redact --verbose`), runs even when no file survives |
| `conventional-pre-commit` | conventional-pre-commit | commit-msg | Conventional Commits message |
| `terramate` | local | both | `terramate fmt`, `generate`, `list --run-order`: fails on rewritten `.tm.hcl`, stale or hand-edited generated files, duplicate stack ids, `after` cycles or typos, failed asserts (project name, account id, region, bucket name length), a stack without `_terramate_generated_{backend,provider,versions}.tf`; prints `hint: run "make generate"` when a stack has no id |
| `generated-versions` | local (pygrep) | both | generated versions still has the top-level `language { compatible_with { opentofu = ... } }` gate (OpenTofu ignores `required_version` in `.tf` files) |
| `generated-backend` | local (pygrep) | both | generated backend still has, line-anchored, `encrypt = true`, `use_lockfile = true`, a `kms_key_id` alias ARN that is not `alias/aws/...`, `allowed_account_ids` with a 12-digit id and `key = "stacks/<uuid>/tofu.tfstate"` |
| `generated-provider` | local (pygrep) | both | generated provider still has `allowed_account_ids` (line-anchored, 12-digit id) and `default_tags {` |
| `forbidden-files` | local | both | rejects state files, plans, crash logs, `.terraform/`, `.tofu` files and override files (`override.tf`, `*_override.tf`, `.json` forms): they silently replace the generated backend, provider and destroy guard |
| `tofu-test` | local | pre-push | `tofu test` in every module with mock providers; fails when a module has no tests, runs none, or leaves `errored_test.tfstate` |
| `terraform_fmt` | pre-commit-terraform | both | `tofu fmt` |
| `terraform_providers_lock` | pre-commit-terraform | both | every provider in every lock file has at least as many `h1:` hashes as configured platforms (darwin and linux, amd64 and arm64) and a `zh:` hash; it counts hashes, it does not check which platforms they belong to (offline) |
| `terraform_tflint` | pre-commit-terraform | both | tflint with preset `all`, the AWS ruleset, exact registry-module versions and the secret rules `aws_write_only_arguments` and `aws_ephemeral_resources` |
| `terraform_docs` | pre-commit-terraform | both | regenerates `modules/*/README.md` between the `BEGIN_TF_DOCS` and `END_TF_DOCS` markers |
| `terraform_validate` | pre-commit-terraform | pre-push | `tofu validate`, serially, in every directory under `make check-all` and in the directories of changed files on a push; a directory without `.terraform` first gets `tofu init -backend=false -lockfile=readonly`, so the stacks' S3 backend is never contacted (it exports no `TF_PLUGIN_CACHE_DIR`: see [Prerequisites](#prerequisites)) |
| `terraform_trivy` | pre-commit-terraform | both | `trivy config`, MEDIUM and above, `.terraform` and downloaded registry-module internals excluded: once at the project root under `make check` and `check-all`, per directory of changed files on a commit or push |
| `terraform_checkov` | pre-commit-terraform | pre-push | the Homebrew checkov, terraform framework, `--skip-download`: once at the project root under `check-all`, inside each directory of changed files on a push; `CKV_TF_1` is skipped in the hook, every other skip is an inline `#checkov:skip` with a reason (`grep -rn checkov:skip .`) |

- A hook that rewrites files (`end-of-file-fixer`, `terraform_fmt`, `terraform_docs`, `terramate`) fails the run: review the change, `git add` it, run again. `terramate fmt` formats `*.tm.hcl` files up front: run it after editing one by hand.
- `trivy` and `checkov` are system tools: they must be on the `PATH` of whatever runs git (no hook environment builds them; a GUI git client or a minimal CI image often lacks Homebrew's `bin`). Missing: `checkov: command not found` (exit 127) or `'trivy' is required by 'terraform_trivy' pre-commit hook but it is not discoverable in the system's PATH`. `make doctor` finds both.
- Network use of the pre-commit-terraform hooks: trivy fetches its checks bundle from `mirror.gcr.io` at most once a day and still runs offline, with its embedded checks ([Not covered](#not-covered)); checkov (the hook sets `CKV_SKIP_PACKAGE_UPDATE_CHECK=true`) and `tofu validate` make no request.
- `make check`, `check-all`, `test`, `relock` and `doctor` unset every `AWS_*`, `ARM_*`, `AZURE_*`, `AZD_*`, `GOOGLE_*`, `GCP_*`, `CLOUDSDK_*`, `VSPHERE_*`, `GOVC_*`, `TF_HTTP_*` and `GITLAB_*` variable, plus `TENV_GITHUB_TOKEN`, `GH_TOKEN` and `HOMEBREW_GITHUB_API_TOKEN` (not `GITHUB_TOKEN`: `terraform_tflint` runs `tflint --init`, which reads it), before pre-commit, tflint, tofu or a provider binary starts. Variables only: a login cached in a config dir (`~/.aws`, az, gcloud, `~/.govmomi`) is not isolated; only the `tofu-test` hook points `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` at `/dev/null` and the az, azd and gcloud config dirs at an empty temp dir. The git hooks that `make hooks` installs run with the environment of the process that runs git; inside them only `tofu-test` scrubs itself. `tofu validate` starts the provider binary (it does not configure the provider, and made no request in a test with fake credentials; nothing enforces that it stays offline); `tofu init` starts none (a TRACE log shows no plugin launch); trivy and checkov only read files. The prefix list must stay in step in the Makefile `SCRUB` (`INSTALL_HOOKS` uses it too), the `tofu-test` hook and `e2e.sh`.

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
| `detect-aws-credentials`, `detect-private-key` | gitleaks covers both | `gitleaks` |
| yamllint, markdownlint, typos | style only (`check-yaml` covers YAML syntax) | none |
| shellcheck | `e2e.sh` is the only shell file and is optional (`make e2e`) | none |

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
| `aws-knowledge` | AWS documentation read and search, regional availability, region lists and AWS skills (5 read-only tools) | remote: `https://knowledge-mcp.global.api.aws`, hosted by AWS | none |

`aws-knowledge` is a remote server hosted by AWS: free, no AWS account, no authentication, subject to rate limits and the AWS Site Terms. Every session start your harness connects to it (`initialize`, `tools/list`: nothing from your project); afterwards only what the agent puts into a tool call leaves your machine: search phrases, documentation URLs, region and skill names. Do not paste secrets or account data into queries. The skills it serves (`aws___retrieve_skill`) are text written by AWS that the agent reads: documentation, not instructions. Not every harness reads `.mcp.json` or supports remote servers: add the entries to its own MCP config by hand (`aws-knowledge` as a remote Streamable HTTP server without authentication) and keep it in step with `.mcp.json`.

Why the `terraform-registry` command looks like this: `--toolsets=registry` keeps the 9 read-only registry tools (without it a TFE token in `~/.terraform.d/credentials.tfrc.json` exposes 56 tools, 19 of them without a read-only hint); `env -u TFE_TOKEN -u TFE_ADDRESS HOME=/nonexistent` stops the binary from reading and sending that token, and makes it log `failed to create TFE client ... /nonexistent` to stderr on every start: by design, not a failure.

Cloud API access (credentials, a profile, signed requests) is not shipped: every entry above is lookup-only and credential-free. If you add a credentialed server yourself, keep it out of `.mcp.json` in the repository.

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

Once per account and region, with admin credentials for that account (it creates the bucket and the key). Until the bucket exists every other stack of that account and region fails at `tofu init`. Use plain `tofu` here: the generated S3 backend points at a bucket that does not exist yet, so a gitignored `backend_override.tf` swaps in local state for the first apply.

First set the real `account_id` in `stacks/<account>/globals.tm.hcl`, run `make generate` and commit: the placeholder ids are baked into the committed generated files, and plain `tofu` has no outdated-code safeguard.

```bash
cd stacks/<account>/<region>/state-backend
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
tofu init
tofu plan -out=tfplan     # review
tofu apply tfplan
rm backend_override.tf
tofu init -migrate-state -force-copy
tofu plan                 # expect no changes
rm -f terraform.tfstate* tfplan   # only after a clean plan
```

- git cannot show a forgotten `backend_override.tf` (it is ignored): check that it is gone. Never commit it: the `forbidden-files` hook rejects tracked override files, which would silently replace the generated backend.
- Stop if the migration fails: the local state is the only record of the bucket and key.
- The stack now keeps its own state in the bucket it created. `prevent_destroy` on bucket and key and `force_destroy = false` make decommissioning a deliberate code change.
- Then initialise the other stacks: `cd stacks/<account> && terramate run -- tofu init`.

## Operate

Run from `stacks/<account>`: credentials are per account, `terramate run` at the project root would span every account, and `allowed_account_ids` refuses a foreign account. Export `TF_PLUGIN_CACHE_DIR` first ([Prerequisites](#prerequisites)).

```bash
cd stacks/<account>
terramate run -- tofu init                                       # first time, and after lock or provider changes
terramate run --no-tags state-backend -- tofu plan -out=tfplan   # then read every stack's plan
terramate run --no-tags state-backend -- tofu apply tfplan       # applies exactly the reviewed plans
```

- Routine runs leave `state-backend` out. Plan and apply it only with admin credentials (`terramate run --tags state-backend -- ...`, same plan-then-apply flow), when `modules/state-backend` or its globals change.
- Never `-auto-approve`. A stale or already applied plan is refused.
- `-detailed-exitcode` is unusable under `terramate run`: exit code 2 counts as failure.
- Safeguards stay on: `terramate run` refuses an uncommitted or untracked tree, outdated generated code and a checkout behind its remote (if you add an `origin`, push `main` to it before the first `terramate run`: the git safeguard calls `git ls-remote`; without a remote the check is skipped). Do not use `-X`; `tfplan` is gitignored, so it does not trip them.
- A run that died (closed terminal, timeout) leaves its lock object `stacks/<id>/tofu.tfstate.tflock` in the state bucket, and the next run in that stack stops with `Error acquiring the state lock` and a `Lock Info:` block (`ID`, `Who`, `Created`). First make sure no other run holds it: ask whoever `Who` names and check your pipeline. Then, in that stack's directory with the account's credentials, run `tofu force-unlock <LOCK_ID>` with the `ID` from the message and answer `yes`; a wrong id is refused and the real one shown. Never `-lock=false` as a way around it.

Destroy, only after the destroy plan was shown and confirmed:

```bash
terramate run --no-tags state-backend --reverse -- tofu plan -destroy -out=tfplan   # read every resource it deletes
terramate run --no-tags state-backend --reverse -- tofu apply tfplan
```

- Protected accounts (`protect_destroy = true`, prod by default): `tofu destroy` and `plan -destroy` fail with `Resource instance cannot be destroyed`. Flip `protect_destroy` in a reviewed pull request and run `make generate` (the guard files disappear in the diff) before planning the destroy; when the work is done, revert the flip and run `make generate` in a second reviewed pull request. Limit: `-target` and `-exclude` plan destroys past the guard. OpenTofu 1.13 prints `-exclude="terraform_data.destroy_guard"` in the refusal itself: do not follow that hint.
- `state-backend` stays out of the destroy (`--no-tags state-backend` above): `prevent_destroy` on its bucket and key makes its destroy plan fail, and removing the guard is a code change in the module.

## End-to-end rehearsal (`make e2e`)

Optional, not part of `check-all`: it replays [Bootstrap](#bootstrap), [Operate](#operate) and Destroy with this project's own files against [floci](https://github.com/floci-io/floci), a free local AWS emulator in Docker. Run it after changing generators, the state-backend module or the version pins, or to try a newer floci image.

```bash
make e2e                  # about 3.5 minutes; needs macOS with Docker Desktop, curl, the pinned tofu and terramate (make setup) and the project's git checkout
E2E_VERBOSE=1 make e2e    # the same, streaming the output of every step
```

It works on a throwaway copy of your tracked and unignored files (your tree and `.terraform` directories stay untouched), against a floci container on a random `127.0.0.1` port (no Docker socket, removed with its volume on exit). For every account under `stacks/`:

- Bootstrap as above (local state, apply, `-migrate-state -force-copy`, clean plan), the state object under its generated key, the KMS alias the backend names. Each `state-backend` takes about a minute, nearly all of it the AWS provider's own 55 s wait for the bucket lifecycle rule.
- Operate: saved-plan `terramate run` init, plan and apply, then a second plan that may only show the two known floci differences.
- A foreign account is refused; a held lock refuses a second operation (`PreconditionFailed`) and is then released.
- Destroy: the reverse destroy of an unprotected account; the guard's refusal where `protect_destroy = true`; the `prevent_destroy` refusal for every `state-backend`.

Each step prints `..` and its label when it starts and `ok` and the label when it passes, so the minute-long applies are not silent; a passing run ends with `e2e: all checks passed in <n>s; floci removed on exit, AWS never contacted`. A failing step shows the last 30 lines of its output (with `E2E_VERBOSE=1` all of it is already on screen) and stops the run with `e2e: FAILED: <label>`. A project without generated stack files fails (`e2e: no stacks/<account>/<region>/ with generated files: run make generate`) instead of passing with nothing checked.

It cannot reach AWS: the environment is scrubbed (no `AWS_*`, `VSPHERE_*`, `GOVC_*`, `GITLAB_*`, `TF_*`, `GIT_*`, proxy or token variable, no AWS config files, no instance metadata), the only credentials are fake (the account id as access key id), `AWS_ENDPOINT_URL` is the only redirect (loopback, preflight-checked), and every other host dies at a dead proxy, proven by a `curl` before the run and a `tofu plan` without the endpoint during it. The network is needed for the OpenTofu registry and GitHub only (provider and module downloads; the first run also pulls the 250 MB image).

| It shows | It cannot show |
|---|---|
| `tofu`, the provider and Terramate accept the generated backend and provider blocks (KMS alias ARN, `use_lockfile`, `encrypt`, `allowed_account_ids`) and the backend refuses a foreign account | IAM, bucket-policy and KMS-policy evaluation, the TLS-only statements included |
| bootstrap, state migration, saved-plan apply and reverse destroy work under Terramate's safeguards; the `network` stack applies | that SSE-KMS is enforced: floci stores the header and never validates the key |
| state locking with `use_lockfile` is a conditional write; the state object lands under its stack-id key | real zone availability, quotas, global bucket-name uniqueness, provider wait times, cost |
| the destroy guard and `prevent_destroy` really fail under this OpenTofu | real AWS: nothing here replaces a first apply in a sandbox account |

Knobs, all optional environment variables:

| Variable | Default | Use |
|---|---|---|
| `E2E_IMAGE` | `floci/floci:latest` | pin a tag or digest (for example `floci/floci:2.3.0`) when a new image regresses; 2.3.0 is what it ran against |
| `E2E_VERBOSE` | unset | `1` streams the output of every step live (a full run is about 4700 lines); any other value: only a failing step shows its last 30 lines |

Run on macOS with Docker Desktop only. A new floci image can change the result (`latest` is not pinned).

## Grow the tree

| Add | How |
|---|---|
| stack | `terramate create`, then write `main.tf` |
| region | copy `stacks/<account>/<region>` to `stacks/<account>/<new region>` (the folder name is the region), edit `network/main.tf`, bootstrap its `state-backend` |
| account | copy `stacks/<account>` to `stacks/<new account>` (the folder name is the account name), set `account_id` (and `protect_destroy = true` if protected), bootstrap each region |

New stack:

```bash
terramate create stacks/<account>/<region>/<stack> --name <stack> --description "..." --after ../state-backend
# write main.tf (and outputs.tf) in the new directory; it already has the generated backend, provider and versions
(cd stacks/<account>/<region>/<stack> && tofu init -backend=false)    # creates .terraform.lock.hcl; commit it
```

`terramate create` cannot set tags (its `--tags` is a filter): add `tags = [...]` to `stack.tm.hcl` by hand; only `state-backend` uses one.

New region or account, by copying:

```bash
cp -R stacks/<existing> stacks/<new>      # a region instead: stacks/<account>/<existing> and stacks/<account>/<new>, in every line
find stacks/<new> -name .terraform -type d -prune -exec rm -rf {} +
find stacks/<new> -name stack.tm.hcl -exec sed -i.bak '/^[[:space:]]*id[[:space:]]*=/d' {} + && find stacks/<new> -name '*.bak' -delete
$EDITOR stacks/<new>/globals.tm.hcl       # an account: account_id (a region needs no edit: the folder name is the region)
make generate                             # new ids = new state keys (copied ids fail with "duplicated ID"), then writes the new backend files; commit them
```

The lock files are copied along and stay valid (same providers). Commit, then bootstrap the new `state-backend` stacks.

- Edit `vpc_cidr` and `azs` in each copied `network/main.tf`: the copy keeps the source's range and zones. Zone letters differ per region and account (us-west-1 has no `b`), so list the zones that exist: `aws ec2 describe-availability-zones --region <region> --filters Name=zone-type,Values=availability-zone --query 'AvailabilityZones[].ZoneName'`.
- State keys are stack ids, so a moved stack keeps its state only within the same account and region: the bucket comes from `account_id` and `region`.
- `account_name` and `region` are the first two folder names under `stacks/` (`globals.tm.hcl`): add a new level (for example `<env>/`) below `<region>/`, and adjust the relative `source` of any hand-written stack that calls a local module.

## Upgrades

Each of these in its own pull request.

| What | Where | Then |
|---|---|---|
| OpenTofu, Terramate | `.tool-versions`; `terramate.tm.hcl` `required_version` when the Terramate minor changes | `make setup` (installs the pins), `make doctor` |
| Homebrew tools (trivy, checkov, terraform-docs, tenv, pre-commit, terraform-mcp-server) | the `Brewfile` lists them without versions | `brew upgrade <name>`, yours to run (`make setup` installs what is missing and keeps installed formulae; the doctor only checks that they run), then `make doctor` and `make check-all` |
| AWS provider constraint | `aws_provider_version` in `globals.tm.hcl`; for modules `modules/*/versions.tf` | `make generate`, then `make relock` |
| Registry module | exact `version` in the stack's `main.tf` (OpenTofu intersects its own provider floor with `aws_provider_version`; nothing is promoted into the global) | `make relock` |
| Hook revisions, tflint ruleset | `.pre-commit-config.yaml` (plain tags), the plugin `version` in `.tflint.hcl` | `make update` (newest tag on each hook repository's default branch: for gitleaks that can lag its newest release), then `make check-all` |
| terraform-skill | `.agents/skills/terraform-skill` | `make skill`, then review `git diff -- .agents/skills` ([Skill](#skill)) |

`make relock` runs `tofu init -backend=false -upgrade` in every stack (`terramate run --disable-safeguards=git`, needed because `make generate` just dirtied the tree; the outdated-code safeguard stays on) and in every `modules/*/`. Finish with `make check-all`.

`make update` runs `pre-commit autoupdate` (plain tags, not SHAs), moves the AWS ruleset in `.tflint.hcl` to the newest release tag of its source repository (`tflint ruleset <old> -> <new>`, or `tflint ruleset already at <v>`) and builds the hook environments of the new revisions (`pre-commit install-hooks`). It always verifies TLS and leaves OpenTofu, Terramate and the providers alone. Its last line is `review "git diff", run "make check-all", commit`.

## Deployer IAM

Least-privilege state access for the identity that runs `terramate run`; replace the placeholders. `stacks/*` covers the state objects and the `.tflock` lock objects (`use_lockfile`). The key policy delegates to the account root, so an IAM policy is enough. Add what the stacks themselves manage (VPC, CloudWatch Logs, the flow-log IAM role, ...). The statement covers the workload stacks only: it cannot plan `state-backend`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<project>-tfstate-<account_id>-<region>/stacks/*"
    },
    {
      "Sid": "StateBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<project>-tfstate-<account_id>-<region>"
    },
    {
      "Sid": "StateKey",
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"],
      "Resource": "arn:aws:kms:<region>:<account_id>:key/<key-id>"
    }
  ]
}
```

`<key-id>`: `aws kms describe-key --key-id alias/<project>-tfstate --query KeyMetadata.KeyId --output text`. Not evaluated by AWS: the statement follows the backend's access pattern and has never been tried against real AWS, so try it in a sandbox account before relying on it.

## Design decisions

1. **Account = environment**: `stacks/<account>/<region>/<stack>`, one state bucket and KMS key per account and region; blast radius follows account boundaries.
2. **State key = stack id** (`stacks/<id>/tofu.tfstate`): moving a folder cannot orphan state; ids come from `make generate` (`terramate create --ensure-stack-ids`) and are never copied, so every project gets fresh state keys.
3. **S3 backend with `use_lockfile`, `encrypt` plus a KMS alias ARN, `allowed_account_ids`**: no DynamoDB; `encrypt` alone means SSE-S3; a wrong account is refused.
4. **No client-side state encryption by default**: the key must pre-exist and its loss would mean state loss; SSE-KMS, versioning and TLS-only already cover the bucket. To enable it, follow OpenTofu's [State and Plan Encryption](https://opentofu.org/docs/language/state/encryption/) before a stack's first apply (existing state needs its migration path) and leave out the `state-backend` stacks (their state would depend on the key they create); reusing the bucket's KMS key gives no second access gate and no isolation between stacks.
5. **Backend, provider and versions are generated from globals, and greps guard the generator**: a dropped security line would otherwise regenerate everywhere silently.
6. **`language { compatible_with }` gates the OpenTofu version**: OpenTofu 1.12+ does not enforce `required_version` in `.tf` files.
7. **Lock files committed for stacks and modules, `-lockfile=readonly` in every hook**: reproducible installs; `tofu init` 1.12+ records hashes for all platforms.
8. **`state-backend` is plain resources with plan-only mock tests** that assert the CMK wiring and `aws:kms` default encryption, bucket key, ownership, both policies, key deletion window, alias, lifecycle rule and `force_destroy = false`, but not `prevent_destroy`; versioning, the public access block and key rotation are left to `terraform_trivy` and `terraform_checkov`. Workload stacks use registry modules pinned exactly.
9. **Destroy guard**: `protect_destroy` generates a `prevent_destroy` resource into every stack of a protected account, since Terramate has none; `-target` and `-exclude` bypass it.

## Not covered

- Real AWS: the S3 backend's acceptance of the KMS alias ARN, `use_lockfile` semantics, IAM and key policies as AWS evaluates them, and applying the `network` stack were never exercised. `make e2e` runs Bootstrap, state migration, plan and apply (the `network` stack included) and the destroy guard against the floci emulator with these files: it shows that OpenTofu, the provider and Terramate accept the generated blocks, not that AWS does.
- Registry-module internals and inputs are not scanned (`terraform_trivy` runs with `--tf-exclude-downloaded-modules`; checkov does not read downloaded modules): the exact version pin is the control.
- `terraform_trivy` scans with the checks bundle it downloads from `mirror.gcr.io` (a few megabytes, re-checked once the cache is a day old, kept in trivy's cache: `~/Library/Caches/trivy` on macOS, `~/.cache/trivy` on Linux). When the download or the re-check fails it logs `Falling back to embedded checks` (hidden by pre-commit while the hook passes; a cache older than a day is not used then either), scans with the checks built into the installed trivy and still exits 0: the same tree can pass in one environment and fail in another once a new check ships. Two known causes: no network, and a `credsStore` in `~/.docker/config.json` (Docker Desktop) whose helper (`docker-credential-desktop`) is not on `PATH`, as in a trimmed agent environment (`error getting credentials`). `trivy conf . --debug` shows which one applies.
- Mocks prove module logic, not provider behaviour: `tofu test` runs plan-only against `mock_provider`.
- `prevent_destroy` and other lifecycle arguments are invisible to tests: review the module diff.
- `validate` and `test` never read backend blocks (`init -backend=false`): the `generated-*` greps cover the generated text. After changing a backend generator, run `tofu init -input=false` in one stack without credentials. It must fail only with credential errors: `No valid credential sources found`, `failed to refresh cached credentials`, then `Retrieving AWS account details` (it may say `Missing Region`) and `Invalid account ID`, both caused by the missing credentials. A schema problem is reported before those, as `Unsupported argument`, `Incorrect attribute value type` or `Invalid KMS Key ID`. A real `tofu init` is the only full check.
- Nothing server-side denies SSE-S3 writes: `encrypt` alone is SSE-S3, and only the `generated-backend` check keeps `kms_key_id`.
- Bucket and key policies are asserted as documents; only AWS evaluates their effect.
- Client-side state encryption is off.
- gitleaks knows token formats, not passwords: it does not flag a password embedded in a URL (`https://user:password@host`).
- Taken at their newest release when installed or updated: the hooks, the tflint ruleset, terraform-skill and the Homebrew tools. A new upstream version can change what a check or your agent does without any change in this repository: review the `make update` and `make skill` diff before committing. The MCP side changes without a diff to review: `aws-knowledge` is a third-party hosted service (rate-limited, needs the network, tools and skills can change at any time).
- Supply chain: pre-commit downloads a Go toolchain for gitleaks without hashes; checkov and trivy come from Homebrew, Terramate is verified by checksum only; the `terraform-registry` MCP server (its entry unsets `TFE_TOKEN` and `TFE_ADDRESS`, see [Agent tooling](#agent-tooling)) and the hooks that git starts run with your shell's environment (`make check`, `check-all`, `test`, `relock` and `doctor` unset the variables listed in [Checks](#checks) first). `make setup` and `make update` build the hook environments with the cloud variables and the GitHub tokens unset.
- `make setup`, `make update` and `make skill` force TLS verification for their git fetches, whatever your git config says, except Homebrew's tap clone (`terraform-linters/tap`, only while it is not installed): Homebrew drops `GIT_*` variables, so that clone uses your git configuration. A path-scoped override (`http.https://github.com/<owner>/.sslVerify=false`) is more specific and wins; git older than 2.31 ignores the mechanism for pre-commit's own git calls (direct git calls are unaffected); a TLS-intercepting network makes the three fail.
- Verified on macOS (arm64) and, from `make setup` through both hook stages, in an Ubuntu 24.04 arm64 container; x86_64 Linux and WSL2 were not run.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: `terraform_fmt`, `terraform_providers_lock`, `terraform_tflint`, `terraform_docs`, `terraform_validate`, `terraform_trivy`, `terraform_checkov`.
- [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) (pinned in each `network/main.tf`): the `network` stacks. `.editorconfig` and the module conventions follow terraform-aws-modules.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the Response Contract and rules in `AGENTS.md`, and the skill itself.
