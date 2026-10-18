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

Inside this repository `aws/` is a template, not a project (Terramate takes the git root as the project root, and the folder ships without stack ids): `check`, `check-all`, `test` and `e2e` run in a throwaway copy of the folder's tracked and unignored files, uncommitted edits included, and bring the hooks' fixes back; `generate`, `relock`, `skill` and `hooks` refuse (aws/README.md, "Make targets").

Second smoke test, optional (macOS with Docker Desktop only; about 3.5 minutes): `cd aws && make e2e` replays Bootstrap, Operate and Destroy against a local emulator and never touches AWS (aws/README.md, "End-to-end rehearsal"). Run it when generators, the state-backend module or the version pins change, or to try a newer floci image.

Only what the development code is based on is pinned: OpenTofu, Terramate, the providers and the registry modules the stacks call. Everything else is taken at its newest release: the hook revisions and the tflint ruleset (`make update`), terraform-skill (`make skill`) and the Homebrew tools. Each provider README's "Upgrades" table says where each one lives and how to move it ([aws](aws/README.md#upgrades)). A project runs `make update` when it is created. The template's own copies go stale until a maintainer refreshes them: `cd aws && make update` (it runs in place and rewrites `.pre-commit-config.yaml` and `.tflint.hcl`), review `git diff`, rerun the smoke test.

## Add a provider

```bash
mkdir azure && git archive HEAD:aws | tar -x -C azure   # committed files, dotfiles included (`cp -R aws/*` drops them)
```

Adapt the provider-specific files listed below, then smoke-test it with `cd azure && make check-all` (uncommitted files are copied too). A provider folder ships without `_terramate_generated_*` files and without `id` lines in its `stack.tm.hcl` files: each project gets its own stack ids, which are its state keys. Lock files do ship: delete the copied `.terraform.lock.hcl` files and create new ones in a scratch copy, where `make generate` and `make relock` are allowed; without them `make check-all` fails at `terraform_validate` and `tofu-test` (the commit stage, `make check`, does not notice):

```bash
d=$(mktemp -d) && cp -R azure/. "$d" && (cd "$d" && git init -q -b main && make generate && make relock)
(cd "$d" && find . -name .terraform.lock.hcl ! -path '*/.terraform/*' -print0 | tar --null -T - -cf -) | tar -xf - -C azure
```

Provider-specific: `.tflint.hcl` (the ruleset plugin), `globals.tm.hcl`, `generate.tm.hcl` (asserts, backend, provider, versions, the state-backend call), the `entry:` regexes of `generated-backend` and `generated-provider` in `.pre-commit-config.yaml` (they name AWS attributes), `stacks/*/globals.tm.hcl` (keep the name `account_id` for the subscription or project id), `modules/` (with tests), each stack's `main.tf`, `Brewfile`, `.mcp.json` (documentation and registry lookups only, never a cloud-API server; candidates, not evaluated: azure `microsoft-learn` at `https://learn.microsoft.com/api/mcp`, gcp `google-developer-knowledge` at `https://developerknowledge.googleapis.com/mcp`, whose tool calls need an API key that must stay out of `.mcp.json`), `e2e.sh` (the same skeleton against [floci-az](https://github.com/floci-io/floci-az) or [floci-gcp](https://github.com/floci-io/floci-gcp), not evaluated, or drop the `e2e` target), `AGENTS.md` and `README.md` (the RUNBOOK reads the sections named in the bullet "The RUNBOOK takes provider facts" below). Everything else stays as shipped. Nothing of this has been built for azure or gcp yet.

- Keep config-dir isolation (`AZURE_CONFIG_DIR`, `AZD_CONFIG_DIR`, `CLOUDSDK_CONFIG`, an empty temp dir) in every hook that runs provider code: unsetting the variables does not stop a cached `az login` or `gcloud` session. In `aws` only `tofu-test` scrubs `AWS_`, `ARM_`, `AZURE_`, `AZD_`, `GOOGLE_`, `GCP_` and `CLOUDSDK_` variables; the pre-commit-terraform hooks (validate with `-backend=false`, trivy, checkov) call no cloud API and run with the caller's environment.
- The RUNBOOK takes provider facts only from `<provider>/README.md` (the sections Layout, Prerequisites, Parameters, Agent tooling, Skill, Bootstrap and Upgrades), `<provider>/.mcp.json` and `<provider>/Brewfile`, and relies on the shared format: the Makefile targets `doctor`, `setup`, `update`, `generate`, `relock`, `skill`, `check-all` and `hooks` (and `e2e` when the provider README has an "End-to-end rehearsal" section), plus `AGENTS.md`, `.gitattributes`, `.tool-versions`, `terramate.tm.hcl`, `.pre-commit-config.yaml`, `.tflint.hcl` and the `stacks/` layout. Keep those.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: the Terraform hooks.
- [terraform-aws-modules](https://github.com/terraform-aws-modules): the VPC module and the module conventions.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the skill installed into projects and the Response Contract in `AGENTS.md`.
- [Terramate](https://terramate.io) and [OpenTofu](https://opentofu.org).
