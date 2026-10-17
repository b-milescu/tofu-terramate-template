# Local-dev entry points (`make help`). pre-commit is the check engine; these targets wrap it.
# Runs on GNU make 3.81 (macOS /usr/bin/make): no .ONESHELL, `!=`, `::=` or $(file ...); every recipe line is its own shell.
SHELL := /bin/bash
export CHECKPOINT_DISABLE := 1
.DEFAULT_GOAL := help
.PHONY: help doctor setup update hooks skill generate relock check check-all test e2e _tracked

# One provider cache for every stack and module: the push-stage hooks and relock init dozens of directories.
CACHE = export TF_PLUGIN_CACHE_DIR="$${TF_PLUGIN_CACHE_DIR:-$$HOME/.terraform.d/plugin-cache}" && mkdir -p "$$TF_PLUGIN_CACHE_DIR" &&

# Homebrew must not auto-update, send analytics or clean up, and must not call the GitHub API: that path hands the credential
# of a logged-in gh or the macOS Keychain to api.github.com (tap privacy check).
BREW = HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_GITHUB_API=1 brew

# Third-party code is fetched and built here, so TLS verification stays on whatever the user's git configuration
# (http.sslVerify=false, unscoped or scoped to github.com) or GIT_SSL_NO_VERIFY say. Direct git calls get it with -c;
# the git subprocesses of pre-commit read GIT_CONFIG_COUNT (git >= 2.31; pre-commit passes it on, but drops GIT_CONFIG_GLOBAL).
GIT_TLS = env -u GIT_SSL_NO_VERIFY git -c http.sslVerify=true -c http.https://github.com/.sslVerify=true
FORCE_TLS = unset GIT_SSL_NO_VERIFY; n=$${GIT_CONFIG_COUNT:-0}; export GIT_CONFIG_COUNT=$$((n + 2)) "GIT_CONFIG_KEY_$$n=http.sslVerify" "GIT_CONFIG_VALUE_$$n=true" "GIT_CONFIG_KEY_$$((n + 1))=http.https://github.com/.sslVerify" "GIT_CONFIG_VALUE_$$((n + 1))=true";

# The hook environments are built from third-party sources (pip, Go, gcc): no cloud variables and no tokens reach them.
INSTALL_HOOKS = $(FORCE_TLS) unset "$${!AWS_@}" "$${!ARM_@}" "$${!AZURE_@}" "$${!AZD_@}" "$${!GOOGLE_@}" "$${!GCP_@}" "$${!CLOUDSDK_@}" GITHUB_TOKEN TENV_GITHUB_TOKEN GH_TOKEN HOMEBREW_GITHUB_API_TOKEN; pre-commit install-hooks

