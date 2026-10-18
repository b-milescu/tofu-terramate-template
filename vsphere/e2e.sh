#!/usr/bin/env bash
# Rehearses the README's Operate and Destroy against vcsim (https://github.com/vmware/govmomi/tree/main/vcsim), the vCenter simulator,
# and a GitLab CE server for the managed state, both in Docker: `make e2e` (in a template checkout make runs it in a throwaway project).
# Needs macOS with Docker Desktop (the only host it was verified on; GitLab takes about 3.5 GiB of its memory), tofu and terramate
# (make setup), curl, and network for the OpenTofu registry and GitHub, never for your vCenter or GitLab; the first run also pulls about
# 1.5 GB of images from Docker Hub.
# E2E_VERBOSE=1 also streams every step's output live.
# It runs on a throwaway copy of the project and cannot reach your vCenter or GitLab: scrubbed environment, fake vCenter credentials and
# tokens of the throwaway GitLab only, a gitignored e2e_override.tf per stack that points its backend and provider at loopback (random
# ports, preflighted), a dead proxy for every other host (proven by a curl first and by two tofu drills during the run), and no Docker
# socket or mount for the containers.
# A third drill pins the TLS stance: with only vsphere_server redirected, the generated provider still verifies certificates and refuses
# vcsim's even with VSPHERE_ALLOW_UNVERIFIED_SSL=true in the environment; only the loopback override turns verification off.
set -euo pipefail
VCSIM_IMAGE=${E2E_VCSIM_IMAGE:-vmware/vcsim:v0.56.0} # linux/amd64 only, so it runs under emulation on arm64; "latest" is an older build
GITLAB_IMAGE=${E2E_GITLAB_IMAGE:-gitlab/gitlab-ce:19.4.2-ce.0}
V=${E2E_VERBOSE:-} # 1: also stream every step's output live (it is logged either way); any other value: off

die() { echo "e2e: $*" >&2; exit 1; }
# step <label> <-|+needle|needle> <cmd...>: "-" must succeed, "+x" must succeed and print x, "x" must fail and print x.
# The label prints when the step starts, so a minute-long wait is not silent. With E2E_VERBOSE=1 the output also streams live (tee
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
  case $v in AWS_* | ARM_* | AZURE_* | AZD_* | GOOGLE_* | GCP_* | CLOUDSDK_* | VSPHERE_* | GOVC_* | GITLAB_* | TF_* | GIT_* | *_PROXY | *_proxy | GITHUB_TOKEN | GH_TOKEN | TENV_GITHUB_TOKEN) unset "$v" ;; esac
done
mkdir -p "$cache"
export TF_PLUGIN_CACHE_DIR=$cache TF_INPUT=0 CHECKPOINT_DISABLE=1 VSPHERE_USER=e2e-user VSPHERE_PASSWORD=e2e-fake-password
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# tripwire: all but loopback and the registry hosts dies at a dead proxy; proven before use
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
export NO_PROXY="localhost,127.0.0.1,registry.opentofu.org,github.com,release-assets.githubusercontent.com"
case $(curl -q -sS -m 5 -o /dev/null https://tripwire.invalid/ 2>&1 || true) in *"127.0.0.1 port 9"*) ;; *) die "the tripwire is not armed" ;; esac

sim=vcsim-e2e-$$ gl=gitlab-e2e-$$
tmp=$(mktemp -d "${TMPDIR:-/tmp}/e2e.XXXXXX")
trap 'docker rm -fv "$sim" "$gl" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT # || true: under set -e a failed rm would skip the cleanup

# throwaway project: tracked and unignored files in a scratch git repo (Terramate needs a clean git root)
mkdir "$tmp/p"
cd "$root"
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ ! -e "$f" ] || printf '%s\0' "$f"; done |
  tar --null -T - -cf - | tar -xf - -C "$tmp/p"
cd "$tmp/p"
git init -q -b main . && git add -A && git -c user.name=e2e -c user.email=e2e@e2e.invalid commit -q -m e2e

