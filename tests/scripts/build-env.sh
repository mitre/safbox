#!/usr/bin/env bash
# scripts/build.sh reads the Proxmox credentials only from a file only its
# owner can read (ADR-0001 Quality Standards: no secrets in the repository;
# the token file is 0600). The mode check must work with GNU stat (Linux)
# and BSD stat (macOS): GNU stat accepts BSD's -f as "filesystem status" and
# prints a report before failing, so trying the BSD form first broke the
# check on Linux (a correct 0600 file was refused). Each case stops before
# build.sh logs, generates keys or runs Packer.
#
#   tests/scripts/build-env.sh [path to build.sh]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:-$ROOT/scripts/build.sh}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
# What build.sh writes once it gets past the credentials: none of it may
# change here.
# A fresh checkout has none of these (.build/ and last.log are ignored), so
# each part prints a placeholder instead of failing under set -e.
state() {
  readlink "$ROOT/last.log" 2>/dev/null || echo "no last.log"
  readlink "$ROOT/.build/runs/latest" 2>/dev/null || echo "no latest run"
  if [ -d "$ROOT/.build/runs" ]; then find "$ROOT/.build/runs" -mindepth 1 -maxdepth 1 | wc -l; else echo "no runs"; fi
}
before=$(state)
fail() { echo "FAIL: $*" >&2; failures=1; }

# run <env file>: build.sh with no credentials in the environment.
# SAFBOX_DEV=1 skips the installer_ssh guard, so a local vars file cannot
# change the outcome.
run() {
  local rc=0
  env -u PROXMOX_URL -u PROXMOX_USERNAME -u PROXMOX_TOKEN SAFBOX_DEV=1 SAFBOX_PROXMOX_ENV="$1" \
    "$BUILD" >"$tmp/out" 2>"$tmp/err" || rc=$?
  echo "$rc"
}

# A file others can read is refused, naming the file and its mode.
: > "$tmp/open.env"; chmod 644 "$tmp/open.env"
rc=$(run "$tmp/open.env")
if [ "$rc" -eq 1 ] && [ "$(cat "$tmp/err")" = "refusing $tmp/open.env: mode 644, must be 600" ]; then
  echo "ok: a 0644 credentials file is refused"
else
  fail "0644: exit $rc, stderr: $(cat "$tmp/err")"
fi

# A 0600 file passes the check: build.sh goes on to the credentials, which
# this empty file does not provide.
: > "$tmp/private.env"; chmod 600 "$tmp/private.env"
rc=$(run "$tmp/private.env")
if [ "$rc" -ne 0 ] && grep -q "PROXMOX_URL: set PROXMOX_URL or provide $tmp/private.env" "$tmp/err" \
  && ! grep -q '^refusing' "$tmp/err"; then
  echo "ok: a 0600 credentials file passes the mode check"
else
  fail "0600: exit $rc, stderr: $(cat "$tmp/err")"
fi

[ "$(state)" = "$before" ] || fail "build.sh logged, generated keys or repointed last.log before the credentials check"

[ "$failures" -eq 0 ] || exit 1
echo "PASS: build.sh accepts only an owner-only credentials file"
