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
# One image for every hypervisor: both guest agents, the VMware one with
# guest operations and customization scripts off.
grep -Eq '^dnf -y install .*open-vm-tools' "$tmp" || { echo "FAIL: %post must install open-vm-tools" >&2; exit 1; }
grep -Eq '^systemctl enable .*vmtoolsd' "$tmp" || { echo "FAIL: %post must enable vmtoolsd" >&2; exit 1; }
if grep -E '^services ' "$tmp" | grep -Eq 'vmtoolsd'; then
  echo "FAIL: services line names vmtoolsd, which %post installs" >&2; exit 1
fi
tools_conf=$(awk '/^cat > \/etc\/vmware-tools\/tools.conf <</ { on=1; next } on && /^EOC$/ { exit } on' "$tmp")
grep -A1 -Fx '[guestoperations]' <<<"$tools_conf" | grep -Eq '^disabled *= *true$' \
  || { echo "FAIL: %post must write tools.conf with [guestoperations] disabled = true" >&2; exit 1; }
grep -A1 -Fx '[deployPkg]' <<<"$tools_conf" | grep -Eq '^enable-custom-scripts *= *false$' \
  || { echo "FAIL: %post must write tools.conf with [deployPkg] enable-custom-scripts = false" >&2; exit 1; }
# The initramfs stays host-only: a generic one (dracut-config-generic)
# carries every GPU's firmware, and the desktop image's no longer leaves
# room in /boot for the kernels dnf keeps. A dracut drop-in adds the
# storage drivers of every supported hypervisor's disk controllers.
if grep -Eq '^dnf .*dracut-config-generic' "$tmp"; then
  echo "FAIL: %post must not install dracut-config-generic (the initramfs stays host-only)" >&2; exit 1
fi
dropin=/etc/dracut.conf.d/90-safbox-storage-drivers.conf
dracut_conf=$(awk -v f="$dropin" '$0 == "cat > " f " <<'"'"'EOC'"'"'" { on=1; next } on && /^EOC$/ { exit } on' "$tmp")
add_drivers=$(sed -nE 's/^add_drivers\+=" (.*) "$/\1/p' <<<"$dracut_conf")
for driver in ahci nvme virtio_blk virtio_scsi vmw_pvscsi; do
  grep -Eq "(^| )$driver( |$)" <<<"$add_drivers" \
    || { echo "FAIL: %post must write $dropin with add_drivers+=\" ... \" naming $driver" >&2; exit 1; }
done
grep -Eq "^chmod 0644 $dropin$" "$tmp" || { echo "FAIL: %post must make $dropin mode 0644" >&2; exit 1; }
# The initramfs anaconda made before %post lacks the added drivers; it is
# rebuilt after the drop-in is written.
awk -v f="$dropin" 'index($0, "cat > " f " <<") == 1 { inst=NR } /^dracut -f --regenerate-all/ && inst { ok=1 } END { exit !ok }' "$tmp" \
  || { echo "FAIL: %post must run dracut -f --regenerate-all after writing $dropin" >&2; exit 1; }
# Scope: the kickstart puts only FIPS on the kernel line; hardening owns the rest.
if grep -E '^bootloader ' "$tmp" | grep -Eq 'audit=|audit_backlog'; then
  echo "FAIL: bootloader line carries hardening arguments that belong to the template_hardening role" >&2; exit 1
fi
echo "PASS: kickstart renders and validates for RHEL10"