all=$(terramate list | grep -E '^stacks/[^/]+/[^/]+/[^/]+' || true)
[ -n "$all" ] || die "no stacks/<environment>/<datacenter>/<stack> in the project"
for s in $all; do
  for g in backend provider versions datacenter; do [ -f "$s/_terramate_generated_$g.tf" ] || die "$s has no generated $g file: run make generate"; done
  [ -f "$s/.terraform.lock.hcl" ] || die "$s has no .terraform.lock.hcl: run make relock (the init here would create it and terramate run stops on untracked files)"
done
first=${all%%$'\n'*}
dcs=$(for s in $all; do sed -n 's/^ *name *= *\(".*"\).*/\1/p' "$s/_terramate_generated_datacenter.tf"; done | sort -u) # HCL string literals, quotes included

# GitLab first, it needs about 2 minutes to boot. Trimmed for a test: one Puma process, no metrics, KAS, registry or usage ping (a sampled
# peak of 3.3 GiB of RAM, about 3.8 with the default configuration). The readiness check answers 404 to the Docker port forward unless its
# address is allowed. Both containers listen on 127.0.0.1 with a random port and are removed with their volumes on exit.
pull() { docker image inspect "$1" >/dev/null 2>&1 || step "pull $1 (first run only)" - docker pull -q ${2:+--platform "$2"} "$1"; }
pull "$GITLAB_IMAGE"
pull "$VCSIM_IMAGE" linux/amd64
omnibus="external_url 'http://127.0.0.1'; gitlab_rails['monitoring_whitelist']=['0.0.0.0/0']; puma['worker_processes']=0; sidekiq['concurrency']=5; prometheus_monitoring['enable']=false; gitlab_kas['enable']=false; registry['enable']=false; postgresql['shared_buffers']='128MB'; gitlab_rails['usage_ping_enabled']=false"
docker run -d --rm --name "$gl" --shm-size 256m -p 127.0.0.1::80 -e GITLAB_OMNIBUS_CONFIG="$omnibus" "$GITLAB_IMAGE" >/dev/null || die "could not start $GITLAB_IMAGE"
docker run -d --rm --name "$sim" --platform linux/amd64 -p 127.0.0.1::8989 "$VCSIM_IMAGE" -l 0.0.0.0:8989 -dc 0 >/dev/null || die "could not start $VCSIM_IMAGE"
glport=$(docker port "$gl" 80/tcp | sed -n '1s/.*://p')
simport=$(docker port "$sim" 8989/tcp | sed -n '1s/.*://p')

at() { (cd "$1" && shift && "$@"); }
tm() { at "stacks/$e" terramate run "$@"; } # the environment's stacks
val() { sed -n "s/^ *$2 *= *\"\(.*\)\".*/\1/p" "$1"; } # the quoted value of an attribute in an HCL file
api() { curl -q -fsS -m 60 -H "PRIVATE-TOKEN: $pat" "http://127.0.0.1:$glport/api/v4/$1" "${@:2}"; }
id() { sed -n 's/^{"id":\([0-9]*\),.*/\1/p' "$tmp/out"; } # the id of the object the last step created
state() { curl -q -fsS -m 20 -u "root:$pat" "$1" | grep -o '"lineage":"[^"]*"'; } # a stored state: a state without a version answers 204 and has no lineage

# vcsim starts empty (-dc 0): create the datacenters the stacks look up, with the stacks' provider pin and a scratch root module
simup() { curl -q -fsS -m 3 -k -o /dev/null "https://127.0.0.1:$simport/about" 2>/dev/null; } # -k: the simulator's certificate is self-signed
for _ in $(seq 60); do simup && break; sleep 0.5; done
simup || die "vcsim does not answer at 127.0.0.1:$simport"
mkdir "$tmp/dc"
cp "$first/_terramate_generated_versions.tf" "$tmp/dc/"
[ ! -f "$first/.terraform.lock.hcl" ] || cp "$first/.terraform.lock.hcl" "$tmp/dc/"
{
  printf 'provider "vsphere" {\n  vsphere_server       = "127.0.0.1:%s"\n  allow_unverified_ssl = true\n}\n' "$simport"
  n=0
  while IFS= read -r l; do
    n=$((n + 1))
    printf 'resource "vsphere_datacenter" "d%s" {\n  name = %s\n}\n' "$n" "$l"
  done <<<"$dcs"
} >"$tmp/dc/main.tf"
step "vcsim datacenters init" - at "$tmp/dc" tofu init
step "vcsim datacenters plan" - at "$tmp/dc" tofu plan -out=tfplan
step "vcsim datacenters apply (5 s: the provider's own wait)" - at "$tmp/dc" tofu apply tfplan

