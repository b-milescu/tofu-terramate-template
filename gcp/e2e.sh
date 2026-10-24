#!/usr/bin/env bash
# Rehearses the README's Bootstrap, Operate and Destroy against floci-gcp (https://github.com/floci-io/floci-gcp), a local Google Cloud
# emulator in Docker: `make e2e` (in a template checkout make runs it in a throwaway project). Needs Docker, tofu, terramate (make setup),
# curl, and network for the registry and GitHub, never for Google Cloud. E2E_VERBOSE=1 also streams every step's output live;
# E2E_IMAGE picks another floci-gcp image. It runs on a throwaway copy of the project and cannot reach Google Cloud: scrubbed
# environment, a fake access token only, GOOGLE_STORAGE_CUSTOM_ENDPOINT, GOOGLE_COMPUTE_CUSTOM_ENDPOINT and GOOGLE_KMS_CUSTOM_ENDPOINT
# as the only redirects (loopback, random port, preflighted), a dead proxy for every other host (proven by a curl first and a tofu
# drill during the run), and no Docker socket for floci-gcp.
set -euo pipefail
IMAGE=${E2E_IMAGE:-floci/floci-gcp:0.11.0}
V=${E2E_VERBOSE:-} # 1: also stream every step's output live (it is logged either way); any other value: off

die() { echo "e2e: $*" >&2; exit 1; }
# step <label> <-|+needle|needle> <cmd...>: "-" must succeed, "+x" must succeed and print x, "x" must fail and print x.
# The label prints when the step starts, so a long apply is not silent. With E2E_VERBOSE=1 the output also streams live (tee
# into the same log); tofu and curl may end it without a newline, so one is added before the ok line.
step() {
  local l=$1 n=$2 rc=0
  shift 2
  printf '  ..   %s\n' "$l"
  if [ "$V" = 1 ]; then
    "$@" 2>&1 | tee "$tmp/out" || rc=${PIPESTATUS[0]}
    [ -z "$(tail -c1 "$tmp/out")" ] || echo
  else "$@" >"$tmp/out" 2>&1 || rc=$?; fi
  case $n in -) [ "$rc" -eq 0 ] ;; +*) [ "$rc" -eq 0 ] && grep -qiF -- "${n#+}" "$tmp/out" ;; *) [ "$rc" -ne 0 ] && grep -qiF -- "$n" "$tmp/out" ;; esac ||
    { [ "$V" = 1 ] || tail -n 30 "$tmp/out" >&2; die "FAILED: $l"; }
  printf '  ok   %s\n' "$l"
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) # the project is the folder of this script, and that must be its git root
top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || die "run it inside the project's git checkout"
[ "$(cd "$top" && pwd -P)" = "$root" ] || die 'run "make e2e": it handles template checkouts'
for t in docker tofu terramate curl tar; do command -v "$t" >/dev/null || die "$t not found (make setup)"; done
cache=${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}
for v in $(compgen -e); do # scrub: no credential, profile, proxy or git setting of yours can leak in
  case $v in AWS_* | ARM_* | AZURE_* | AZD_* | MSI_* | IDENTITY_* | ACTIONS_ID_TOKEN_REQUEST_* | SYSTEM_ACCESSTOKEN | CI_JOB_TOKEN | CI_JOB_JWT | CI_JOB_JWT_V2 | CI_REGISTRY_PASSWORD | GOOGLE_* | GCLOUD_* | GCP_* | CLOUDSDK_* | VSPHERE_* | GOVC_* | GITLAB_* | TF_* | GIT_* | *_PROXY | *_proxy | GITHUB_TOKEN | GH_TOKEN | TENV_GITHUB_TOKEN | HOMEBREW_GITHUB_API_TOKEN) unset "$v" ;; esac
