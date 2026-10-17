# OpenTofu + Terramate project templates

Provider templates for infrastructure projects: [OpenTofu](https://opentofu.org) for the code, [Terramate](https://terramate.io) for stacks, code generation and run order, [pre-commit](https://pre-commit.com) as the only check runner. Each provider folder is a complete project (hooks, tool pins, Makefile, agent files); the root holds only this README and [RUNBOOK.md](RUNBOOK.md).

| Provider | Folder | Status |
|---|---|---|
| AWS | [`aws/`](aws/) | ready ([README](aws/README.md)) |
| Azure | `azure/` | planned |
| GCP | `gcp/` | planned |

## Create a project

Open your coding agent in this directory and ask it to "follow RUNBOOK.md". It asks for the target directory, the provider, the tool versions and the provider's parameters, installs the toolchain, copies the provider folder, sets up the agent tooling and makes the initial commit.

It needs a committed checkout of this repository (the RUNBOOK copies committed files), Homebrew or the permission to install it (macOS 15+ on Apple Silicon, Linux x86_64 or aarch64 with glibc, WSL2), about 3 GB of downloads and caches, and git TLS verification on (no `GIT_SSL_NO_VERIFY` in the environment, no `http.sslVerify = false` for github.com in the git config).

## Maintaining

Smoke test: both check stages on the provider folder. It needs the toolchain (`make setup` in any project, or RUNBOOK step 4).

```bash
cd aws && make check-all
```

Inside this repository `aws/` is a template, not a project (Terramate takes the git root as the project root, and the folder ships without stack ids), so `check`, `check-all`, `test` and `e2e` run in a throwaway project: a copy of the folder's tracked and unignored files in a scratch git repository, `make generate`, then the target. Uncommitted edits are tested, and what the hooks did in the copy comes back to the checkout: the fixes of a failing run (review `git diff`, rerun) and the files a hook created in a passing run, such as a missing module README (untracked: `git status`). Stack ids, generated files and lock files never come back (aws/README.md, "Make targets", lists the messages). `generate`, `relock`, `skill` and `hooks` refuse here: they would write stack ids, generated files, lock files, a skill copy or git hooks into the template.

Second smoke test, optional (Docker, about 3.5 minutes): `cd aws && make e2e` replays Bootstrap, Operate and Destroy against a local emulator and never touches AWS (aws/README.md, "End-to-end rehearsal"). Run it when generators, the state-backend module or the version pins change, or to try a newer floci image.

| Policy | What | Where (`<p>` = provider folder) |
|---|---|---|
| Pinned | OpenTofu, Terramate | `<p>/.tool-versions`, and `required_version` in `<p>/terramate.tm.hcl` |
| Pinned | providers | the provider version in `<p>/globals.tm.hcl`, module `versions.tf`, the committed lock files |
| Pinned | registry modules the stacks call | the exact `version` in each stack's `main.tf` |
| Latest | hook revisions, tflint ruleset | `make update` in a project (the RUNBOOK runs it once, step 4); `<p>/.pre-commit-config.yaml` and `<p>/.tflint.hcl` carry what the last update wrote |
| Latest | MCP packages | `@latest` in `<p>/.mcp.json`: uvx checks for a newer release on every start |
| Latest | terraform-skill | `make skill` (install and update) |
| Latest | Homebrew tools | newest at install (`<p>/Brewfile`) |

Only what the development code is based on is pinned. A project runs `make update` when it is created. The template's own copies go stale until a maintainer refreshes them: `cd aws && make update` (it runs in place and rewrites `.pre-commit-config.yaml` and `.tflint.hcl`), review `git diff`, rerun the smoke test.

## Add a provider

```bash
mkdir azure && git archive HEAD:aws | tar -x -C azure   # committed files, dotfiles included (`cp -R aws/*` drops them)
```

Adapt the copy with the table below, then smoke-test it with `cd azure && make check-all` (uncommitted files are copied too). A provider folder ships without `_terramate_generated_*` files and without `id` lines in its `stack.tm.hcl` files: each project gets its own stack ids, which are its state keys. Lock files do ship: delete the copied `.terraform.lock.hcl` files and create new ones in a scratch copy, where `make generate` and `make relock` are allowed; without them `make check-all` fails at `terraform_validate` and `tofu-test` (the commit stage, `make check`, does not notice):

```bash
d=$(mktemp -d) && cp -R azure/. "$d" && (cd "$d" && git init -q -b main && make generate && make relock)
(cd "$d" && find . -name .terraform.lock.hcl ! -path '*/.terraform/*' -print0 | tar --null -T - -cf -) | tar -xf - -C azure
```

| File | aws | azure | gcp |
|---|---|---|---|
| `.tool-versions`, `.gitignore`, `.gitattributes`, `.editorconfig`, `terramate.tm.hcl`, `Makefile` | as shipped | identical, except that the `e2e` target calls `./e2e.sh` (below) | same |
| `.pre-commit-config.yaml` | as shipped | identical except the `entry:` regexes of `generated-backend` and `generated-provider` (they name AWS attributes) | same |
| `.tflint.hcl` | `plugin "aws"` | `plugin "azurerm"` | `plugin "google"` |
| `globals.tm.hcl` | `project`, `aws_provider_version`, `state_bucket`, `state_kms_alias`, `protect_destroy` | provider version; storage account, container and resource group names for the backend | provider version; state bucket name |
| `generate.tm.hcl` | asserts on project name, 12-digit account id and bucket name length; `s3` backend; `provider "aws"`; `required_providers`; state-backend module call | assert on the subscription id; `azurerm` backend; `provider "azurerm"` (`features {}`, `subscription_id`); `required_providers` | assert on the project id; `gcs` backend (`bucket`, `prefix`); `provider "google"` (`project`, `region`); `required_providers` |
| `stacks/**/globals.tm.hcl` | `account_id` is the AWS account, `region` | keep the names: `account_id` is the subscription id | keep the names: `account_id` is the project id |
| `modules/` | `state-backend` (S3 and KMS) | storage account and container module, with tests | bucket module, with tests |
| stack `main.tf` | VPC | the provider's resources | the provider's resources |
| `Brewfile` | `uv`, `terraform-mcp-server` | `terraform-mcp-server`; `uv` only while a `uvx` server is configured (`make doctor` checks `uvx`) | same as azure |
| `.mcp.json` | `terraform`, `aws-documentation`, `aws-knowledge` (remote, no auth) | `terraform`, `microsoft-learn` (remote `https://learn.microsoft.com/api/mcp`, no auth) | `terraform`, `google-developer-knowledge` (remote `https://developerknowledge.googleapis.com/mcp`: it lists its tools without a key, but calls need an API key in the `X-Goog-Api-Key` header) |
| `e2e.sh` | rehearsal against [floci](https://github.com/floci-io/floci) (`AWS_ENDPOINT_URL`) | optional: the same skeleton against [floci-az](https://github.com/floci-io/floci-az), or drop the `e2e` target | optional: against [floci-gcp](https://github.com/floci-io/floci-gcp), or drop the `e2e` target |
| `AGENTS.md`, `README.md` | this provider | adapt the MCP list; rewrite the README, including its Parameters section | same |

- The table is a checklist derived from the aws files: no azure or gcp folder exists yet, so none of it is built or tested.
- Keep config-dir isolation (`AZURE_CONFIG_DIR`, `AZD_CONFIG_DIR`, `CLOUDSDK_CONFIG`, an empty temp dir) in every hook that runs provider code and in the RUNBOOK's MCP check: unsetting the variables does not stop a cached `az login` or `gcloud` session. In `aws` only `tofu-test` scrubs `AWS_`, `ARM_`, `AZURE_`, `AZD_`, `GOOGLE_`, `GCP_` and `CLOUDSDK_` variables; the pre-commit-terraform hooks (validate with `-backend=false`, trivy, checkov) call no cloud API and run with the caller's environment.
- Cloud-API MCP servers (Azure MCP, gcloud-mcp, credentialed AWS servers) are not shipped: the `.mcp.json` files hold documentation and registry lookups only.
- Appendix A's converter and Appendix B's check in the RUNBOOK handle `command` entries and `url` entries without extra keys; an entry with `headers` (the GCP one) stops the converter, so write its harness files by hand, and the check reports it as not probed.
- `e2e.sh` is the skeleton for the other providers: scrub, fake credentials, one endpoint redirect with a preflight, a dead-proxy tripwire proven before and during the run, a throwaway copy, and checks per `stacks/<account>/<region>/`. What changes is the endpoint variables, the credentials, the state-backend checks and the drift list. floci-az and floci-gcp are the sister emulators of floci; they were not evaluated here.
- The RUNBOOK takes provider facts only from `<provider>/README.md#parameters`, `<provider>/.mcp.json` and `<provider>/Brewfile`, and relies on the shared format: the Makefile targets `doctor`, `setup`, `update`, `generate`, `relock`, `skill`, `check-all` and `hooks` (and `e2e` when the provider README has an "End-to-end rehearsal" section), plus `.tool-versions`, `terramate.tm.hcl`, `.pre-commit-config.yaml` and the `stacks/` layout. Keep those.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: the Terraform hooks.
- [terraform-aws-modules](https://github.com/terraform-aws-modules): the VPC module and the module conventions.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the skill installed into projects and the Response Contract in `AGENTS.md`.
- [Terramate](https://terramate.io) and [OpenTofu](https://opentofu.org).
