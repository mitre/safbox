#!/usr/bin/env bats
# scripts/validate.sh against the stub cinc-auditor and saf
# (tests/scripts/stubs/): which profiles the release gate runs, with which
# inputs, against which thresholds, its read-only client mode
# (--client-read-only), which a clone kept for a person gets, and
# --results-dir, which keeps the build gate's box profile results for the
# template (scripts/build.sh gives it the run's scans directory; the seal
# installs them with the time each scan ended, taken from the file). Each
# test runs it in a scratch repository of its own.
#
#   tests/bats/run.sh tests/scripts/validate.bats
#   VALIDATE_SH=/path/validate.sh tests/bats/run.sh ...    another copy
bats_require_minimum_version 1.14.0
load ../bats/common

setup() {
  VALIDATE_SH=${VALIDATE_SH:-$ROOT/scripts/validate.sh}
  T=$BATS_TEST_TMPDIR R=$BATS_TEST_TMPDIR/root STUB=$BATS_TEST_TMPDIR/stub
  mkdir -p "$R/scripts" "$R/verify/profiles" "$R/verify/inputs" "$T/bin" "$STUB"
  cp "$VALIDATE_SH" "$R/scripts/validate.sh"
  cp -r "$ROOT/verify/thresholds" "$R/verify/"
  : > "$R/verify/inputs/build.yml"
  mkdir -p "$R/packer/answerfiles/el10"
  cp "$ROOT/packer/answerfiles/el10/guest-agents.yml" "$R/packer/answerfiles/el10/"
  cp "$ROOT/tests/scripts/stubs/cinc-auditor" "$ROOT/tests/scripts/stubs/saf" "$T/bin/"
  INPUTS=$T/inputs.yml
  (umask 077 && : > "$INPUTS")
  KEPT=$T/run/scans
}

# validate [args...]: validate.sh with the stubs, its output in
# $STUB/out and its exit status in $STUB/rc.
validate() {
  local rc=0
  PATH="$T/bin:$PATH" STUB_DIR="$STUB" "$R/scripts/validate.sh" "$@" >"$STUB/out" 2>&1 || rc=$?
  echo "$rc" > "$STUB/rc"
}
rc() { cat "$STUB/rc"; }
# client_run / client_threshold: the client profile's cinc-auditor run and
# the threshold its results were held to.
client_run() { grep -- 'safbox-client ' "$STUB/cinc.calls"; }
client_threshold() { grep -o -- '-T [^ ]*client[^ ]*' "$STUB/saf.calls"; }
# results_of <profile>: the results file the scan of <profile> wrote in
# .build/ (the name's time stamp tells safbox from the overlay).
results_of() { find "$R/.build" -maxdepth 1 -regex ".*/validate-build-$1-[0-9]*T[0-9]*Z\.json"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

@test "the release gate with --client-inputs runs the full client profile against client-release.yml" {
  validate --client-inputs "$INPUTS" admin@192.0.2.50 key release
  assert_equal "$(rc)" 0
  run client_run
  assert_success
  refute_output --partial 'read_only'
  assert_equal "$(client_threshold)" "-T $R/verify/thresholds/client-release.yml"
}

@test "--client-read-only runs only the client profile read-only, against its own threshold" {
  validate --client-inputs "$INPUTS" --client-read-only admin@192.0.2.50 key release
  assert_equal "$(rc)" 0
  run client_run
  assert_output --partial 'read_only=true'
  assert_equal "$(client_threshold)" "-T $R/verify/thresholds/client-release-read-only.yml"
  assert_file_contains "$STUB/out" 'read-only.*skipped'
  # The box's own profiles are left as they are.
  run grep -c -- 'read_only' "$STUB/cinc.calls"
  assert_output 1
  run grep -c -- '-T [^ ]*/\(safbox\|stig\)-release.yml' "$STUB/saf.calls"
  assert_output 2
}

@test "--client-read-only without --client-inputs is refused before any scan, naming --client-inputs" {
  validate --client-read-only admin@192.0.2.50 key release
  assert_equal "$(rc)" 2
  assert_file_not_exists "$STUB/cinc.calls"
  assert_file_contains "$STUB/out" 'client-read-only.*--client-inputs'
}

# The guest agents the answer file installs, by hypervisor
# (packer/answerfiles/el10/guest-agents.yml): the box's profiles pick the
# one for the hypervisor they detect. A site's inputs come after, so a
# site may change them.
@test "every scan gets the answer file's guest agents, before the site's inputs" {
  SITE=$T/site.yml
  : > "$SITE"
  validate --site-inputs "$SITE" --client-inputs "$INPUTS" admin@192.0.2.50 key release
  assert_equal "$(rc)" 0
  run grep -c -- "--input-file $R/packer/answerfiles/el10/guest-agents.yml $SITE" "$STUB/cinc.calls"
  assert_output 3
}

@test "the build gate gets the guest agents before the build context's inputs" {
  validate admin@192.0.2.50 key build
  assert_equal "$(rc)" 0
  run grep -c -- "--input-file $R/packer/answerfiles/el10/guest-agents.yml $R/verify/inputs/build.yml" "$STUB/cinc.calls"
  assert_output 2
}

@test "--results-dir keeps the box profiles' results, with their scan times, in an owner-only directory" {
  validate --results-dir "$KEPT" admin@192.0.2.50:22 key build
  assert_equal "$(rc)" 0
  run env LC_ALL=C ls "$KEPT"
  assert_output "safbox-rhel10-stig-overlay.json
safbox.json"
  for profile in safbox safbox-rhel10-stig-overlay; do
    scanned=$(results_of "$profile")
    assert [ -n "$scanned" ]
    cmp "$scanned" "$KEPT/$profile.json"
    assert_equal "$(mtime "$KEPT/$profile.json")" "$(mtime "$scanned")"
  done
  assert_equal "$(mode "$KEPT")" 700
}

@test "--results-dir does not keep the client profile's results" {
  validate --results-dir "$KEPT" --client-inputs "$INPUTS" admin@192.0.2.50 key release
  assert_equal "$(rc)" 0
  assert_file_not_exists "$KEPT/safbox-client.json"
  assert_file_exists "$KEPT/safbox.json"
}

@test "without --results-dir nothing is kept beside .build/" {
  validate admin@192.0.2.50:22 key build
  assert_equal "$(rc)" 0
  assert_file_not_exists "$KEPT"
}

@test "--results-dir with no directory is a usage error, before any scan" {
  validate --results-dir
  assert_equal "$(rc)" 2
  assert_file_not_exists "$STUB/cinc.calls"
}