# Template mode: this folder lies inside a git work tree whose top-level is another directory, so it is the template checkout and not
# a project (a project is its own git root; outside git nothing changes). There generate, relock, skill and hooks refuse, because they
# would write stack ids, generated files, locks, a skill copy or git hooks into the template, and check, check-all, test and e2e run in
# a throwaway project: the tracked and unignored files of this folder in a scratch git repository, generated and staged. Physical paths
# are compared: /tmp is a symlink on macOS and git reports the real path.
# A failed run can be a hook that rewrote the copy (terramate fmt, terraform_fmt, terraform_docs, the whitespace fixers), and a passing
# run can be a hook that created a file (terraform_docs writes a missing module README; pre-commit fails only on rewritten tracked
# files). The ids and generated files were staged before the run, so what is unstaged in the copy afterwards is exactly what the hooks
# did: it is applied to the checkout as one patch (all or nothing; a hunk next to a generated id line does not apply and is printed
# instead). The copy converts no line endings (info/attributes beats .gitattributes), or a CRLF fix would not show in the diff, and the
# diff options pin the format against the user's git configuration and GIT_DIFF_OPTS (a zero-context patch would be refused by git
# apply). Files a hook created arrive untracked: git 2.43's apply --intent-to-add empties the index.
IN_TEMPLATE = here=$$(pwd -P); top=$$(git rev-parse --show-toplevel 2>/dev/null) && top=$$(cd "$$top" && pwd -P) && [ "$$top" != "$$here" ]
REFUSE = if $(IN_TEMPLATE); then echo "this folder is a template inside $$top: create a project with RUNBOOK.md; check, check-all, test and e2e run in a throwaway copy" >&2; exit 1; fi
HOOK_FIXES = env -u GIT_DIFF_OPTS git -C "$$t" diff --binary --no-color --no-ext-diff --no-textconv --no-renames --unified=3 --src-prefix=a/ --dst-prefix=b/
THROWAWAY = if $(IN_TEMPLATE); then \
  echo "template checkout: running $@ in a throwaway project"; \
  t=$$(mktemp -d) || exit 1; trap 'rm -rf "$$t"' EXIT; \
  { git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do if [ -e "$$f" ] || [ -L "$$f" ]; then printf '%s\0' "$$f"; fi; done | tar --null -T - -cf - | tar -xf - -C "$$t" && \
    git -C "$$t" init -q -b main && mkdir -p "$$t/.git/info" && printf '* -text\n' >> "$$t/.git/info/attributes" && \
    $(MAKE) -C "$$t" --no-print-directory generate && git -C "$$t" add -A; } || exit $$?; \
  $(MAKE) -C "$$t" --no-print-directory $@; rc=$$?; \
  if git -C "$$t" add -N . && ! git -C "$$t" diff --quiet; then \
    p=$$(git rev-parse --show-prefix); \
    if $(HOOK_FIXES) | git -C "$$top" apply --whitespace=nowarn --directory="$${p%/}"; then \
      if [ $$rc -eq 0 ]; then echo "template checkout: the hooks created files in this folder: see \"git status\""; \
      else echo "template checkout: applied the hooks' fixes to this folder: review \"git diff\", then rerun"; fi; \
    else { echo "template checkout: could not apply the hooks' fixes; the diff:"; $(HOOK_FIXES); } >&2; fi; \
  fi; \
  exit $$rc; fi

help: ## List the targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z0-9-]+:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

