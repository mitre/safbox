#!/usr/bin/env bash
# Render the kickstart template with placeholder values and validate it
# against the RHEL 10 kickstart grammar with pykickstart.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TPL="$ROOT/packer/answerfiles/el10/ks.cfg.pkrtpl.hcl"

test -f "$TPL" || { echo "FAIL: $TPL missing" >&2; exit 1; }
command -v ksvalidator >/dev/null || { echo "FAIL: ksvalidator not installed (pipx install pykickstart)" >&2; exit 1; }

tmp=$(mktemp)
tmp_nossh=$(mktemp)
trap 'rm -f "$tmp" "$tmp_nossh"' EXIT
# [$] is a literal dollar in sed; it keeps these patterns from reading like
# unexpanded shell variables.
sed -e 's/[$]{build_user}/packer/g' \
    -e 's|[$]{ssh_public_key}|ssh-rsa AAAAB3NzaC1yc2EPlaceholderKeyForLintOnly lint|g' \
    -e 's/[$]{hostname}/safbox/g' \
    -e 's/[$]{environment_group}/minimal-environment/g' \
    -e 's/[$]{datasource_list}/NoCloud/g' \
    "$TPL" \
  | awk '
      # Emulate the templatefile directives: installer_ssh=true keeps the
      # guarded block; the directive lines themselves are dropped.
      /^%\{ *if installer_ssh/ { next }
      /^%\{ *endif/ { next }
      { print }' > "$tmp"
# Second rendering with installer_ssh=false: the guarded block is removed.
awk '/^%\{ *if installer_ssh/ { skip=1; next } /^%\{ *endif/ { skip=0; next } !skip { print }' "$TPL" \
  | sed -e 's/[$]{build_user}/packer/g' -e 's/[$]{hostname}/safbox/g' \
        -e 's/[$]{environment_group}/minimal-environment/g' -e 's/[$]{datasource_list}/NoCloud/g' \
        -e 's|[$]{ssh_public_key}|ssh-rsa AAAAB3NzaC1yc2EPlaceholderKeyForLintOnly lint|g' > "$tmp_nossh"

# Every template variable and directive must have been handled.
for f in "$tmp" "$tmp_nossh"; do
  if grep -nE '[$]\{|^%\{' "$f"; then
    echo "FAIL: unrendered template syntax above in $f" >&2; exit 1
  fi
done

ksvalidator -v RHEL10 "$tmp"
ksvalidator -v RHEL10 "$tmp_nossh"
grep -q '^sshpw ' "$tmp" || { echo "FAIL: installer_ssh=true rendering lacks the sshpw line" >&2; exit 1; }
! grep -q '^sshpw ' "$tmp_nossh" || { echo "FAIL: installer_ssh=false rendering still contains sshpw" >&2; exit 1; }
grep -Eq '^%post --erroronfail' "$tmp" || { echo "FAIL: %post must use --erroronfail" >&2; exit 1; }
# fips=1 must reach the installed system's bootloader, not just the installer.
grep -Eq '^bootloader .*--append=.*fips=1' "$tmp" || { echo "FAIL: bootloader --append missing fips=1" >&2; exit 1; }
# Build user must authenticate by key only.
grep -Eq '^sshkey --username=packer ' "$tmp" || { echo "FAIL: sshkey line for build user missing" >&2; exit 1; }
grep -Eq '^user --name=packer .*--lock' "$tmp" || { echo "FAIL: build user password not locked" >&2; exit 1; }
grep -Eq '^rootpw --lock' "$tmp" || { echo "FAIL: root password not locked" >&2; exit 1; }
# services --enabled runs before %post; units installed in %post cannot be named there.
if grep -E '^services ' "$tmp" | grep -Eq 'qemu-guest-agent|cloud-init'; then
  echo "FAIL: services line names a unit that %post installs (anaconda enables services before %post)" >&2; exit 1
fi
grep -Eq '^systemctl enable .*qemu-guest-agent' "$tmp" || { echo "FAIL: %post must enable qemu-guest-agent" >&2; exit 1; }
grep -Eq '^systemctl enable .*cloud-init' "$tmp" || { echo "FAIL: %post must enable cloud-init" >&2; exit 1; }
# Scope: the kickstart puts only FIPS on the kernel line; hardening owns the rest.
if grep -E '^bootloader ' "$tmp" | grep -Eq 'audit=|audit_backlog'; then
  echo "FAIL: bootloader line carries hardening arguments that belong to the hardening role" >&2; exit 1
fi
echo "PASS: kickstart renders and validates for RHEL10"
