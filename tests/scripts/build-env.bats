#!/usr/bin/env bats
# scripts/build.sh reads the Proxmox credentials (load_env, scripts/lib.sh)
# only from a file only its owner can read (the token file is 0600, and no
# secret is in the repository). The mode check must work with GNU stat
# (Linux) and BSD stat (macOS): GNU stat accepts BSD's -f as "filesystem
# status" and prints a report before failing, so trying the BSD form first
# broke the check on Linux (a correct 0600 file was refused). Each case
# stops before build.sh logs, generates keys or runs Packer.
#
#   tests/bats/run.sh tests/scripts/build-env.bats
#   BUILD_SH=/path/build.sh tests/bats/run.sh ...    another copy of build.sh
bats_require_minimum_version 1.14.0

setup() {
  load ../bats/common
  BUILD_SH=${BUILD_SH:-$ROOT/scripts/build.sh}
}

# What build.sh writes once it gets past the credentials: none of it may
# change here. A fresh checkout has none of these (.build/ and last.log are
# ignored), so each part prints a placeholder.
state() {
  readlink "$ROOT/last.log" 2>/dev/null || echo "no last.log"
  readlink "$ROOT/.build/runs/latest" 2>/dev/null || echo "no latest run"
  if [ -d "$ROOT/.build/runs" ]; then find "$ROOT/.build/runs" -mindepth 1 -maxdepth 1 | wc -l; else echo "no runs"; fi
}

# build_with <env file>: build.sh with no credentials in the environment.
# SAFBOX_DEV=1 skips the installer_ssh guard, so a local vars file cannot
# change the outcome.
build_with() {
  run --separate-stderr env -u PROXMOX_URL -u PROXMOX_USERNAME -u PROXMOX_TOKEN SAFBOX_DEV=1 \
    SAFBOX_PROXMOX_ENV="$1" "$BUILD_SH"
}

# env_file <mode>: an empty credentials file with that mode.
env_file() {
  local f="$BATS_TEST_TMPDIR/$1.env"
  : > "$f"; chmod "$1" "$f"
  echo "$f"
}

@test "a 0644 credentials file is refused, naming the file and its mode" {
  f=$(env_file 644)
  build_with "$f"
  assert_failure 1
  assert_stderr "refusing $f: mode 644, must be 600"
}

@test "a 0600 credentials file passes the mode check" {
  f=$(env_file 600)
  build_with "$f"
  # build.sh goes on to the credentials, which this empty file lacks.
  assert_failure
  assert_stderr --partial "PROXMOX_URL: set PROXMOX_URL or provide $f"
  refute_stderr_line --regexp "^refusing"
}

@test "build.sh logs, generates keys and repoints last.log only after the credentials check" {
  before=$(state)
  build_with "$(env_file 644)"
  build_with "$(env_file 600)"
  assert_equal "$(state)" "$before"
}
