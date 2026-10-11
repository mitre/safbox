#!/usr/bin/env bash
# Static check of the Packer install layer: formatting, plugin init, and a
# full validate using the committed example variables (no credentials needed).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

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
echo "PASS: packer fmt/init/validate"