# drill: the generated backend, untouched, addresses a host that is not loopback and must die at the proxy. No retries (the backend's
# retry_wait_min = 5 would make it 15 s) and a data directory of its own (init saves the backend it configured before it fails to read it)
(export TF_HTTP_RETRY_MAX=0 TF_DATA_DIR="$tmp/drill"; step "tripwire drill: no backend override dies at the proxy" "proxyconnect" at "$first" tofu init -no-color)

# GitLab: a root token (the only way in: the password grant is off), the project that holds the states, and a user that is not a member
gitlab_ready() { # its readiness check covers the database, Redis and Gitaly
  local end=$((SECONDS + 600))
  while [ "$SECONDS" -lt "$end" ]; do
    curl -q -fsS -m 5 -o /dev/null "http://127.0.0.1:$glport/-/readiness?all=1" 2>/dev/null && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$gl" 2>/dev/null)" = true ] || { echo "the GitLab container stopped (Docker Desktop needs about 3.5 GiB of memory for it)"; return 1; }
    sleep 2
  done
  echo "GitLab was not ready after 10 minutes"
  docker logs --tail 20 "$gl" 2>&1
  return 1
}
step "GitLab is ready (about 2 minutes after it started)" - gitlab_ready
ruby="u = User.find_by_username('root')
attrs = { scopes: [:api], name: 'e2e', expires_at: 30.days.from_now }
attrs[:organization] = Organizations::Organization.default_organization if PersonalAccessToken.column_names.include?('organization_id')
puts 'TOKEN=' + u.personal_access_tokens.create!(attrs).token"
step "GitLab root token (30 s: Rails boots)" +TOKEN= docker exec "$gl" gitlab-rails runner "$ruby"
pat=$(sed -n 's/^TOKEN=//p' "$tmp/out")
step "GitLab project for the states" +'"id":' api projects -d name=e2e -d visibility=private
proj=http://127.0.0.1:$glport/api/v4/projects/$(id)
step "GitLab user without membership" +'"id":' api users -d email=outsider@e2e.invalid -d username=outsider -d name=outsider -d force_random_password=true -d skip_confirmation=true
step "its api token" +'"token":' api "users/$(id)/personal_access_tokens" -d name=e2e -d 'scopes[]=api'
outsider=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$tmp/out")
export TF_HTTP_USERNAME=root TF_HTTP_PASSWORD=$pat

# e2e_override.tf per stack, gitignored: the generated blocks with only the endpoints replaced (override files merge into the originals)
ovr_backend() { # GitLab on loopback; same state name, lock paths and methods
  sed -e '/^\/\//d' -e "s#\"https://[^\"]*/api/v4/projects/[0-9]*/#\"$proj/#" "$1/_terramate_generated_backend.tf" >"$1/e2e_override.tf"
  [ "$(grep -c "\"$proj/" "$1/e2e_override.tf")" -eq 3 ] || die "$1: the generated backend has no address, lock_address and unlock_address of the form https://<host>/api/v4/projects/<id>/..."
}
ovr_provider() { # vcsim; the certificate check goes off because the provider has no CA option and on macOS ignores SSL_CERT_FILE
  sed -e '/^\/\//d' -e "s/^\( *vsphere_server *= *\).*/\1\"127.0.0.1:$simport\"/" -e 's/^\( *allow_unverified_ssl *= *\)false/\1true/' "$1/_terramate_generated_provider.tf" >>"$1/e2e_override.tf"
  { grep -q "^ *vsphere_server *= *\"127.0.0.1:$simport\"" "$1/e2e_override.tf" && grep -q '^ *allow_unverified_ssl *= *true' "$1/e2e_override.tf"; } ||
    die "$1: the generated provider has no vsphere_server and allow_unverified_ssl = false"
}

