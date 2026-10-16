#!/usr/bin/env bash
# scripts/check-tools.sh names each missing or wrong workstation tool the way
# docs/guides/proxmox/build.md does, and fails the run (ADR-0001 Quality
# Standards: two-audience docs; the build guide's Prerequisites). Each case
# runs the check against stub tools that print a real tool's version output,
# on a PATH holding only the stubs and the system utilities the check uses.
#
#   tests/scripts/check-tools.sh [path to check-tools.sh]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHECK=${1:-$ROOT/scripts/check-tools.sh}
GUIDE="docs/guides/proxmox/build.md#prerequisites"

# The versions the check reads from the repository, so the cases follow a pin
# change instead of hard-coding it.
ANSIBLE_PIN=$(sed -nE 's/^ansible==([0-9.]+).*/\1/p' "$ROOT/tests/requirements.txt")
PACKER_MIN=$(sed -nE 's/.*required_version *= *">= *([0-9.]+)".*/\1/p' "$ROOT/packer/build.pkr.hcl")
SAF_CI=$(sed -nE 's/^ *SAF_CLI_VERSION: *([0-9.]+).*/\1/p' "$ROOT/.github/workflows/static.yml")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SYS="$tmp/sys"
mkdir -p "$SYS"
for t in bash sh sed grep head tail sort dirname; do
  ln -s "$(type -P "$t")" "$SYS/$t"
done

failures=0
stub() { printf '#!/bin/sh\necho "%s"\n' "$2" > "$1"; chmod +x "$1"; }

# A full, correct workstation in $1.
good_tools() {
  mkdir -p "$1"
  stub "$1/packer" "Packer v1.16.1"
  stub "$1/ansible-playbook" "ansible-playbook [core 2.21.0]"
  stub "$1/ansible-community" "Ansible community version $ANSIBLE_PIN"
  stub "$1/cinc-auditor" "7.2.1"
  stub "$1/saf" "@mitre/saf/$SAF_CI linux-x64 node-v22.20.0"
  for t in git ssh ssh-keygen curl jq; do stub "$1/$t" "$t"; done
}

# run <case> <expected exit> <expected stderr> <PATH dirs...>
run() {
  local name=$1 want_rc=$2 want_err=$3; shift 3
  local path; path=$(IFS=:; echo "$*"):$SYS
  local rc=0
  HOME="$tmp/home" PATH="$path" "$SYS/bash" "$CHECK" >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: $name: exit $rc, want $want_rc; stderr:" >&2; sed 's/^/  /' "$tmp/err" >&2; failures=1; return
  fi
  if [ "$(cat "$tmp/err")" != "$want_err" ]; then
    echo "FAIL: $name: stderr differs" >&2
    diff <(printf '%s\n' "$want_err") "$tmp/err" | sed 's/^/  /' >&2 || true
    failures=1; return
  fi
  echo "ok: $name"
}

# (a) Everything present at the pinned versions.
good_tools "$tmp/a"
run "all tools present" 0 "" "$tmp/a"
grep -qx 'PASS: workstation prerequisites' "$tmp/out" || { echo "FAIL: all tools present: no PASS line" >&2; failures=1; }

# (b) ansible-core alone: no ansible-community command.
good_tools "$tmp/b"; rm "$tmp/b/ansible-community"
run "ansible-core without the ansible package" 1 \
"ERROR: Ansible: $tmp/b/ansible-playbook is ansible-core without the ansible package; install ansible $ANSIBLE_PIN: pipx install --include-deps ansible==$ANSIBLE_PIN, see $GUIDE
FAIL: workstation prerequisites; fix the above and rerun" "$tmp/b"

# (c) The ansible package at another version.
good_tools "$tmp/c"; stub "$tmp/c/ansible-community" "Ansible community version 12.0.0"
run "ansible package at the wrong version" 1 \
"ERROR: Ansible: the ansible package is 12.0.0 ($tmp/c/ansible-community); need exactly $ANSIBLE_PIN: pipx install --force --include-deps ansible==$ANSIBLE_PIN, see $GUIDE
FAIL: workstation prerequisites; fix the above and rerun" "$tmp/c"

# (d) A second install earlier in PATH supplies ansible-community only.
good_tools "$tmp/d"; mkdir -p "$tmp/d-other"
stub "$tmp/d-other/ansible-community" "Ansible community version $ANSIBLE_PIN"
run "ansible commands from different installs" 1 \
"ERROR: Ansible: ansible-playbook ($tmp/d/ansible-playbook) and ansible-community ($tmp/d-other/ansible-community) come from different installs; remove the other one or reorder PATH, see $GUIDE
FAIL: workstation prerequisites; fix the above and rerun" "$tmp/d-other" "$tmp/d"

# (e) No SAF CLI: named as the SAF CLI, not by its bare command.
good_tools "$tmp/e"; rm "$tmp/e/saf"
run "SAF CLI missing" 1 \
"ERROR: SAF CLI (saf) not found; install @mitre/saf $SAF_CI (needs Node.js), see $GUIDE
FAIL: workstation prerequisites; fix the above and rerun" "$tmp/e"

# (f) Packer older than the template's required_version.
good_tools "$tmp/f"; stub "$tmp/f/packer" "Packer v1.11.2"
run "Packer below required_version" 1 \
"ERROR: Packer 1.11.2 found at $tmp/f/packer; need $PACKER_MIN or newer, see $GUIDE
FAIL: workstation prerequisites; fix the above and rerun" "$tmp/f"

[ "$failures" -eq 0 ] || exit 1
echo "PASS: check-tools names each missing or wrong workstation tool"
