#!/usr/bin/env bash
# The repository's gitleaks rules catch Proxmox API token secrets, which the
# default rules miss (a bare UUID has no recognisable prefix), and leave the
# repository's documented placeholders alone. Fake tokens are generated at
# run time so none is ever committed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG="$ROOT/.gitleaks.toml"
command -v gitleaks >/dev/null || { echo "FAIL: gitleaks not installed" >&2; exit 1; }
test -f "$CONFIG" || { echo "FAIL: $CONFIG missing" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A random UUID-shaped value, as Proxmox issues token secrets.
uuid=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' \
  | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/')

leaks=0
scan() { gitleaks dir --no-banner --config "$CONFIG" --exit-code 1 "$1" >/dev/null 2>&1; }
# Rule that fired, so a detection by the entropy-dependent generic rule does
# not count as the Proxmox rules working.
rule_of() { gitleaks dir --no-banner --config "$CONFIG" --report-format json --report-path - "$1" 2>/dev/null \
  | sed -n 's/.*"RuleID": *"\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' ' || true; }
expect_leak() {
  printf '%s\n' "$2" > "$tmp/$1"
  local rules; rules=$(rule_of "$tmp/$1")
  if [[ "$rules" == *proxmox-* ]]; then echo "ok: detected $1 ($rules)"
  else echo "FAIL: not detected by a Proxmox rule: $1 (${rules:-no rule})" >&2; leaks=1; fi
}
expect_clean() {
  printf '%s\n' "$2" > "$tmp/$1"
  if scan "$tmp/$1"; then echo "ok: not flagged $1"; else echo "FAIL: false positive: $1" >&2; leaks=1; fi
}

expect_leak env-bare "PROXMOX_TOKEN=$uuid"
expect_leak env-export "export PROXMOX_TOKEN=\"$uuid\""
expect_leak env-quoted-single "PROXMOX_TOKEN='$uuid'"
expect_leak packer-var "proxmox_token = \"$uuid\""
expect_leak curl-header "header = \"Authorization: PVEAPIToken=builder@pve!packer=$uuid\""
expect_leak http-header "Authorization: PVEAPIToken=root@pam!ci=$uuid"

# Placeholders the repository documents or uses for validation (literal
# text; the dollar signs are escaped, not expanded).
expect_clean zero-placeholder "PROXMOX_TOKEN=\"\${PROXMOX_TOKEN:-00000000-0000-0000-0000-000000000000}\""
expect_clean zero-literal 'PROXMOX_TOKEN=00000000-0000-0000-0000-000000000000'
expect_clean doc-placeholder 'PROXMOX_TOKEN=<token secret>'
expect_clean shell-reference "printf \"PVEAPIToken=%s=%s\" \"\$PROXMOX_USERNAME\" \"\$PROXMOX_TOKEN\""
expect_clean required-var ": \"\${PROXMOX_TOKEN:?set PROXMOX_TOKEN}\""

[ "$leaks" -eq 0 ] || exit 1
echo "PASS: gitleaks rules catch Proxmox token secrets and pass the placeholders"
