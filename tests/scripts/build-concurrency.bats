#!/usr/bin/env bats
# Two scripts/build.sh runs on one workstation at the same time must not
# share a key, a Packer debug log, a build log or a galaxy install directory
# (the build key stays ephemeral and per-run, and the token never reaches
# the debug log).
#
# setup_file starts run one and holds it inside packer build (the stub
# packer records what build.sh handed it: the private key file, the debug
# log path, the galaxy directory), starts run two while run one is still
# building, records what can only be seen while both build, then lets run
# two finish first; run one, still building, reads its key and debug log
# afterwards, as Packer does when the build gate runs at the end of a
# build. Each test then checks one fact, for both runs where it applies.
#
#   tests/bats/run.sh tests/scripts/build-concurrency.bats
#   BUILD_SH=/path/build.sh tests/bats/run.sh ...    another copy of build.sh
bats_require_minimum_version 1.14.0
load ../bats/common
load helpers

RUN_RE='^\.build/runs/[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$'

setup_file() {
  scratch "$BATS_FILE_TMPDIR"
  start one
  wait_for "$STUB/started.one"
  start two
  wait_for "$STUB/started.two"
  # While both build.
  W=$T/while-building; mkdir "$W"
  for n in one two; do mode "$R/$(run_of "$n")" > "$W/mode.$n"; done
  readlink "$R/last.log" > "$W/last.log"
  last_log > "$W/last.log.resolved"
  readlink "$R/.build/runs/latest" > "$W/latest" 2>/dev/null || echo none > "$W/latest"
  # Run two finishes first.
  release two
  release one
  export W
}

teardown_file() {
  scratch_teardown
}

@test "each run has its own .build/runs/<UTC id>/ directory, mode 700" {
  assert_not_equal "$(run_of one)" "$(run_of two)"
  for n in one two; do
    assert_regex "$(run_of "$n")" "$RUN_RE"
    assert_equal "$(cat "$W/mode.$n")" 700
  done
}

@test "each run keeps its debug log, build log, galaxy, site and scans in its run directory" {
  run -0 cat "$STUB/npm.calls"
  for n in one two; do
    local d; d=$(run_of "$n")
    assert_equal "$(rundir_of "$(cat "$STUB/$n/debuglog")")" "$d"
    assert_equal "$(sed -n 's/^build log: //p' "$STUB/out.$n" | head -1)" "$R/$d/build.log"
    assert_equal "$(cat "$STUB/$n/galaxy")" "$R/$d/galaxy"
    assert_equal "$(cat "$STUB/$n/site")" "$R/$d/site"
    assert_line -- "--prefix $R/site run build -- --outDir $R/$d/site"
    assert_equal "$(cat "$STUB/$n/run_id")" "$(basename "$d")"
    assert_equal "$(cat "$STUB/$n/scans")" "$R/$d/scans"
  done
}

@test "build.sh installs the site's pinned packages" {
  run -0 cat "$STUB/npm.calls"
  assert_line -- "--prefix $R/site ci --no-audit --no-fund"
}

# last.log goes through .build/runs/latest, so the two can never name
# different runs, whatever order concurrent starts repoint them in.
@test "last.log and .build/runs/latest name the newest run, during and after both runs" {
  assert_equal "$(cat "$W/last.log")" .build/runs/latest/build.log
  assert_equal "$(cat "$W/last.log.resolved")" "$(build_log_of two)"
  assert_equal "$(cat "$W/latest")" "$(basename "$(run_of two)")"
  assert_equal "$(last_log)" "$(build_log_of two)"
}

@test "both runs exit 0" {
  assert_equal "$(rc_of one)" 0
  assert_equal "$(rc_of two)" 0
}

@test "run two starting neither replaced nor removed run one's key" {
  assert_equal "$(cat "$STUB/one/key.after")" "$(cat "$STUB/one/key.before")"
  assert_not_equal "$(cat "$STUB/one/key.after")" missing
}

@test "both debug logs survive the other run" {
  assert_equal "$(cat "$STUB/one/debuglog.kept")" yes
  assert_equal "$(cat "$STUB/two/debuglog.kept")" yes
}

@test "each run's output is in its own build log only" {
  assert_file_contains "$R/$(run_of one)/build.log" 'stub packer one done'
  assert_file_contains "$R/$(run_of two)/build.log" 'stub packer two done'
  assert_file_not_contains "$R/$(run_of one)/build.log" 'stub packer two'
}

# Without SAFBOX_DEV each run deletes its own key and galaxy install at the
# end, and keeps its logs.
@test "each run deletes its key and galaxy install and keeps its logs" {
  for n in one two; do
    local d; d=$R/$(run_of "$n")
    assert_file_not_exists "$d/build_key"
    assert_file_not_exists "$d/build_key.pub"
    assert_not_exists "$d/galaxy"
    assert_size_not_zero "$d/packer-debug.log"
    assert_size_not_zero "$d/build.log"
  done
}
