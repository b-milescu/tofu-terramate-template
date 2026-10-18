#!/usr/bin/env bash
# Rehearses the README's Bootstrap, Operate and Destroy against floci (https://github.com/floci-io/floci), a local AWS emulator
# in Docker: `make e2e` (in a template checkout make runs it in a throwaway project). Needs Docker, tofu, terramate (make setup),
# curl, and network for the registry and GitHub, never for AWS. E2E_VERBOSE=1 also streams every step's output live.
# It runs on a throwaway copy of the project and cannot reach AWS: scrubbed environment, fake credentials only (the account id
# as access key id), AWS_ENDPOINT_URL as the only redirect (loopback, random port, preflighted), a dead proxy for every other
# host (proven by a curl first and a tofu drill during the run), and no Docker socket for floci.
set -euo pipefail
IMAGE=${E2E_IMAGE:-floci/floci:latest}
DRIFT="module.vpc.aws_default_network_acl.this[0] module.vpc.aws_flow_log.this[0]" # floci #5720, #5729: delete them when those issues close
V=${E2E_VERBOSE:-} # 1: also stream every step's output live (it is logged either way); any other value: off
OTHER=999999999999

die() { echo "e2e: $*" >&2; exit 1; }
# step <label> <-|+needle|needle> <cmd...>: "-" must succeed, "+x" must succeed and print x, "x" must fail and print x.
# The label prints when the step starts, so a minute-long apply is not silent. With E2E_VERBOSE=1 the output also streams live (tee
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
  case $v in AWS_* | ARM_* | AZURE_* | AZD_* | GOOGLE_* | GCP_* | CLOUDSDK_* | TF_* | GIT_* | *_PROXY | *_proxy | GITHUB_TOKEN | GH_TOKEN | TENV_GITHUB_TOKEN) unset "$v" ;; esac
