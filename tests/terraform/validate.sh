#!/usr/bin/env bash
# Static check of the deployment modules (ADR-0001 §Decision: deployment is
# Terraform, one module per target under deploy/terraform/<target>/):
# formatting, provider init and validate with the committed example values,
# no credentials and no hypervisor needed. Also checks what keeps a module
# reproducible and its site values out of git:
#   - every provider is pinned to an exact version (as packer/build.pkr.hcl
#     pins its plugins) and Terraform to a minimum release,
#   - the dependency lock file, which records the provider's checksums for
#     the platforms the module is run from, is committed (not ignored), as
#     a downloaded artifact is pinned by version and checksum,
#   - example.tfvars is committed, and every other *.tfvars file, state
#     file and .terraform directory is ignored by git.
# TERRAFORM names the binary (default: terraform on PATH).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
TERRAFORM=${TERRAFORM:-terraform}
command -v "$TERRAFORM" >/dev/null || { echo "FAIL: terraform not installed (set TERRAFORM)" >&2; exit 1; }

modules=()
for dir in deploy/terraform/*/; do
  [[ -f "$dir/versions.tf" ]] && modules+=("${dir%/}")
done
[[ ${#modules[@]} -gt 0 ]] || { echo "FAIL: no module with a versions.tf under deploy/terraform/" >&2; exit 1; }

# The platforms the lock file must cover: the CI runner and the
# workstations the module is documented for.
LOCK_PLATFORMS=(linux_amd64 darwin_arm64 darwin_amd64)
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

"$TERRAFORM" fmt -check -recursive deploy/terraform || fail "terraform fmt -check: run terraform fmt -recursive deploy/terraform"

for module in "${modules[@]}"; do
  versions="$module/versions.tf"
  grep -qE '^\s*required_version\s*=\s*">= [0-9]+\.[0-9]+\.[0-9]+"' "$versions" \
    || fail "$versions: required_version must name the minimum Terraform release (>= x.y.z)"
  sources=$(grep -cE '^\s*source\s*=' "$versions" || true)
  exact=$(grep -cE '^\s*version\s*=\s*"= [0-9]+\.[0-9]+\.[0-9]+"' "$versions" || true)
  [[ "$sources" -gt 0 && "$sources" -eq "$exact" ]] \
    || fail "$versions: every required provider must be pinned to one exact version ($exact of $sources are)"

  lock="$module/.terraform.lock.hcl"
  if [[ ! -f "$lock" ]]; then
    fail "$lock missing: run terraform providers lock$(printf ' -platform=%s' "${LOCK_PLATFORMS[@]}") in $module"
  else
    git check-ignore -q "$lock" && fail "$lock is ignored by git; it must be committed"
    # terraform providers lock records one h1: hash per platform it was
    # asked for, plus the zh: hashes of every platform's release archive.
    h1=$(grep -cE '"h1:' "$lock" || true)
    [[ "$h1" -ge ${#LOCK_PLATFORMS[@]} ]] \
      || fail "$lock: $h1 h1: hashes; lock the providers for ${LOCK_PLATFORMS[*]}"
  fi

  example="$module/example.tfvars"
  [[ -f "$example" ]] || fail "$example missing"
  git check-ignore -q "$example" && fail "$example is ignored by git; it must be committed"
  for ignored in terraform.tfvars site.auto.tfvars terraform.tfstate terraform.tfstate.backup .terraform/x; do
    git check-ignore -q "$module/$ignored" || fail "$module/$ignored would not be ignored by git"
  done

  # init resolves the provider by the lock file; validate needs no
  # credentials or values.
  work=$(mktemp -d)
  if ! TF_DATA_DIR="$work" "$TERRAFORM" -chdir="$module" init -backend=false -input=false -lockfile=readonly >"$work/init.log" 2>&1; then
    cat "$work/init.log" >&2
    fail "$module: terraform init"
  elif ! TF_DATA_DIR="$work" "$TERRAFORM" -chdir="$module" validate -no-color; then
    fail "$module: terraform validate"
  fi
  rm -rf "$work"
done

if [[ "$fails" -gt 0 ]]; then
  echo "FAIL: $fails check(s) failed" >&2
  exit 1
fi
echo "PASS: deploy/terraform modules (${modules[*]}) are formatted, pinned, locked and valid; site values stay out of git"