# drill: with only the backend redirected, the provider still addresses the stack's vCenter host and must die at the proxy
vc=$(val "$first/_terramate_generated_provider.tf" vsphere_server)
ovr_backend "$first"
step "${first#stacks/} init with the backend on loopback" - at "$first" tofu init
step "tripwire drill: no provider override dies at the proxy" "proxyconnect" at "$first" tofu plan -no-color
grep -qF "$vc" "$tmp/out" || die "the drill did not reach for $vc"

# drill: with the server redirected too, the generated allow_unverified_ssl = false still beats VSPHERE_ALLOW_UNVERIFIED_SSL=true in the
# environment (an argument in code wins over the variable), so the plan must fail on vcsim's self-signed certificate
printf 'provider "vsphere" {\n  vsphere_server = "127.0.0.1:%s"\n}\n' "$simport" >>"$first/e2e_override.tf"
VSPHERE_ALLOW_UNVERIFIED_SSL=true step "TLS drill: the generated provider refuses vcsim's certificate even with VSPHERE_ALLOW_UNVERIFIED_SSL=true" "x509:" at "$first" tofu plan -no-color
grep -qF "127.0.0.1:$simport" "$tmp/out" || die "the drill did not reach vcsim"

# the full overrides of every stack; the first one replaces the file the drill wrote
for s in $all; do
  ovr_backend "$s"
  ovr_provider "$s"
done

lock() { # a held lock refuses a second operation (409); tofu console takes it before it reads and holds it until its stdin closes
  local s=$1 h=$tmp/hold-$e pid
  mkfifo "$h"
  (cd "$s" && exec tofu console <"$h" >"$h.out" 2>&1) &
  pid=$!
  exec 3>"$h"
  echo '6 * 7' >&3
  for _ in $(seq 40); do grep -q '^42' "$h.out" && break; sleep 0.5; done
  grep -q '^42' "$h.out" || { cat "$h.out" >&2; die "tofu console did not start"; }
  step "${s#stacks/} a second operation is refused while the lock is held" "HTTP remote state already locked" at "$s" tofu plan -no-color -lock-timeout=0s
  exec 3>&-
  wait "$pid" || true
  step "${s#stacks/} the lock is released" - at "$s" tofu plan -lock-timeout=0s
}

envs=$(cut -d/ -f2 <<<"$all" | sort -u)
for e in $envs; do
  stacks=$(grep "^stacks/$e/" <<<"$all")
  lead=${stacks%%$'\n'*}
  echo "== environment $e ($(val "$lead/_terramate_generated_provider.tf" vsphere_server))"
  step "$e init" - tm -- tofu init
  step "$e plan" - tm -- tofu plan -out=tfplan
  step "$e apply of the saved plans" - tm -- tofu apply tfplan
  for s in $stacks; do step "${s#stacks/} state exists in GitLab under its generated name" +lineage state "$(val "$s/e2e_override.tf" address)"; done
  step "$e second plan is clean" "+No changes" tm -- tofu plan -detailed-exitcode -no-color # exit 2 (changes) fails terramate run
  lock "$lead"
  TF_HTTP_USERNAME=outsider TF_HTTP_PASSWORD=$outsider step "$e a token without membership is refused at the lock" "Unexpected HTTP response code 404" at "$lead" tofu plan -no-color
  guarded=
  for s in $stacks; do [ ! -f "$s/_terramate_generated_destroy_guard.tf" ] || guarded=1; done
  if [ -n "$guarded" ]; then # protect_destroy is set for this environment
    step "$e destroy is blocked by the guard" "Resource instance terraform_data.destroy_guard has prevent_destroy" tm --reverse -- tofu plan -destroy -no-color -out=tfplan
  else
    step "$e destroy plan" - tm --reverse -- tofu plan -destroy -out=tfplan
    step "$e destroy apply of the saved plan" - tm --reverse -- tofu apply tfplan
  fi
done
echo "e2e: all checks passed in ${SECONDS}s; vcsim and GitLab removed on exit, your vCenter and GitLab never contacted"
