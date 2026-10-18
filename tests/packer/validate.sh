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
# The display adapter: qxl (the default; SPICE) or std (standard VGA, noVNC
# only). Anything else Proxmox accepts is out of scope and rejected.
reject "vga virtio" "vga must be qxl (SPICE, the default) or std" -var vga=virtio
reject "vga serial0" "vga must be qxl (SPICE, the default) or std" -var vga=serial0
reject "vga QXL in capitals" "vga must be qxl (SPICE, the default) or std" -var vga=QXL
reject "an empty vga" "vga must be qxl (SPICE, the default) or std" -var vga=

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
accept "vga std (standard VGA)" -var vga=std
accept "vga qxl (SPICE, the default)" -var vga=qxl
# galaxy_dir (scripts/build.sh passes one per run, so concurrent builds never
# install into the same place) reaches every path Ansible reads: the galaxy
# install paths and the ANSIBLE_* search paths, with ansible.cfg's paths
# when it is null. packer inspect prints the evaluated locals.
inspect_local() { # name -var...
  local name=$1 out; shift
  out=$(packer inspect -var-file=packer/example.pkrvars.hcl \
    -var "ssh_public_key=$(cat "$tmp/key.pub")" -var "ssh_private_key_file=$tmp/key" "$@" packer/ 2>&1) \
    || { echo "FAIL: packer inspect $*: $out" >&2; exit 1; }
  sed -n "s/^local\.$name: //p" <<<"$out"
}
want_local() { # description name want -var...
  local desc=$1 name=$2 want=$3 got; shift 3
  got=$(inspect_local "$name" "$@")
  if [ "$got" = "$want" ]; then echo "ok: $desc"
  else echo "FAIL: $desc: local.$name is $got, want $want" >&2; exit 1; fi
}
want_env() { # description entry -var...
  local desc=$1 entry=$2; shift 2
  if inspect_local ansible_env "$@" | grep -qF "\\\"$entry\\\""; then echo "ok: $desc"
  else echo "FAIL: $desc: local.ansible_env lacks $entry" >&2; exit 1; fi
}
A="$ROOT/ansible"
want_local "galaxy_dir sets the roles install path" galaxy_roles '"/run/galaxy/roles"' -var galaxy_dir=/run/galaxy
want_local "galaxy_dir sets the collections install path" galaxy_collections '"/run/galaxy/collections"' -var galaxy_dir=/run/galaxy
want_env "galaxy_dir leads ANSIBLE_ROLES_PATH" "ANSIBLE_ROLES_PATH=/run/galaxy/roles:$A/roles" -var galaxy_dir=/run/galaxy
want_env "galaxy_dir leads ANSIBLE_COLLECTIONS_PATH" \
  "ANSIBLE_COLLECTIONS_PATH=/run/galaxy/collections:~/.ansible/collections:/usr/share/ansible/collections" -var galaxy_dir=/run/galaxy
want_local "no galaxy_dir installs roles where ansible.cfg says" galaxy_roles "\"$A/galaxy_roles\""
want_local "no galaxy_dir installs collections where ansible.cfg says" galaxy_collections "\"$A/collections\""
# Provisioner arguments are not printed by inspect: the appliance-layer
# provisioner (the one with galaxy_file) must install into those paths.
galaxy_block=$(awk '/provisioner "ansible"/ {b=""; inb=1} inb {b = b $0 "\n"} inb && /^  }/ {if (b ~ /galaxy_file/) printf "%s", b; inb=0}' packer/build.pkr.hcl)
for want in 'roles_path *= local.galaxy_roles' 'collections_path *= local.galaxy_collections' 'ansible_env_vars *= local.ansible_env'; do
  if grep -qE "^ *$want\$" <<<"$galaxy_block"; then echo "ok: the galaxy provisioner sets ${want%% *}"
  else echo "FAIL: the ansible provisioner with galaxy_file does not set '$want'" >&2; exit 1; fi
done
echo "PASS: packer fmt/init/validate"
