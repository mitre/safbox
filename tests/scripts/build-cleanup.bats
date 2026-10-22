#!/usr/bin/env bats
# However a scripts/build.sh run ends (a token leak, a failing Packer, a
# galaxy install that cannot be removed, a signal to build.sh or to its
# whole process group), its cleanup deletes the run's key and reports what
# it could not do; SAFBOX_DEV=1 keeps the key. Each test runs build.sh in a
# scratch repository of its own with the stub packer (tests/scripts/stubs/).
#
#   tests/bats/run.sh tests/scripts/build-cleanup.bats
#   BUILD_SH=/path/build.sh tests/bats/run.sh ...    another copy of build.sh
bats_require_minimum_version 1.14.0
load ../bats/common
load helpers

setup() {
  scratch "$BATS_TEST_TMPDIR"
}

teardown() {
  scratch_teardown
}

# assert_cleaned <name>: the run's key pair and galaxy install are gone.
assert_cleaned() {
  local run; run=$(run_of "$1")
  assert_file_not_exists "$R/$run/build_key"
  assert_file_not_exists "$R/$run/build_key.pub"
  assert_not_exists "$R/$run/galaxy"
}

# The token-leak check reads that run's own debug log, and a failed check
# still removes the key.
@test "a token in the run's debug log fails the run with 2, names the log and deletes the key" {
  build leak STUB_LEAK=1
  assert_equal "$(rc_of leak)" 2
  assert_file_contains "$STUB/out.leak" "FATAL: API token found in $R/$(run_of leak)/packer-debug.log"
  assert_cleaned leak
}

# A failing packer build keeps its exit status, and the cleanup deletes the
# key even when the galaxy install cannot be removed (it only warns), with
# and without a token leak (which still exits 2). STUB_RO=1 leaves a
# directory in the galaxy install its owner cannot delete from.
@test "a failing Packer keeps its exit status and the run is cleaned up" {
  build packer-fails STUB_RC=7
  assert_equal "$(rc_of packer-fails)" 7
  assert_cleaned packer-fails
}

@test "a galaxy install that cannot be removed is reported, and the key still goes" {
  build galaxy-stuck STUB_RC=7 STUB_RO=1
  assert_equal "$(rc_of galaxy-stuck)" 7
  assert_file_not_exists "$R/$(run_of galaxy-stuck)/build_key"
  assert_file_not_exists "$R/$(run_of galaxy-stuck)/build_key.pub"
  assert_file_contains "$STUB/out.galaxy-stuck" "warning: could not remove $R/$(run_of galaxy-stuck)/galaxy"
}

@test "a stuck galaxy install and a token leak: exit 2, both reported, the key goes" {
  build galaxy-stuck-leak STUB_RC=7 STUB_RO=1 STUB_LEAK=1
  assert_equal "$(rc_of galaxy-stuck-leak)" 2
  assert_file_not_exists "$R/$(run_of galaxy-stuck-leak)/build_key"
  assert_file_not_exists "$R/$(run_of galaxy-stuck-leak)/build_key.pub"
  assert_file_contains "$STUB/out.galaxy-stuck-leak" "warning: could not remove $R/$(run_of galaxy-stuck-leak)/galaxy"
}

# A SIGTERM sent to build.sh alone (not its group) still deletes the key
# once Packer has stopped.
@test "a SIGTERM to build.sh alone exits 143 and deletes the key" {
  start term
  wait_for "$STUB/started.term"
  kill -TERM "$(cat "$STUB/pid.term")"
  release term
  assert_equal "$(rc_of term)" 143
  assert_file_not_exists "$R/$(run_of term)/build_key"
}

# A signal to the whole process group reaches build.sh, Packer and the tee
# that writes build.log. The run still ends through its cleanup: the key is
# deleted, the leak check still fails the run with 2 and says so in
# build.log, and Packer's cancellation output reaches build.log. HUP and
# INT take the same path as TERM (one trap each, only the exit status
# differs), and the tee is shown to ignore all three, so TERM stands for
# them.
# group_term <name> [env...]: sets LOG, the run's build.log.
group_term() {
  local name=$1; shift
  GROUP=1 start "$name" "$@"
  wait_for "$STUB/started.$name"
  kill -s TERM -- "-$(cat "$STUB/pid.$name")"
  wait_for "$STUB/rc.$name"
  LOG="$R/$(run_of "$name")/build.log"
}
# The signals the build.log tee ignored, from the stub packer's record.
tee_ignores() { ignored "$(cat "$STUB/$1/tee.sigign" 2>/dev/null || echo 0)"; }

@test "a group SIGTERM exits 143, logs Packer's cancellation and cleans up" {
  group_term group-term
  assert_equal "$(rc_of group-term)" 143
  run -0 cat "$LOG"
  assert_line "stub packer group-term cancelled"
  assert_cleaned group-term
  assert_equal "$(tee_ignores group-term)" "HUP INT TERM"
}

@test "a group SIGTERM with a token leak exits 2 and reports the leak in build.log" {
  group_term group-term-leak STUB_LEAK=1
  assert_equal "$(rc_of group-term-leak)" 2
  run -0 cat "$LOG"
  assert_line "stub packer group-term-leak cancelled"
  assert_file_contains "$LOG" "FATAL: API token found in $R/$(run_of group-term-leak)/packer-debug.log"
  assert_cleaned group-term-leak
  assert_equal "$(tee_ignores group-term-leak)" "HUP INT TERM"
}

# A debug log the leak check cannot read is reported, not taken as clean.
@test "an unreadable debug log is reported" {
  build unreadable STUB_UNREADABLE=1
  assert_file_contains "$STUB/out.unreadable" \
    "warning: cannot read $R/$(run_of unreadable)/packer-debug.log to check it for the API token"
}

# SAFBOX_DEV=1 keeps the run's key for pre-seal diagnostics, and its run is
# the newest.
@test "SAFBOX_DEV=1 exits 0, keeps the run's key and becomes the latest run" {
  build earlier
  build dev SAFBOX_DEV=1
  assert_equal "$(rc_of dev)" 0
  assert_file_exists "$R/$(run_of dev)/build_key"
  assert_equal "$(readlink "$R/.build/runs/latest")" "$(basename "$(run_of dev)")"
}
