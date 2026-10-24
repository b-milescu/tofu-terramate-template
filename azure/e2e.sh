#!/usr/bin/env bash
# Rehearses the README's Bootstrap, Operate and Destroy against floci-az (https://github.com/floci-io/floci-az), a local Azure
# emulator in Docker: `make e2e` (in a template checkout make runs it in a throwaway project). Needs macOS with Docker Desktop,
# terramate (make setup), curl, and network for the registry, GitHub and the images, never for Azure. E2E_VERBOSE=1 also streams
# every step's output live; E2E_IMAGE swaps the emulator image.
# It runs on a throwaway copy of the project and cannot reach Azure: scrubbed environment, fake credentials only, the emulator's
# loopback as the provider's only redirect (ARM_METADATA_HOSTNAME), the state accounts' blob hosts mapped to the emulator alone, a
# dead proxy for every other host (proven by a curl first and a tofu drill during the run), and no Docker socket for either container.
# OpenTofu runs in its pinned image (.tool-versions) in the emulator's network namespace, because the backend's blob URL is fixed to
# https://<account>.blob.core.windows.net (a hosts entry, and the emulator's CA in SSL_CERT_FILE) and the azurerm provider on macOS
# ignores SSL_CERT_FILE. The first run downloads the provider for linux into the plugin cache next to the one for macOS.
set -euo pipefail
# the first image that answers 404 for a missing blob container (floci-az #523): 0.15.0 and latest answer 200 and azurerm_storage_container
# fails with "already exists"; move to the first release that has the fix
IMAGE=${E2E_IMAGE:-floci/floci-az:nightly-10232026@sha256:e97e84516a74a5c4256783b08734bb8df8bbc88268dd784c2253033195ceb398}
V=${E2E_VERBOSE:-} # 1: also stream every step's output live (it is logged either way); any other value: off

die() { echo "e2e: $*" >&2; exit 1; }
# step <label> <-|+needle|needle> <cmd...>: "-" must succeed, "+x" must succeed and print x, "x" must fail and print x.
# The label prints when the step starts, so a minute-long apply is not silent. With E2E_VERBOSE=1 the output also streams live (tee
# into the same log); tofu and curl may end it without a newline, so one is added before the ok line.
step() {
  local l=$1 n=$2 rc=0 t0=$SECONDS
  shift 2
  printf '  ..   %s\n' "$l"
  if [ "$V" = 1 ]; then
    "$@" 2>&1 | tee "$tmp/out" || rc=${PIPESTATUS[0]}
    [ -z "$(tail -c1 "$tmp/out")" ] || echo
  else "$@" >"$tmp/out" 2>&1 || rc=$?; fi
  case $n in -) [ "$rc" -eq 0 ] ;; +*) [ "$rc" -eq 0 ] && grep -qiF -- "${n#+}" "$tmp/out" ;; *) [ "$rc" -ne 0 ] && grep -qiF -- "$n" "$tmp/out" ;; esac ||
    { [ "$V" = 1 ] || tail -n 30 "$tmp/out" >&2; die "FAILED: $l"; }
  printf '  ok   %s (%ss)\n' "$l" "$((SECONDS - t0))"
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) # the project is the folder of this script, and that must be its git root
for t in docker terramate curl tar git; do command -v "$t" >/dev/null || die "$t not found (make setup)"; done
top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || die "run it inside the project's git checkout"
[ "$(cd "$top" && pwd -P)" = "$root" ] || die 'run "make e2e": it handles template checkouts'
tofu_ver=$(awk '$1 == "opentofu" { print $2 }' "$root/.tool-versions")
[ -n "$tofu_ver" ] || die ".tool-versions pins no opentofu version"
TOFU_IMAGE=ghcr.io/opentofu/opentofu:$tofu_ver
cache=${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}
for v in $(compgen -e); do # scrub: no credential, profile, proxy or git setting of yours can leak in
  case $v in AWS_* | ARM_* | AZURE_* | AZD_* | MSI_* | IDENTITY_* | ACTIONS_ID_TOKEN_REQUEST_* | SYSTEM_ACCESSTOKEN | CI_JOB_TOKEN | CI_JOB_JWT | CI_JOB_JWT_V2 | CI_REGISTRY_PASSWORD | GOOGLE_* | GCLOUD_* | GCP_* | CLOUDSDK_* | VSPHERE_* | GOVC_* | GITLAB_* | TF_* | GIT_* | *_PROXY | *_proxy | GITHUB_TOKEN | GH_TOKEN | TENV_GITHUB_TOKEN | HOMEBREW_GITHUB_API_TOKEN) unset "$v" ;; esac
