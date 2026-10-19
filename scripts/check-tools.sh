#!/usr/bin/env bash
# Check that the workstation has the tools docs/guides/proxmox/build.md
# lists under Prerequisites, at usable versions, and say which by name.
# Reports every problem before exiting, so one run shows all that is missing.
#
#   scripts/check-tools.sh
#
# Called by tests/packer/validate.sh and scripts/build.sh. Version sources:
#   Packer        required_version in packer/build.pkr.hcl (minimum)
#   Ansible       the ansible pin in tests/requirements.txt (exact)
#   CINC Auditor  inspec_version in verify/profiles/*/inspec.yml (minimum)
#   SAF CLI       SAF_CLI_VERSION in .github/workflows/static.yml (warn only)
#   Node.js, npm  engines.node in site/package.json (minimum)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUIDE="docs/guides/proxmox/build.md#prerequisites"

# pipx installs land here; build.sh adds the same directory.
export PATH="$HOME/.local/bin:$PATH"

fail=0
problem() { echo "ERROR: $*" >&2; fail=1; }
warn() { echo "WARNING: $*" >&2; }

# First x.y.z in a tool's version output.
semver() { grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }
# True when $1 >= $2.
at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# Packer
packer_min=$(sed -nE 's/.*required_version *= *">= *([0-9.]+)".*/\1/p' "$ROOT/packer/build.pkr.hcl")
if ! command -v packer >/dev/null; then
  problem "Packer (packer) not found; install Packer $packer_min or newer, see $GUIDE"
else
  v=$(packer version 2>/dev/null | semver || true)
  if [ -z "$v" ] || ! at_least "$v" "$packer_min"; then
    problem "Packer ${v:-of unknown version} found at $(command -v packer); need $packer_min or newer, see $GUIDE"
  fi
fi

# Ansible: the community package at the exact pinned version. ansible-core
# alone, or an OS package, has no ansible-community command or the wrong
# version; a second install earlier in PATH splits the two commands apart.
ansible_pin=$(sed -nE 's/^ansible==([0-9.]+).*/\1/p' "$ROOT/tests/requirements.txt")
if ! command -v ansible-playbook >/dev/null; then
  problem "Ansible (ansible-playbook) not found; install the ansible package $ansible_pin: pipx install --include-deps ansible==$ansible_pin, see $GUIDE"
elif ! command -v ansible-community >/dev/null; then
  problem "Ansible: $(command -v ansible-playbook) is ansible-core without the ansible package; install ansible $ansible_pin: pipx install --include-deps ansible==$ansible_pin, see $GUIDE"
else
  v=$(ansible-community --version 2>/dev/null | semver || true)
  if [ "$v" != "$ansible_pin" ]; then
    problem "Ansible: the ansible package is ${v:-of unknown version} ($(command -v ansible-community)); need exactly $ansible_pin: pipx install --force --include-deps ansible==$ansible_pin, see $GUIDE"
  fi
  if [ "$(dirname "$(command -v ansible-playbook)")" != "$(dirname "$(command -v ansible-community)")" ]; then
    problem "Ansible: ansible-playbook ($(command -v ansible-playbook)) and ansible-community ($(command -v ansible-community)) come from different installs; remove the other one or reorder PATH, see $GUIDE"
  fi
fi

# CINC Auditor
cinc_min=$(sed -nE 's/^inspec_version: *">= *([0-9.]+)".*/\1/p' "$ROOT"/verify/profiles/*/inspec.yml | sort -V | tail -1)
if ! command -v cinc-auditor >/dev/null; then
  problem "CINC Auditor (cinc-auditor) not found; install it, see $GUIDE"
else
  v=$(cinc-auditor --version 2>/dev/null | semver || true)
  if [ -z "$v" ] || ! at_least "$v" "$cinc_min"; then
    problem "CINC Auditor ${v:-of unknown version} found at $(command -v cinc-auditor); need $cinc_min or newer, see $GUIDE"
  fi
fi

# SAF CLI: CI's version is the tested one; others are allowed with a warning.
saf_ci=$(sed -nE 's/^ *SAF_CLI_VERSION: *([0-9.]+).*/\1/p' "$ROOT/.github/workflows/static.yml")
if ! command -v saf >/dev/null; then
  problem "SAF CLI (saf) not found; install @mitre/saf $saf_ci (needs Node.js), see $GUIDE"
else
  v=$(saf --version 2>/dev/null | semver || true)
  [ "$v" = "$saf_ci" ] || warn "SAF CLI is ${v:-of unknown version}; the build is tested with $saf_ci"
fi

# Node.js and npm build the documentation site (site/package.json engines).
node_min=$(sed -nE 's/.*"node": *">= *([0-9.]+)".*/\1/p' "$ROOT/site/package.json")
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  problem "Node.js and npm not found; install Node.js $node_min or newer, see $GUIDE"
else
  v=$(node --version 2>/dev/null | semver || true)
  if [ -z "$v" ] || ! at_least "$v" "$node_min"; then
    problem "Node.js ${v:-of unknown version} found at $(command -v node); need $node_min or newer, see $GUIDE"
  fi
fi

# Plain command-line tools: any version.
for t in git "ssh:OpenSSH client (ssh)" "ssh-keygen:OpenSSH client (ssh-keygen)" curl jq flock; do
  command -v "${t%%:*}" >/dev/null || problem "${t#*:} not found; see $GUIDE"
done

# The release gate's client checks (verify/profiles/safbox-client) probe the
# box's TLS with openssl s_client, which must be OpenSSL 3, not LibreSSL.
if ! command -v openssl >/dev/null; then
  problem "OpenSSL (openssl) not found; see $GUIDE"
elif ! openssl version | grep -q '^OpenSSL 3'; then
  problem "openssl at $(command -v openssl) is $(openssl version); put OpenSSL 3 first on PATH, see $GUIDE"
fi
# Its port probes (InSpec's host resource) use netcat.
if ! command -v nc >/dev/null && ! command -v ncat >/dev/null; then
  problem "netcat (nc or ncat) not found; the release gate's client checks probe the box's ports with it, see $GUIDE"
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: workstation prerequisites; fix the above and rerun" >&2
  exit 1
fi
echo "PASS: workstation prerequisites"
