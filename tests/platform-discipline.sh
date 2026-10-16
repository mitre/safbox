#!/usr/bin/env bash
# Platform discipline (ADR-0001 Quality Standards): the appliance layer and
# everything outside the install layer must not name a hypervisor or cloud.
#
# Scope. The ADR names packer/source-*.pkr.hcl and packer/answerfiles/ as the only
# places a platform may appear. The rest of the install layer (variables,
# the shared build block, its tests, the runner scripts and theirs) necessarily
# names the builder plugin, and the documentation describes the targets, so
# those paths are listed as the install-layer allowance below. Everything
# else in the tree, in particular ansible/ and verify/, is scanned.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PATTERN='(^|[^[:alnum:]_])(proxmox|vsphere|vmware|aws|azure|gcp|hyper-v|virtualbox|qemu|kvm)([^[:alnum:]_]|$)'

# Install layer and documentation, where naming the target is the point.
# The secret-scanning rules and their test name the install layer's own
# credential (the hypervisor API token) so it can never be committed.
ALLOW_DIRS=(packer tests/packer tests/kickstart tests/secrets scripts tests/scripts docs)
ALLOW_FILES=(README.md NOTICE tests/platform-discipline.sh .gitleaks.toml)
# Tool and state directories that are not project content.
SKIP_DIRS=(.git .beads .build .dolt .claude .codex .agents packer_cache collections)

find_args=()
for d in "${SKIP_DIRS[@]}" "${ALLOW_DIRS[@]}"; do
  find_args+=(-path "./$d" -prune -o)
done
for f in "${ALLOW_FILES[@]}"; do
  find_args+=(-path "./$f" -prune -o)
done

# qemu-guest-agent is the distribution's package and unit name for the guest
# agent. That exact token is blanked before matching so a bare hypervisor
# name on the same line still hits. *.local.md files are git-ignored notes.
# Git-ignored files are site-local by definition (local vars, notes) and may
# name the site's platform; only project content is checked.
hits=$(find . "${find_args[@]}" -type f -name '*.local.md' -prune -o -type f -print0 \
  | git check-ignore -z --stdin --non-matching --verbose \
  | tr '\0' '\n' | paste - - - - | awk -F'\t' '$1 == "" {print $4}' | tr '\n' '\0' \
  | xargs -0 grep -nIiE "$PATTERN" --with-filename 2>/dev/null \
  | sed -E 's/[Qq][Ee][Mm][Uu]-[Gg]uest-[Aa]gent//g' \
  | grep -iE "$PATTERN" || true)

if [[ -n "$hits" ]]; then
  echo "FAIL: hypervisor or cloud names outside the install layer:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "PASS: no hypervisor or cloud names outside the install layer and docs"