done
mkdir -p "$cache"
export TF_PLUGIN_CACHE_DIR=$cache TF_INPUT=0 CHECKPOINT_DISABLE=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# fakes, the only credentials: the provider's only redirect is the emulator's own port (seen from inside its network namespace); the
# backend takes the access key before it tries Entra ID, so the generated backend stays as it is and its Entra ID path is not rehearsed
export ARM_METADATA_HOSTNAME=localhost:4577 ARM_USE_CLI=false ARM_RESOURCE_PROVIDER_REGISTRATIONS=none
export ARM_CLIENT_ID=00000000-0000-0000-0000-000000000003 ARM_CLIENT_SECRET=e2e-fake-secret ARM_TENANT_ID=00000000-0000-0000-0000-000000000002
export ARM_ACCESS_KEY=ZTJlLWZha2U= # any base64: floci-az checks no key

# the state accounts the generated backends name: each needs a hosts entry (<account>.blob.core.windows.net -> the emulator) and a NO_PROXY exception
accts=$(for f in "$root"/stacks/*/*/*/_terramate_generated_backend.tf; do [ ! -f "$f" ] || sed -n 's/^ *storage_account_name *= *"\(.*\)".*/\1/p' "$f"; done | sort -u)
[ -n "$accts" ] || die "no stacks/<environment>/<region>/<stack> with a generated azurerm backend: run make generate"
hosts=()
noproxy="localhost,127.0.0.1,registry.opentofu.org,github.com,release-assets.githubusercontent.com"
for s in $accts; do hosts+=(--add-host "$s.blob.core.windows.net:127.0.0.1"); noproxy+=",$s.blob.core.windows.net"; done
# tripwire: all but loopback, the registry hosts and those blob hosts dies at a dead proxy; proven before use
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY=$noproxy
case $(curl -q -sS -m 5 -o /dev/null https://tripwire.invalid/ 2>&1 || true) in *"127.0.0.1 port 9"*) ;; *) die "the tripwire is not armed" ;; esac

# floci-az on 127.0.0.1 with a random port, always removed (with its volume) on exit; its TLS endpoint answers for the blob hosts. First the
# lock holder (lock(): a tofu console reading a FIFO) is released and awaited while floci-az still answers, so its unlock reaches the emulator.
name=floci-az-e2e-$$
tmp=$(mktemp -d "${TMPDIR:-/tmp}/e2e.XXXXXX") && tmp=$(cd "$tmp" && pwd -P) # the physical path: Terramate and pwd -P report it, and the tofu shim mounts the same string
trap 'exec 3>&-; [ -z "${hp:-}" ] || wait "$hp" || true; docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT # || true: under set -e a failed wait or rm would skip the rest of the cleanup
docker image inspect "$TOFU_IMAGE" >/dev/null 2>&1 || { echo "e2e: pulling $TOFU_IMAGE"; docker pull -q "$TOFU_IMAGE" >/dev/null || die "could not pull $TOFU_IMAGE"; }
docker run -d --rm --name "$name" -p 127.0.0.1::4577 "${hosts[@]}" -e FLOCI_AZ_TLS_ENABLED=true -e 'FLOCI_AZ_HOSTNAME=*.blob.core.windows.net' "$IMAGE" >/dev/null || die "could not start $IMAGE"
port=$(docker port "$name" 4577/tcp | sed -n '1s/.*://p')
probe() { [ "$(curl -q -sS -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/ready" 2>/dev/null || true)" = 200 ]; }
for _ in $(seq 100); do probe && break; sleep 0.2; done
probe || die "floci-az does not answer at 127.0.0.1:$port"
curl -q -sf -m 5 "http://127.0.0.1:$port/_floci/tls-cert" -o "$tmp/ca.crt" || die "floci-az serves no TLS certificate (FLOCI_AZ_TLS_ENABLED)"
export SSL_CERT_FILE=$tmp/ca.crt

# tofu shim: the pinned OpenTofu in a container that shares the emulator's network namespace (its loopback and hosts file) and sees the
# same physical paths; only the variables listed enter it. terramate runs on the host and calls the shim.
mkdir "$tmp/bin"
cat >"$tmp/bin/tofu" <<EOF
#!/usr/bin/env bash
exec docker run --rm -i --network container:$name --user "\$(id -u):\$(id -g)" -v "$tmp:$tmp" -v "$cache:$cache" -w "\$(pwd -P)" -e HOME=/tmp \\
  -e TF_PLUGIN_CACHE_DIR -e TF_INPUT -e CHECKPOINT_DISABLE -e HTTPS_PROXY -e HTTP_PROXY -e ALL_PROXY -e NO_PROXY -e SSL_CERT_FILE \\
  -e ARM_METADATA_HOSTNAME -e ARM_USE_CLI -e ARM_RESOURCE_PROVIDER_REGISTRATIONS -e ARM_CLIENT_ID -e ARM_CLIENT_SECRET -e ARM_TENANT_ID -e ARM_ACCESS_KEY \\
  $TOFU_IMAGE "\$@"
EOF
chmod +x "$tmp/bin/tofu"
export PATH=$tmp/bin:$PATH

# throwaway project: tracked and unignored files in a scratch git repo (Terramate needs a clean git root)
mkdir "$tmp/p"
cd "$root"
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ ! -e "$f" ] || printf '%s\0' "$f"; done |
  tar --null -T - -cf - | tar -xf - -C "$tmp/p"
cd "$tmp/p"
git init -q -b main . && git add -A && git -c user.name=e2e -c user.email=e2e@e2e.invalid commit -q -m e2e
# floci-az gaps, as a gitignored override in the copy only (README: Not covered). It emulates no role assignment (every
# Microsoft.Authorization route answers 404), no management lock and no lifecycle management policy (their GET answers with the
# storage account), and it echoes a fixed storage account (LRS, https_traffic_only false, TLS1_0, shared keys and local users on,
# Account key types, no blob properties), which every second plan would show as changes, some forcing replacement. for_each, not count:
# the module sets for_each.
cat >modules/state-backend/e2e_override.tf <<'EOF'
resource "azurerm_role_assignment" "state_contributor" {
  for_each = toset([])
}

resource "azurerm_management_lock" "state" {
  count = 0
}

resource "azurerm_storage_management_policy" "state" {
  count = 0
}

resource "azurerm_storage_account" "state" {
  lifecycle {
    ignore_changes = [account_replication_type, default_to_oauth_authentication, https_traffic_only_enabled, infrastructure_encryption_enabled, local_user_enabled, min_tls_version, public_network_access, queue_encryption_key_type, shared_access_key_enabled, table_encryption_key_type, blob_properties]
  }
}
EOF

at() { (cd "$1" && shift && "$@"); }
tm() { at "stacks/$a" terramate run --no-tags state-backend "$@"; } # the environment's stacks except the state-backends
bk() { local v; v=$(sed -n "s/^ *$2 *= *\"\(.*\)\".*/\1/p" "$1/_terramate_generated_backend.tf"); printf '%s' "${v%%$'\n'*}"; }
blob() { local s=$1; shift; curl -q -sS -m 10 "$@" "http://127.0.0.1:$port/$(bk "$s" storage_account_name)/$(bk "$s" container_name)/$(bk "$s" key)"; } # path-style over plain http: floci-az checks no key
obj() { step "${1#stacks/} state blob exists under its generated key" - blob "$1" -fI; }

boot() { # README Bootstrap, literally: local state first, then migrated into the container it created
  local sb=$1 t=${1#stacks/}
  printf 'terraform {\n  backend "local" {}\n}\n' >"$sb/backend_override.tf"
  step "$t init" - at "$sb" tofu init
  step "$t plan" - at "$sb" tofu plan -out=tfplan
  # once: without the metadata host the provider addresses real Azure and must die at the proxy
  [ -n "${drilled:-}" ] || { drilled=1; (unset ARM_METADATA_HOSTNAME; step "tripwire drill: no metadata host override dies at the proxy" "proxyconnect tcp" at "$sb" tofu plan -no-color); }
  step "$t apply (the provider polls every Azure write, a resource group for 20 s)" - at "$sb" tofu apply tfplan
  rm "$sb/backend_override.tf"
  step "$t migrate state into the container" - at "$sb" tofu init -migrate-state -force-copy
  step "$t state is read from the azurerm backend" +azurerm_storage_container.state at "$sb" tofu state list
  step "$t plan is clean" "+No changes" at "$sb" tofu plan -no-color
  rm -f "$sb"/terraform.tfstate* "$sb/tfplan"
  obj "$sb"
}

lock() { # a held lock is a lease on the state blob and refuses a second operation; tofu console holds it until its stdin closes
  local s=$1 h=$tmp/hold-$a
  mkfifo "$h"
  (cd "$s" && exec tofu console <"$h" >/dev/null 2>&1) &
  hp=$! # global: the EXIT trap releases and awaits the holder when a step fails
  exec 3>"$h"
  for _ in $(seq 60); do grep -qi 'x-ms-lease-status: locked' <<<"$(blob "$s" -I 2>/dev/null || true)" && break; sleep 0.5; done
  step "${s#stacks/} a second operation is refused while the lock is held" "state blob is already locked" at "$s" tofu plan -no-color -lock-timeout=0s
  exec 3>&-
  wait "$hp" || true
  hp=
  step "${s#stacks/} the lock is released" - at "$s" tofu plan -lock-timeout=0s
}

# refused <address>: the output of the last step holds tofu's prevent_destroy refusal for that resource (tofu wraps its messages at 78 columns: squeeze first)
refused() { tr -s '[:space:]' ' ' <"$tmp/out" | grep -qF "Resource instance $1 has prevent_destroy set" || { [ "$V" = 1 ] || tail -n 30 "$tmp/out" >&2; die "no prevent_destroy refusal for $1"; }; }

envs=0
for d in stacks/*/; do
  a=${d#stacks/}
  a=${a%/}
  sbs=$(for f in "stacks/$a"/*/*/_terramate_generated_state_backend.tf; do [ ! -f "$f" ] || echo "${f%/*}"; done)
  [ -n "$sbs" ] || continue
  envs=$((envs + 1))
  first=${sbs%%$'\n'*}
  echo "== environment $a"
  work=$(terramate list --no-tags state-backend | grep "^stacks/$a/" || true)
  for sb in $sbs; do boot "$sb"; done
  if [ -n "$work" ]; then
    step "$a init" - tm -- tofu init
    step "$a plan" - tm -- tofu plan -out=tfplan
    step "$a apply of the saved plans" - tm -- tofu apply tfplan
    for s in $work; do obj "$s"; done
    # -detailed-exitcode: terramate counts exit 2 (changes) as a failure, which daily runs cannot use and this check wants: one clean stack must not hide a dirty one
    step "$a second plan is clean" "+No changes" tm -- tofu plan -no-color -detailed-exitcode
  fi
  lock "$first"
  if [ -f "$first/_terramate_generated_destroy_guard.tf" ]; then # protect_destroy is set for this environment
    step "$a destroy is blocked by the guard" "Resource instance terraform_data.destroy_guard has prevent_destroy" tm --reverse -- tofu plan -destroy -no-color -out=tfplan
  elif [ -n "$work" ]; then
    step "$a destroy plan" - tm --reverse -- tofu plan -destroy -out=tfplan
    step "$a destroy apply of the saved plan" - tm --reverse -- tofu apply tfplan
  fi
  step "$a state-backend destroy is blocked by prevent_destroy" "Resource instance cannot be destroyed" at "stacks/$a" terramate run --reverse --tags state-backend -- tofu plan -destroy -no-color -out=tfplan
  # A destroy starts at the container, and a failed resource stops everything that waits for it: the plan names only the container. The account
  # and the resource group each get a replace plan, which prevent_destroy refuses as well.
  refused module.state_backend.azurerm_storage_container.state
  for r in azurerm_storage_account azurerm_resource_group; do
    step "$a state-backend replacing $r.state is refused by prevent_destroy" "Resource instance cannot be destroyed" at "stacks/$a" terramate run --tags state-backend -- tofu plan -no-color -replace="module.state_backend.$r.state"
    refused "module.state_backend.$r.state"
  done
done
[ "$envs" -gt 0 ] || die "no stacks/<environment>/<region>/ with generated files: run make generate"
echo "e2e: all checks passed in ${SECONDS}s; floci-az removed on exit, Azure never contacted"