doctor: ## Check the toolchain against the pins (installs nothing; non-zero exit on a missing or wrong tool)
	@unset TF_PLUGIN_CACHE_DIR; export TENV_SKIP_LAST_USE=1 TFLINT_DISABLE_VERSION_CHECK=1 CKV_SKIP_PACKAGE_UPDATE_CHECK=true; bad=0; \
	ver() { local o; o=$$("$$@" 2>&1) || return 0; grep -Eo '[0-9]+(\.[0-9]+)+' <<<"$$o" | head -1; }; \
	ge() { [ "$$(printf '%s\n%s\n' "$$1" "$$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$$2" ]; }; \
	has() { command -v "$$1" >/dev/null 2>&1 || { echo "MISSING $$1"; bad=1; return 1; }; }; \
	chk() { has "$$1" || return 0; v=$$(ver "$$1" --version); if [ -n "$$v" ]; then echo "ok $$1 $$v"; else echo "WRONG $$1 (no version)"; bad=1; fi; }; \
	chk git; \
	if has pre-commit; then \
	  v=$$(ver pre-commit --version); \
	  min=$$(sed -n 's/^minimum_pre_commit_version: *"\{0,1\}\([0-9.]*\).*/\1/p' .pre-commit-config.yaml 2>/dev/null); \
	  h=$$(mktemp -d); err=$$(PRE_COMMIT_HOME="$$h" pre-commit validate-config .pre-commit-config.yaml 2>&1); rc=$$?; rm -rf "$$h"; \
	  if [ -z "$$v" ]; then echo "WRONG pre-commit (no version)"; bad=1; \
	  elif [ $$rc -eq 0 ]; then echo "ok pre-commit $$v"; \
	  elif [ -n "$$min" ] && ! ge "$$v" "$$min"; then echo "WRONG pre-commit $$v want >= $$min"; bad=1; \
	  else echo "ok pre-commit $$v"; echo "WRONG .pre-commit-config.yaml is invalid (validate-config exit $$rc):"; sed -e '/^$$/d' -e 's/^/  /' <<<"$$err"; bad=1; fi; \
	fi; \
	chk tenv; \
	if has tofu; then \
	  want=$$(awk '$$1 == "opentofu" { print $$2 }' .tool-versions); \
	  out=$$(tofu version 2>/dev/null); rc=$$?; v=$$(sed -n 's/^OpenTofu v//p' <<<"$$out" | head -1); \
	  if [ $$rc -ne 0 ]; then echo "MISSING tofu"; bad=1; \
	  elif [ -z "$$v" ]; then echo "WRONG tofu (no version)"; bad=1; \
	  elif [ "$$v" = "$$want" ]; then echo "ok tofu $$v"; \
	  else echo "WRONG tofu $$v want $$want"; bad=1; fi; \
	fi; \
	if has terramate; then \
	  want=$$(awk '$$1 == "terramate" { print $$2 }' .tool-versions); \
	  v=$$(terramate version 2>/dev/null); rc=$$?; \
	  if [ $$rc -ne 0 ]; then echo "MISSING terramate"; bad=1; \
	  elif [ -z "$$v" ]; then echo "WRONG terramate (no version)"; bad=1; \
	  elif [ "$$v" = "$$want" ]; then echo "ok terramate $$v"; \
	  else echo "WRONG terramate $$v want $$want"; bad=1; fi; \
	fi; \
	if has tflint; then \
	  v=$$(ver tflint --version); req=$$(sed -n 's/^ *required_version *= *">= *\([0-9.]*\)".*/\1/p' .tflint.hcl | head -1); \
	  if [ -z "$$v" ]; then echo "WRONG tflint (no version)"; bad=1; \
	  elif ge "$$v" "$$req"; then echo "ok tflint $$v"; \
	  else echo "WRONG tflint $$v want >= $$req"; bad=1; fi; \
	fi; \
	chk trivy; chk terraform-docs; chk checkov; chk uvx; chk terraform-mcp-server; \
	exit $$bad

setup: ## Install the toolchain (Brewfile, tenv pins, tflint plugin, hook environments), then run doctor
	-$(BREW) trust --cask terraform-linters/tap/tflint
	$(BREW) bundle --file=Brewfile --no-upgrade
	tenv tofu install
	tenv tm install
	tflint --init --config=.tflint.hcl
	@echo "pre-commit install-hooks"; $(INSTALL_HOOKS)
	$(MAKE) --no-print-directory doctor

update: ## Move hook revisions and the tflint ruleset to their newest releases (OpenTofu, Terramate and providers stay pinned)
	@echo "pre-commit autoupdate"; $(FORCE_TLS) pre-commit autoupdate
	@t=$$(mktemp .tflint.hcl.XXXXXX) || exit 1; trap 'rm -f "$$t"' EXIT; \
	src=$$(sed -n 's/^[[:space:]]*source[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' .tflint.hcl); \
	old=$$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' .tflint.hcl); \
	[ "$$(grep -c . <<<"$$src")" = 1 ] && [ "$$(grep -c . <<<"$$old")" = 1 ] || { echo ".tflint.hcl: expected exactly one plugin source and one plugin version" >&2; exit 1; }; \
	new=$$($(GIT_TLS) ls-remote --tags --refs --sort=-v:refname "https://$$src" 'v*' | awk '$$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$$/ { sub("refs/tags/v", "", $$2); print $$2; exit }'); \
	[ -n "$$new" ] || { echo "no release tag found at https://$$src" >&2; exit 1; }; \
	sed 's/^\([[:space:]]*version[[:space:]]*=[[:space:]]*"\)[^"]*"/\1'"$$new"'"/' .tflint.hcl > "$$t" && \
	tflint --init --config="$$t" && cat "$$t" > .tflint.hcl && \
	if [ "$$old" = "$$new" ]; then echo "tflint ruleset already at $$old"; else echo "tflint ruleset $$old -> $$new"; fi
	@echo "pre-commit install-hooks"; $(INSTALL_HOOKS)
	@echo 'review "git diff", run "make check-all", commit'

hooks: ## Install the git hooks (pre-commit, pre-push, commit-msg); run it after the first commit
	@$(REFUSE)
	pre-commit install

# The edit check of `make skill`: the copy must still hold what make skill wrote. The fingerprint is the git blob hash of every
# entry except SOURCE and directories (path and bytes, no attribute filters), kept on SOURCE's second line; edits, deleted and
# added files and symlinks change it. Git state plays no part, so an uncommitted update can be rerun. Without a recorded
# fingerprint (no SOURCE, or the old one-line SOURCE) the check falls back to git: tracked files must match the index.
SKILL_FP = fp() { (cd "$$1" && find . ! -type d ! -path ./SOURCE | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$$(git hash-object --no-filters "$$f" 2>/dev/null)" "$$f"; done) | git hash-object --stdin; };

skill: ## Install or update terraform-skill (latest upstream) in .agents/skills
	@$(REFUSE)
	@$(SKILL_FP) d=.agents/skills/terraform-skill; git rev-parse --is-inside-work-tree >/dev/null || exit 1; \
	if [ -e "$$d" ]; then \
	  rec=$$(sed -n 's/^content \([0-9a-f][0-9a-f]*\)$$/\1/p' "$$d/SOURCE" 2>/dev/null | head -1); \
	  if [ -n "$$rec" ]; then [ "$$(fp "$$d")" = "$$rec" ] || { echo "$$d has local edits (its content differs from what make skill wrote): remove the folder and rerun" >&2; exit 1; }; \
	  else git diff --quiet -- "$$d" || { echo "$$d has local changes: commit or discard your changes first" >&2; exit 1; }; fi; \
	fi; \
	old=$$(sed -n 's/.* at \([0-9a-f]*\) (.*/\1/p' "$$d/SOURCE" 2>/dev/null); had=0; [ -e "$$d" ] && had=1; \
	t=$$(mktemp -d) || exit 1; trap 'rm -rf "$$t"' EXIT; \
	$(GIT_TLS) clone -q --depth 1 https://github.com/antonbabenko/terraform-skill.git "$$t/src" || exit 1; \
	[ -f "$$t/src/skills/terraform-skill/SKILL.md" ] && [ -f "$$t/src/LICENSE" ] || { echo "upstream layout changed: skills/terraform-skill/SKILL.md or LICENSE not found" >&2; exit 1; }; \
	new=$$(git -C "$$t/src" rev-parse --short=7 HEAD); \
	rm -rf "$$d" && mkdir -p "$$(dirname "$$d")" && cp -R "$$t/src/skills/terraform-skill" "$$d" && cp "$$t/src/LICENSE" "$$d/LICENSE" && \
	{ echo "terraform-skill from https://github.com/antonbabenko/terraform-skill at $$new (default branch, Apache-2.0, unmodified). Update: make skill"; echo "content $$(fp "$$d")"; } > "$$d/SOURCE" || exit 1; \
	if [ $$had = 0 ]; then echo "terraform-skill installed at $$new"; \
	elif [ "$$old" = "$$new" ]; then echo "terraform-skill already at $$new"; \
	else echo "terraform-skill updated $${old:-unknown} -> $$new"; fi; \
	[ -z "$$(git status --porcelain -- "$$d")" ] || echo 'review "git status" and "git diff -- .agents/skills", then commit'

generate: ## Create missing stack ids, then regenerate the stack code (run after editing *.tm.hcl)
	@$(REFUSE)
	terramate create --ensure-stack-ids
	terramate generate

relock: ## Upgrade the provider lock files within the version constraints
	@$(REFUSE)
	@$(CACHE) terramate run --disable-safeguards=git --parallel 1 -- tofu init -backend=false -upgrade -input=false && \
	for d in modules/*/; do (cd "$$d" && tofu init -backend=false -upgrade -input=false) || exit 1; done

# Hooks only see tracked files: on an untracked tree every hook skips and pre-commit exits 0.
_tracked:
	@$(IN_TEMPLATE) || git ls-files --error-unmatch .pre-commit-config.yaml >/dev/null 2>&1 || { echo "nothing is tracked yet: run 'git add -A' first" >&2; exit 1; }

check: _tracked ## Commit-stage hooks on every tracked file
	@$(THROWAWAY); $(CACHE) pre-commit run --all-files

check-all: _tracked ## Commit- and push-stage hooks on every tracked file
	@$(THROWAWAY); $(CACHE) pre-commit run --all-files && pre-commit run --all-files --hook-stage pre-push

test: _tracked ## tofu test of every module (mock providers, no credentials)
	@$(THROWAWAY); $(CACHE) pre-commit run tofu-test --all-files --hook-stage pre-push

e2e: ## Rehearse Bootstrap, Operate and Destroy against floci, a local AWS emulator in Docker (about 3.5 minutes, never reaches AWS)
	@$(THROWAWAY); $(SHELL) ./e2e.sh
