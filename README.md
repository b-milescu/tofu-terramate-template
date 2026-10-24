# OpenTofu + Terramate project templates

Provider templates for infrastructure projects: [OpenTofu](https://opentofu.org) for the code, [Terramate](https://terramate.io) for stacks, code generation and run order, [pre-commit](https://pre-commit.com) as the only check runner. Each provider folder is a complete project (hooks, tool pins, Makefile, agent files); the root holds only this README and [RUNBOOK.md](RUNBOOK.md).

| Provider | Folder | Status |
|---|---|---|
| AWS | [`aws/`](aws/) | ready ([README](aws/README.md)) |
| vSphere | [`vsphere/`](vsphere/) | ready ([README](vsphere/README.md)) |
| Azure | [`azure/`](azure/) | ready ([README](azure/README.md)) |
| GCP | [`gcp/`](gcp/) | ready ([README](gcp/README.md)) |

## Create a project

Open your coding agent in this directory and ask it to "follow RUNBOOK.md". It asks for the target directory, the provider, the tool versions and the provider's parameters, installs the toolchain, copies the provider folder, sets up the agent tooling, makes the initial commit and, when you ask, creates and pushes the git remote.

It needs a committed checkout of this repository (the RUNBOOK copies committed files), Homebrew or the permission to install it (macOS 15+ on Apple Silicon, Linux x86_64 or aarch64 with glibc, WSL2), about 3 GB of downloads and caches (measured for aws only), and git TLS verification on (no `GIT_SSL_NO_VERIFY` in the environment, no `http.sslVerify = false` for github.com in the git config), or your explicit yes to keep it off: the RUNBOOK then forces verification on for what it fetches itself, and stops when `make setup` would clone a Homebrew tap, which it cannot cover.

## Maintaining

Smoke test: both check stages on each provider folder. It needs the toolchain (`make setup` in any project, or RUNBOOK step 4).

```bash
cd aws && make check-all
cd ../vsphere && make check-all
cd ../gcp && make check-all
cd ../azure && make check-all
```

Inside this repository `aws/`, `vsphere/`, `gcp/` and `azure/` are templates, not projects (Terramate takes the git root as the project root, and the folders ship without stack ids): `check`, `check-all`, `test` and `e2e` run in a throwaway copy of the folder's tracked and unignored files, uncommitted edits included, and bring the hooks' fixes back; `generate`, `relock`, `skill` and `hooks` refuse (each provider README, "Make targets").

Second smoke test, optional (macOS with Docker Desktop only; each provider README, "End-to-end rehearsal"):

- `cd aws && make e2e` (about 3.5 minutes) replays Bootstrap, Operate and Destroy against floci, a local AWS emulator, and never touches AWS.
- `cd vsphere && make e2e` (about 3 minutes) replays Operate and Destroy against vcsim and GitLab CE and never touches a real vCenter or GitLab.
- `cd gcp && make e2e` (about 30 seconds) replays Bootstrap, Operate and Destroy against floci-gcp, a local Google Cloud emulator, and never touches Google Cloud.
- `cd azure && make e2e` (about 6 minutes) replays Bootstrap, Operate and Destroy against floci-az, a local Azure emulator, with OpenTofu itself running in a Linux container, and never touches Azure.

Run one when its generators, modules or version pins change, or to try newer emulator images.

Only what the development code is based on is pinned: OpenTofu, Terramate, the providers and the registry modules the stacks call. The emulator images of `make e2e` are pinned too (gcp: floci-gcp 0.11.0; azure: a dated floci-az nightly, by digest; vsphere: vcsim and GitLab CE), except aws, which takes `floci/floci:latest`; `E2E_IMAGE` overrides the image (vsphere: `E2E_VCSIM_IMAGE` and `E2E_GITLAB_IMAGE`). Everything else is taken at its newest release: the hook revisions and the tflint ruleset (`make update`), terraform-skill (`make skill`) and the Homebrew tools. Each provider README's "Upgrades" table says where each one lives and how to move it ([aws](aws/README.md#upgrades), [vsphere](vsphere/README.md#upgrades), [gcp](gcp/README.md#upgrades), [azure](azure/README.md#upgrades)). A project runs `make update` when it is created. The template's own copies go stale until a maintainer refreshes them: `make update` in each provider folder (`cd aws && make update`; it runs in place and rewrites `.pre-commit-config.yaml` and `.tflint.hcl`), review `git diff`, rerun the smoke test.

## Add a provider

```bash
P='<provider>'   # the new folder's name
mkdir "$P" && git archive HEAD:aws | tar -x -C "$P"   # committed files, dotfiles included (`cp -R aws/*` drops them)
```

Adapt the provider-specific files listed below, then smoke-test it with `cd "$P" && make check-all` (uncommitted files are copied too). A provider folder ships without `_terramate_generated_*` files and without `id` lines in its `stack.tm.hcl` files: each project gets its own stack ids, which are its state keys. Lock files do ship: delete the copied `.terraform.lock.hcl` files and create new ones in a scratch copy, where `make generate` and `make relock` are allowed; without them `make check-all` fails at `terraform_validate` and `tofu-test` (the commit stage, `make check`, does not notice):

```bash
P='<provider>'
d=$(mktemp -d) && cp -R "$P"/. "$d" && (cd "$d" && git init -q -b main && make generate && make relock)
(cd "$d" && find . -name .terraform.lock.hcl ! -path '*/.terraform/*' -print0 | tar --null -T - -cf -) | tar -xf - -C "$P"
```

Provider-specific: `.tflint.hcl` (the ruleset plugin), `globals.tm.hcl`, `generate.tm.hcl` (asserts, backend, provider, versions, the state-backend call), the `entry:` regexes of `generated-backend` and `generated-provider` and the required-file loop of the `terramate` hook in `.pre-commit-config.yaml` (the regexes name AWS attributes; the loop lists the generated files every stack must have), `stacks/*/globals.tm.hcl` (name the id global after the cloud's own term: `account_id`, `project_id`, `subscription_id`), `modules/` (with tests), each stack's `main.tf`, `Brewfile`, `.mcp.json` (documentation and registry lookups only, never a cloud-API server: `azure/` adds `microsoft-learn` at `https://learn.microsoft.com/api/mcp`, which needs no credentials; `gcp/` adds none, because the Google Developer Knowledge server at `https://developerknowledge.googleapis.com/mcp` needs an API key for its tool calls and that key must stay out of `.mcp.json`), `e2e.sh` and the `e2e:` help line of the `Makefile` (the same skeleton against a local emulator: [floci-gcp](https://github.com/floci-io/floci-gcp) in `gcp/`, [floci-az](https://github.com/floci-io/floci-az) in `azure/`; or drop the `e2e` target), `AGENTS.md` and `README.md` (the RUNBOOK reads the sections named in the bullet "The RUNBOOK takes provider facts" below). Everything else stays as shipped.

- A provider without a tflint ruleset of its own keeps the `terraform` ruleset as the only plugin and pins it in `.tflint.hcl` with `source` and `version` (as `vsphere/.tflint.hcl` does): `make update` needs exactly one of each, and a bundled-only file stops it with `.tflint.hcl: expected exactly one plugin source and one plugin version`. A provider that trivy and checkov have no checks for drops `terraform_trivy` and `terraform_checkov` and every use of them (hooks, Brewfile entries, doctor checks, README sections), but only after a sample of the provider's resources shows zero checks, with a positive control from another provider (as the Disabled tools row of `vsphere/README.md` does); `grep -rniE 'trivy|checkov' <provider>/` lists what is left, and a note that they are absent may stay, as in `vsphere/`.
- Keep config-dir isolation in every hook that runs provider code: `AZURE_CONFIG_DIR`, `AZD_CONFIG_DIR` and `CLOUDSDK_CONFIG` at an empty temp dir, and `GOOGLE_APPLICATION_CREDENTIALS=/dev/null`, because `CLOUDSDK_CONFIG` does not move the gcloud application-default credentials file out of `~/.config/gcloud`. Unsetting the variables does not stop a cached `az login` or `gcloud` session, so only `tofu-test` isolates those config dirs. Which targets unset which variables (`SCRUB` in the Makefiles) and what the git hooks scrub is in each provider README's Checks ([aws](aws/README.md#checks), [vsphere](vsphere/README.md#checks), [gcp](gcp/README.md#checks), [azure](azure/README.md#checks)). The four folders carry one prefix list: `AWS_`, `ARM_`, `AZURE_`, `AZD_`, `MSI_` and `IDENTITY_` (managed identity), `ACTIONS_ID_TOKEN_REQUEST_` (GitHub OIDC), `GOOGLE_`, `GCLOUD_` (`GCLOUD_KEYFILE_JSON` authenticates the google provider), `GCP_`, `CLOUDSDK_`, `VSPHERE_`, `GOVC_`, `TF_HTTP_`, `GITLAB_` and the names `SYSTEM_ACCESSTOKEN` (Azure DevOps job token), `CI_JOB_TOKEN`, `CI_JOB_JWT`, `CI_JOB_JWT_V2` and `CI_REGISTRY_PASSWORD` (GitLab CI job credentials: a Maintainer's `CI_JOB_TOKEN` can lock, write and delete GitLab-managed state; the other `CI_*` variables stay); a provider whose credentials use other prefixes adds them to `SCRUB`, the `tofu-test` hook and `e2e.sh` of every folder. The pre-commit-terraform hooks (validate with `-backend=false`, and trivy and checkov in `aws`, `gcp` and `azure`) call no cloud API.
- The RUNBOOK takes provider facts only from `<provider>/README.md` (the sections Layout, Prerequisites, Parameters, Agent tooling, Skill, Bootstrap, Checks and Upgrades), `<provider>/.mcp.json` and `<provider>/Brewfile`, and relies on the shared format: the Makefile targets `doctor`, `setup`, `update`, `generate`, `relock`, `skill`, `check-all` and `hooks` (and `e2e` when the provider README has an "End-to-end rehearsal" section), plus `AGENTS.md`, `.gitattributes`, `.tool-versions`, `terramate.tm.hcl`, `.pre-commit-config.yaml`, `.tflint.hcl` and the `stacks/` layout. Keep those.

## Credits

- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) by Anton Babenko: the Terraform hooks.
- [terraform-aws-modules](https://github.com/terraform-aws-modules): the VPC module and the module conventions.
- [terraform-skill](https://github.com/antonbabenko/terraform-skill) by Anton Babenko: the skill installed into projects and the Response Contract in `AGENTS.md`.
- [floci](https://github.com/floci-io/floci), [floci-gcp](https://github.com/floci-io/floci-gcp) and [floci-az](https://github.com/floci-io/floci-az): the local AWS, Google Cloud and Azure emulators behind `make e2e`.
- [Terramate](https://terramate.io) and [OpenTofu](https://opentofu.org).