done
mkdir -p "$cache"
export TF_PLUGIN_CACHE_DIR=$cache TF_INPUT=0 CHECKPOINT_DISABLE=1 AWS_ACCESS_KEY_ID=000000000000 AWS_SECRET_ACCESS_KEY=floci-fake-secret
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# tripwire: all but loopback and the registry hosts dies at a dead proxy; proven before use
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
export NO_PROXY="localhost,127.0.0.1,registry.opentofu.org,github.com,release-assets.githubusercontent.com"
case $(curl -q -sS -m 5 -o /dev/null https://tripwire.invalid/ 2>&1 || true) in *"127.0.0.1 port 9"*) ;; *) die "the tripwire is not armed" ;; esac

# floci on 127.0.0.1 with a random port, always removed (with its volume) on exit
name=floci-e2e-$$
tmp=$(mktemp -d "${TMPDIR:-/tmp}/e2e.XXXXXX")
trap 'docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT # || true: under set -e a failed rm would skip the cleanup
docker run -d --rm --name "$name" -p 127.0.0.1::4566 "$IMAGE" >/dev/null || die "could not start $IMAGE"
port=$(docker port "$name" 4566/tcp | sed -n '1s/.*://p')
export AWS_ENDPOINT_URL=http://localhost:$port # the only redirect; preflight: floci's S3 Control route answers at <account id>.localhost (macOS resolves it to loopback)
probe() { grep -q awss3control <<<"$(curl -q -sS -m 3 "http://$OTHER.localhost:$port/v20180820/tags/arn%3Aaws%3As3%3A%3A%3Ae2e" 2>/dev/null || true)"; }
for _ in $(seq 60); do probe && break; sleep 0.5; done
probe || die "floci does not answer at $OTHER.localhost:$port (e2e runs on macOS with Docker Desktop only)"

# throwaway project: tracked and unignored files in a scratch git repo (Terramate needs a clean git root)
mkdir "$tmp/p"
cd "$root"
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ ! -e "$f" ] || printf '%s\0' "$f"; done |
  tar --null -T - -cf - | tar -xf - -C "$tmp/p"
cd "$tmp/p"
git init -q -b main . && git add -A && git -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m e2e

at() { (cd "$1" && shift && "$@"); }
tm() { at "stacks/$a" terramate run --no-tags state-backend "$@"; } # the account's stacks except the state-backends
bk() { local v; v=$(sed -n "s/^ *$2 *= *\"\(.*\)\".*/\1/p" "$1/_terramate_generated_backend.tf"); printf '%s' "${v%%$'\n'*}"; }
sig() { curl -q -fsS -m 20 --aws-sigv4 "aws:amz:$1:$2" -u "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "${@:3}"; }
obj() { step "${1#stacks/} state object exists under its generated key" - sig "$(bk "$1" region)" s3 -I "$AWS_ENDPOINT_URL/$(bk "$1" bucket)/$(bk "$1" key)"; }

boot() { # README Bootstrap, literally: local state first, then migrated into the bucket it created
  local sb=$1 t=${1#stacks/} al
  printf 'terraform {\n  backend "local" {}\n}\n' >"$sb/backend_override.tf"
  step "$t init" - at "$sb" tofu init
  step "$t plan" - at "$sb" tofu plan -out=tfplan
  # once: without the endpoint the provider addresses real AWS and must die at the proxy
  [ -n "${drilled:-}" ] || { drilled=1; (unset AWS_ENDPOINT_URL; export AWS_MAX_ATTEMPTS=1; step "tripwire drill: no endpoint override dies at the proxy" "proxyconnect tcp" at "$sb" tofu plan -no-color); }
  step "$t apply (a minute: the AWS provider waits 55 s for the bucket lifecycle rule)" - at "$sb" tofu apply tfplan
  rm "$sb/backend_override.tf"
  step "$t migrate state into the bucket" - at "$sb" tofu init -migrate-state -force-copy
  step "$t plan is clean" "+No changes" at "$sb" tofu plan -no-color
  rm -f "$sb"/terraform.tfstate* "$sb/tfplan"
  obj "$sb"
  al=$(bk "$sb" kms_key_id) # floci takes any alias on PutObject: check that the backend's alias is the one the module created
  step "alias/${al##*alias/} exists" - sig "$(bk "$sb" region)" kms -H 'Content-Type: application/x-amz-json-1.1' -H 'X-Amz-Target: TrentService.DescribeKey' -d '{"KeyId":"alias/'"${al##*alias/}"'"}' "$AWS_ENDPOINT_URL/"
}

lock() { # a held lock is an S3 object and refuses a second operation; tofu console holds it until its stdin closes
  local s=$1 h=$tmp/hold-$a
  mkfifo "$h"
  (cd "$s" && exec tofu console <"$h" >/dev/null 2>&1) &
  exec 3>"$h"
  for _ in $(seq 40); do sig "$(bk "$s" region)" s3 -I "$AWS_ENDPOINT_URL/$(bk "$s" bucket)/$(bk "$s" key).tflock" >/dev/null 2>&1 && break; sleep 0.5; done
  step "${s#stacks/} a second operation is refused while the lock is held" "PreconditionFailed" at "$s" tofu plan -no-color -lock-timeout=0s
  exec 3>&-
  wait || true
  step "${s#stacks/} the lock is released" - at "$s" tofu plan -lock-timeout=0s
}

accounts=0
for d in stacks/*/; do
  a=${d#stacks/}
  a=${a%/}
  sbs=$(for f in "stacks/$a"/*/*/_terramate_generated_state_backend.tf; do [ ! -f "$f" ] || echo "${f%/*}"; done)
  [ -n "$sbs" ] || continue
  accounts=$((accounts + 1))
  first=${sbs%%$'\n'*}
  AWS_ACCESS_KEY_ID=$(grep -Eo 'arn:aws:kms:[a-z0-9-]+:[0-9]{12}' "$first/_terramate_generated_backend.tf" | grep -Eo '[0-9]{12}')
  echo "== account $a ($AWS_ACCESS_KEY_ID)"
  work=$(terramate list --no-tags state-backend | grep "^stacks/$a/" || true)
  for sb in $sbs; do boot "$sb"; done
  if [ -n "$work" ]; then
    step "$a init" - tm -- tofu init
    step "$a plan" - tm -- tofu plan -out=tfplan
    step "$a apply of the saved plans" - tm -- tofu apply tfplan
    for s in $work; do obj "$s"; done
    step "$a second plan" - tm -- tofu plan -no-color
    while IFS= read -r r; do # only the known floci gaps may still show as changes
      case " $DRIFT " in *" $r "*) ;; *) die "$a: the second plan wants to change $r" ;; esac
    done < <(sed -En 's/^  # (.+) (will be|must be) .*/\1/p' "$tmp/out")
  fi
  AWS_ACCESS_KEY_ID=$OTHER step "$a the backend refuses another account" "Invalid account ID" at "$first" tofu plan -no-color
  lock "$first"
  if [ -f "$first/_terramate_generated_destroy_guard.tf" ]; then # protect_destroy is set for this account
    step "$a destroy is blocked by the guard" "Resource instance terraform_data.destroy_guard has prevent_destroy" tm --reverse -- tofu plan -destroy -no-color -out=tfplan
  elif [ -n "$work" ]; then
    step "$a destroy plan" - tm --reverse -- tofu plan -destroy -out=tfplan
    step "$a destroy apply of the saved plan" - tm --reverse -- tofu apply tfplan
  fi
  step "$a state-backend destroy is blocked by prevent_destroy" "Resource instance cannot be destroyed" at "stacks/$a" terramate run --reverse --tags state-backend -- tofu plan -destroy -no-color -out=tfplan
done
[ "$accounts" -gt 0 ] || die "no stacks/<account>/<region>/ with generated files: run make generate"
echo "e2e: all checks passed in ${SECONDS}s; floci removed on exit, AWS never contacted"
