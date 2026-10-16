#!/usr/bin/env bash
# Static check of the Packer install layer: formatting, plugin init, and a
# full validate using the committed example variables (no credentials needed).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# Every tool the build needs, not only Packer: this is the first command
# docs/guides/proxmox/build.md step 8 runs.
scripts/check-tools.sh

test -d packer || { echo "FAIL: packer/ directory missing" >&2; exit 1; }
test -f packer/example.pkrvars.hcl || { echo "FAIL: packer/example.pkrvars.hcl missing" >&2; exit 1; }

# The plugin insists on non-empty credentials even for validate, which never
# connects. Supply inert placeholders when the environment has none.
export PROXMOX_URL="${PROXMOX_URL:-https://proxmox.example.invalid:8006/api2/json}"
export PROXMOX_USERNAME="${PROXMOX_USERNAME:-validate@pve!placeholder}"
export PROXMOX_TOKEN="${PROXMOX_TOKEN:-00000000-0000-0000-0000-000000000000}"

# The communicator reads the private key even during validate; use a
# throwaway pair that never leaves the temp dir.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t rsa -b 2048 -N '' -C validate-only -f "$tmp/key"

packer fmt -check -recursive packer/
packer init packer/
packer validate \
  -var-file=packer/example.pkrvars.hcl \
  -var "ssh_public_key=$(cat "$tmp/key.pub")" \
  -var "ssh_private_key_file=$tmp/key" \
  packer/

# Two operator mistakes that otherwise surface far from their cause
# (docs/guides/proxmox/build.md steps 1 and 2): the node's IP address as its
# name fails the first API call with "596 ... certificate verify failed",
# and a live ISO boots to a desktop that never runs the kickstart, so the
# build waits for SSH until install_timeout. Both must fail here, by name.
reject() { # description message-fragment -var...
  local desc=$1 want=$2 out rc=0; shift 2
  out=$(packer validate -var-file=packer/example.pkrvars.hcl \
    -var "ssh_public_key=$(cat "$tmp/key.pub")" -var "ssh_private_key_file=$tmp/key" "$@" packer/ 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$want" <<<"$out"; then echo "ok: $desc is rejected"
  else echo "FAIL: $desc: packer validate exit $rc, expected the message '$want'" >&2; exit 1; fi
}
reject "an IP address as proxmox_node" "proxmox_node must be the node's name" -var proxmox_node=192.168.5.6
reject "an IPv6 address as proxmox_node" "proxmox_node must be the node's name" -var proxmox_node=fd00::6
reject "a Rocky Workstation-Lite live ISO" "iso_file must be an installer ISO" -var iso_file=local:iso/Rocky-10-Workstation-Lite-x86_64-latest.iso
reject "an AlmaLinux Live-GNOME ISO" "iso_file must be an installer ISO" -var iso_file=local:iso/AlmaLinux-10-latest-x86_64-Live-GNOME.iso
reject "a KDE live ISO" "iso_file must be an installer ISO" -var iso_file=local:iso/Rocky-10.2-KDE-x86_64-latest.iso

# Legitimate values the checks must not mistake for those: node names, and
# installer ISOs whose storage or file name merely contains a live-image word.
accept() { # description -var...
  local desc=$1 out rc=0; shift
  out=$(packer validate -var-file=packer/example.pkrvars.hcl \
    -var "ssh_public_key=$(cat "$tmp/key.pub")" -var "ssh_private_key_file=$tmp/key" "$@" packer/ 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok: $desc is accepted"
  else echo "FAIL: $desc: packer validate exit $rc: $out" >&2; exit 1; fi
}
accept "node name pve-01" -var proxmox_node=pve-01
accept "an all-digit node name" -var proxmox_node=10
accept "storage 'olive' with a minimal ISO" -var iso_file=olive:iso/Rocky-10.2-x86_64-minimal.iso
accept "storage 'nas-automated' with a DVD ISO" -var iso_file=nas-automated:iso/Rocky-10.2-x86_64-dvd1.iso
accept "a file name containing 'ultimate'" -var iso_file=local:iso/rocky-ultimate-minimal.iso
accept "an AlmaLinux x86_64_v2 DVD" -var iso_file=local:iso/AlmaLinux-10.1-x86_64_v2-dvd.iso
accept "a storage named 'live-nas'" -var iso_file=live-nas:iso/Rocky-10.2-x86_64-minimal.iso
echo "PASS: packer fmt/init/validate"