done
mkdir -p "$cache"
export TF_PLUGIN_CACHE_DIR=$cache TF_INPUT=0 CHECKPOINT_DISABLE=1 GOOGLE_OAUTH_ACCESS_TOKEN=floci-fake-token
export GOOGLE_APPLICATION_CREDENTIALS=/dev/null GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 # /dev/null as ADC file: were the fake token ever ignored, the run fails instead of using yours
# tripwire: all but loopback and the registry hosts dies at a dead proxy; proven before use
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
export NO_PROXY="localhost,127.0.0.1,registry.opentofu.org,github.com,release-assets.githubusercontent.com"
case $(curl -q -sS -m 5 -o /dev/null https://tripwire.invalid/ 2>&1 || true) in *"127.0.0.1 port 9"*) ;; *) die "the tripwire is not armed" ;; esac

# floci-gcp on 127.0.0.1 with a random port, always removed (with its volume) on exit. First the lock holder (lock(): a tofu console reading a
# FIFO) is released and awaited while floci-gcp still answers: a console that loses its backend retries forever and outlives the script.
name=floci-gcp-e2e-$$
tmp=$(mktemp -d "${TMPDIR:-/tmp}/e2e.XXXXXX")
trap 'exec 3>&-; [ -z "${hp:-}" ] || wait "$hp" || true; docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT # || true: under set -e a failed wait or rm would skip the rest of the cleanup
docker run -d --rm --name "$name" -p 127.0.0.1::4588 "$IMAGE" >/dev/null || die "could not start $IMAGE"
port=$(docker port "$name" 4588/tcp | sed -n '1s/.*://p')
ep=http://127.0.0.1:$port
probe() { curl -q -fsS -m 2 -o /dev/null "$ep/health" 2>/dev/null; }
for _ in $(seq 100); do probe && break; sleep 0.2; done
probe || die "floci-gcp does not answer at $ep"
# the only redirects; the storage endpoint serves the provider and the gcs backend alike
export GOOGLE_STORAGE_CUSTOM_ENDPOINT=$ep/storage/v1/ GOOGLE_COMPUTE_CUSTOM_ENDPOINT=$ep/compute/v1/ GOOGLE_KMS_CUSTOM_ENDPOINT=$ep/v1/

# throwaway project: tracked and unignored files in a scratch git repo (Terramate needs a clean git root)
mkdir "$tmp/p"
cd "$root"
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ ! -e "$f" ] || printf '%s\0' "$f"; done |
  tar --null -T - -cf - | tar -xf - -C "$tmp/p"
cd "$tmp/p"
git init -q -b main . && git add -A && git -c user.name=e2e -c user.email=e2e@e2e.invalid commit -q -m e2e
# gitignored *_override.tf files, written into the copy after the commit. 1) In the module, what floci-gcp 0.11.0 does not emulate: IAM
# policies on keys, the key's rotation period and labels (the provider's default_labels included) and the bucket's default key. The
# lifecycle blocks merge with the module's prevent_destroy, so the destroy refusals below still hold. What this rehearsal cannot show
# for that reason: the service agent's grant on the key, the key as the bucket's default key, the rotation.
cat >modules/state-backend/e2e_override.tf <<'EOF'
resource "google_kms_crypto_key_iam_member" "gcs" {
  count = 0 # getIamPolicy on a key answers 404
}

resource "google_kms_crypto_key" "state" {
  lifecycle {
    ignore_changes = [rotation_period, labels, terraform_labels, effective_labels] # not stored
  }
}

resource "google_storage_bucket" "state" {
  lifecycle {
    ignore_changes = [encryption] # not stored
  }
}
EOF
# 2) every stack: operations polled every 100 ms instead of 10 s, and a universe_domain other than googleapis.com, which stops the
# provider's own call to openidconnect.googleapis.com and turns any endpoint without a redirect into https://<service>.e2e.invalid
for d in stacks/*/*/*/; do printf 'provider "google" {\n  poll_interval   = "100ms"\n  universe_domain = "e2e.invalid"\n}\n' >"$d/e2e_override.tf"; done

at() { (cd "$1" && shift && "$@"); }
tm() { at "stacks/$a" terramate run --no-tags state-backend "$@"; } # the environment's stacks except the state-backends
bk() { local v; v=$(sed -n "s/^ *$3 *= *\"\(.*\)\".*/\1/p" "$1/_terramate_generated_$2.tf"); printf '%s' "${v%%$'\n'*}"; } # bk <stack> <generated file> <attribute>
gcs() { curl -q -fsS -m 10 -o /dev/null "$@"; }
ou() { printf '%s/storage/v1/b/%s/o/%s%%2F%s' "$ep" "$(bk "$1" backend bucket)" "$(bk "$1" backend prefix | sed 's#/#%2F#g')" "$2"; } # state or lock object of a stack
obj() { step "${1#stacks/} state object exists under its generated prefix" - gcs "$(ou "$1" default.tfstate)"; }
# refused <address>: the output of the last step holds tofu's prevent_destroy refusal for that resource (tofu wraps its messages at 78 columns: squeeze first)
refused() { tr -s ' \n' ' ' <"$tmp/out" | grep -qF "Resource instance $1 has prevent_destroy set" || { [ "$V" = 1 ] || tail -n 30 "$tmp/out" >&2; die "no prevent_destroy refusal for $1"; }; }

