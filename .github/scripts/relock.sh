#!/usr/bin/env bash
# Re-lock the providers of every template folder inside their constraints (the scratch-copy flow of README "Add a provider": a template
# folder refuses `make relock`), copy the lock files back, and rewrite the doc lines that quote the locked version.
# Leaves the changes in the work tree; run from anywhere inside the repository after `make setup`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# folder -> registry address of the provider whose locked version the folder README quotes (a case, not `declare -A`: macOS bash is 3.2)
provider() { case "$1" in aws) echo hashicorp/aws ;; vsphere) echo vmware/vsphere ;; gcp) echo hashicorp/google ;; azure) echo hashicorp/azurerm ;; esac; }

for p in aws vsphere gcp azure; do
  d=$(mktemp -d)
  cp -R "$p"/. "$d"
  (cd "$d" && git init -q -b main && make generate && make relock)
  (cd "$d" && find . -name .terraform.lock.hcl ! -path '*/.terraform/*' -print0 | tar --null -T - -cf -) | tar -xf - -C "$p"
  rm -rf "$d"

  # every lock file that names the provider must agree on one version
  v=$(find "$p" -name .terraform.lock.hcl ! -path '*/.terraform/*' -print0 | xargs -0 awk -v s="registry.opentofu.org/$(provider "$p")" '
    index($0, "provider \"" s "\"") { f = 1 } f && $1 == "version" { gsub(/"/, "", $3); print $3; f = 0 }' | sort -u)
  [ "$(grep -c . <<<"$v")" = 1 ] || { echo "$p: locks disagree on $(provider "$p"): $v" >&2; exit 1; }
  echo "$p: $(provider "$p") locked at $v"

  edit() { # file, replacement, pattern (extended regex), expected number of matching lines
    [ "$(grep -cE "$3" "$1")" = "$4" ] || { echo "$1: expected $4 line(s) matching $3" >&2; exit 1; }
    sed -E "s/$3/$2/" "$1" > "$1.new" && mv "$1.new" "$1"
  }
  edit "$p/README.md" "keep the locked $v (verified)" 'keep the locked [0-9][0-9.]* \(verified\)' 1
  if [ "$p" = vsphere ]; then edit "$p/README.md" "is locked at $v," 'is locked at [0-9][0-9.]*,' 1; fi
done
