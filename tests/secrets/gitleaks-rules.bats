#!/usr/bin/env bats
# The repository's gitleaks rules (.gitleaks.toml) catch Proxmox API token
# secrets, which the default rules miss (a bare UUID has no recognisable
# prefix), and leave the repository's documented placeholders alone. Fake
# tokens are generated at run time so none is ever committed. Needs
# gitleaks on PATH.
#
#   tests/bats/run.sh tests/secrets/gitleaks-rules.bats
bats_require_minimum_version 1.14.0
load ../bats/common

setup_file() {
  command -v gitleaks >/dev/null || fail "gitleaks not installed"
  assert_file_exists "$ROOT/.gitleaks.toml"
}

setup() {
  CONFIG="$ROOT/.gitleaks.toml"
  # A random UUID-shaped value, as Proxmox issues token secrets.
  UUID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' \
    | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/')
}

# file_with <line>: a file holding that line, alone in its own directory.
file_with() {
  local d="$BATS_TEST_TMPDIR/scan"
  mkdir -p "$d"
  printf '%s\n' "$1" > "$d/file"
  echo "$d/file"
}

# assert_proxmox_rule <line>: a Proxmox rule fires on the line. The rule
# that fired is checked, so a detection by the entropy-dependent generic
# rule does not count as the Proxmox rules working.
assert_proxmox_rule() {
  local f; f=$(file_with "$1")
  run gitleaks dir --no-banner --config "$CONFIG" --report-format json --report-path - "$f"
  assert_output --regexp '"RuleID": *"proxmox-'
}

# refute_leak <line>: gitleaks finds nothing in the line.
refute_leak() {
  local f; f=$(file_with "$1")
  run gitleaks dir --no-banner --config "$CONFIG" --exit-code 1 "$f"
  assert_success
}

@test "detected: a bare PROXMOX_TOKEN assignment" {
  assert_proxmox_rule "PROXMOX_TOKEN=$UUID"
}

@test "detected: an exported, double-quoted PROXMOX_TOKEN" {
  assert_proxmox_rule "export PROXMOX_TOKEN=\"$UUID\""
}

@test "detected: a single-quoted PROXMOX_TOKEN" {
  assert_proxmox_rule "PROXMOX_TOKEN='$UUID'"
}

@test "detected: a Packer proxmox_token variable" {
  assert_proxmox_rule "proxmox_token = \"$UUID\""
}

@test "detected: a curl config Authorization header" {
  assert_proxmox_rule "header = \"Authorization: PVEAPIToken=builder@pve!packer=$UUID\""
}

@test "detected: an HTTP Authorization header" {
  assert_proxmox_rule "Authorization: PVEAPIToken=root@pam!ci=$UUID"
}

# Placeholders the repository documents or uses for validation (literal
# text; the dollar signs are escaped, not expanded).
@test "not flagged: the all-zero default in a parameter expansion" {
  refute_leak "PROXMOX_TOKEN=\"\${PROXMOX_TOKEN:-00000000-0000-0000-0000-000000000000}\""
}

@test "not flagged: the all-zero literal" {
  refute_leak 'PROXMOX_TOKEN=00000000-0000-0000-0000-000000000000'
}

@test "not flagged: the documentation placeholder" {
  refute_leak 'PROXMOX_TOKEN=<token secret>'
}

@test "not flagged: a shell reference to the variables" {
  refute_leak "printf \"PVEAPIToken=%s=%s\" \"\$PROXMOX_USERNAME\" \"\$PROXMOX_TOKEN\""
}

@test "not flagged: a required-variable check" {
  refute_leak ": \"\${PROXMOX_TOKEN:?set PROXMOX_TOKEN}\""
}