boot() { # README Bootstrap, literally: local state first, then migrated into the bucket it created
  local sb=$1 t=${1#stacks/}
  printf 'terraform {\n  backend "local" {}\n}\n' >"$sb/backend_override.tf"
  step "$t init" - at "$sb" tofu init
  step "$t plan" - at "$sb" tofu plan -out=tfplan
  step "$t apply" - at "$sb" tofu apply tfplan
  rm "$sb/backend_override.tf"
  step "$t migrate state into the bucket" - at "$sb" tofu init -migrate-state -force-copy
  step "$t plan is clean" "+No changes" at "$sb" tofu plan -no-color
  rm -f "$sb"/terraform.tfstate* "$sb/tfplan"
  obj "$sb"
  # floci stores neither the bucket's default key nor its name: check that the key itself exists
  step "$t KMS key exists" - gcs "$ep/v1/projects/$proj/locations/$(bk "$sb" state_backend location)/keyRings/$(bk "$sb" state_backend kms_key_ring_name)/cryptoKeys/$(bk "$sb" state_backend kms_key_name)"
}

lock() { # a held lock is an object and refuses a second operation; tofu console holds it until its stdin closes
  local s=$1 h=$tmp/hold-$a id
  mkfifo "$h"
  (cd "$s" && exec tofu console <"$h" >/dev/null 2>&1) &
  hp=$! # global: the EXIT trap releases and awaits the holder when a step fails
  exec 3>"$h"
  for _ in $(seq 40); do gcs "$(ou "$s" default.tflock)" 2>/dev/null && break; sleep 0.5; done
  step "${s#stacks/} a second operation is refused while the lock is held" "conditionNotMet" at "$s" tofu plan -no-color -lock-timeout=0s
  id=$(sed -n '/^  ID: */{s///p;q;}' "$tmp/out") # locks never expire; the lock id is the lock object's generation
  step "${s#stacks/} force-unlock removes the held lock" - at "$s" tofu force-unlock -no-color -force "$id"
  step "${s#stacks/} a plan takes the lock again after the force-unlock" - at "$s" tofu plan -lock-timeout=0s
  exec 3>&-
  wait "$hp" || true # the console's own unlock finds its lock gone and may fail
  hp=
}

envs=0
for d in stacks/*/; do
  a=${d#stacks/}
  a=${a%/}
  sbs=$(for f in "stacks/$a"/*/*/_terramate_generated_state_backend.tf; do [ ! -f "$f" ] || echo "${f%/*}"; done)
  [ -n "$sbs" ] || continue
  envs=$((envs + 1))
  first=${sbs%%$'\n'*}
  proj=$(sed -n 's/^  project *= *"\(.*\)".*/\1/p' "$first/_terramate_generated_provider.tf") # two spaces: not the project label of default_labels
  echo "== environment $a (project $proj)"
  work=$(terramate list --no-tags state-backend | grep "^stacks/$a/" || true)
  for sb in $sbs; do boot "$sb"; done
  if [ -n "$work" ]; then
    step "$a init" - tm -- tofu init
    step "$a plan" - tm -- tofu plan -out=tfplan
    step "$a apply of the saved plans" - tm -- tofu apply tfplan
    for s in $work; do obj "$s"; done
    step "$a second plan is clean" "+No changes" tm -- tofu plan -no-color -detailed-exitcode
    # once: a service without its redirect addresses the real endpoint and must die at the proxy
    [ -n "${drilled:-}" ] || { drilled=1; step "tripwire drill: no compute endpoint override dies at the proxy" "proxyconnect tcp" tm -- env -u GOOGLE_COMPUTE_CUSTOM_ENDPOINT tofu plan -no-color; }
  fi
  lock "$first"
  if [ -f "$first/_terramate_generated_destroy_guard.tf" ]; then # protect_destroy is set for this environment
    step "$a destroy is blocked by the guard" "Resource instance terraform_data.destroy_guard has prevent_destroy" tm --reverse -- tofu plan -destroy -no-color -out=tfplan
  elif [ -n "$work" ]; then
    step "$a destroy plan" - tm --reverse -- tofu plan -destroy -out=tfplan
    step "$a destroy apply of the saved plan" - tm --reverse -- tofu apply tfplan
  fi
  step "$a state-backend destroy is blocked by prevent_destroy" "Resource instance cannot be destroyed" at "stacks/$a" terramate run --reverse --tags state-backend -- tofu plan -destroy -no-color -out=tfplan
  # A destroy starts at the bucket, and a failed resource stops everything that waits for it: the plan names only the bucket. The key and the
  # key ring each get a replace plan, which prevent_destroy refuses as well.
  refused module.state_backend.google_storage_bucket.state
  for r in google_kms_crypto_key google_kms_key_ring; do
    step "$a state-backend replacing $r.state is refused by prevent_destroy" "Resource instance cannot be destroyed" at "stacks/$a" terramate run --tags state-backend -- tofu plan -no-color -replace="module.state_backend.$r.state"
    refused "module.state_backend.$r.state"
  done
done
[ "$envs" -gt 0 ] || die "no stacks/<environment>/<region>/ with generated files: run make generate"
echo "e2e: all checks passed in ${SECONDS}s; floci-gcp removed on exit, Google Cloud never contacted"
