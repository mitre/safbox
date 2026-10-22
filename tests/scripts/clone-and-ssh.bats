#!/usr/bin/env bats
# scripts/clone-and-ssh.sh against the stub curl (the Proxmox API), ssh and
# sleep (tests/scripts/stubs/): which build keys it offers a development
# template, when it runs the release gate (stub validate.sh), and which
# extra SSH keys it hands cloud-init or refuses. Each test runs it in a
# scratch repository of its own.
#
#   tests/bats/run.sh tests/scripts/clone-and-ssh.bats
#   CLONE_SH=/path/clone-and-ssh.sh tests/bats/run.sh ...    another copy
bats_require_minimum_version 1.14.0
load ../bats/common
load helpers

# Made once for the file and only read by the tests: the clone key
# clone-and-ssh.sh would otherwise make on every run (RSA 4096, as it
# does), and throwaway extra keys of every type the checks tell apart.
setup_file() {
  K=$BATS_FILE_TMPDIR/keys; mkdir -p "$K"
  ssh-keygen -q -t rsa -b 4096 -N '' -C safbox-clone -f "$K/clone_key"
  local spec t b
  for spec in ecdsa:256 ecdsa:384 ecdsa:521 rsa:2048 rsa:3072 rsa:1024 ed25519:; do
    t=${spec%%:*} b=${spec#*:}
    ssh-keygen -q -t "$t" ${b:+-b "$b"} -N '' -C "$t$b" -f "$K/$t$b"
  done
  grep -v '^-' "$K/ecdsa384" | head -1 > "$K/junk.pub"   # base64, not a key line
  cat "$K/ecdsa256.pub" "$K/ed25519.pub" > "$K/mixed.pub"
  { echo '# the owner'; echo; echo "  $(cat "$K/ecdsa256.pub")"; } > "$K/commented.pub"
  export K
}

setup() {
  scratch "$BATS_TEST_TMPDIR"
  mkdir -p "$R/.build"
  cp "$K/clone_key" "$K/clone_key.pub" "$R/.build/"
}

teardown() {
  scratch_teardown
}

# When the clone's user cannot log in, clone-and-ssh.sh reads the
# development template's state as the build user with the key of the run
# that built it. With several runs' keys kept it offers each, newest first
# (the template accepts only its own); SAFBOX_BUILD_KEY names one. Without
# STUB_BOOT the stub ssh refuses every login and records the build user's
# keys.
@test "every kept run key is offered newest first, or the one SAFBOX_BUILD_KEY names" {
  local older="$R/.build/runs/20200101T000000Z-aaaaaa"
  mkdir -p "$older"
  ssh-keygen -q -t rsa -b 2048 -N '' -C older -f "$older/build_key"
  build dev SAFBOX_DEV=1
  clone_and_ssh
  assert_file_exists "$STUB/build-user-keys"
  assert_equal "$(cat "$STUB/build-user-keys")" "$(printf '%s\n' "$R/$(run_of dev)/build_key" "$older/build_key")"
  clone_and_ssh SAFBOX_BUILD_KEY="$older/build_key"
  assert_file_exists "$STUB/build-user-keys"
  assert_equal "$(cat "$STUB/build-user-keys")" "$older/build_key"
}

# The release gate runs only once the clone has finished booting. A
# finished boot with failed units (degraded) is scanned, the units listed;
# a boot that never settles within SAFBOX_READY_TIMEOUT fails, naming the
# queued jobs, without a scan. With STUB_BOOT set, admin and safuser log in
# and the clone's boot ends in that state (running; degraded; hang: never
# settles; sshfail: ssh itself fails).
@test "a clone that finished booting is scanned after safuser logs in with the deployer's key" {
  clone_and_ssh STUB_BOOT=running
  assert_equal "$(clone_rc)" 0
  assert_scanned
  assert_file_contains "$STUB/clone.out" 'PASS: safuser logs in'
}

@test "a clone whose boot ends degraded is scanned, its failed units listed" {
  clone_and_ssh STUB_BOOT=degraded
  assert_equal "$(clone_rc)" 0
  assert_scanned
  assert_file_contains "$STUB/clone.out" 'healthcheck'
}

@test "a boot that never settles fails unscanned within SAFBOX_READY_TIMEOUT, naming the queued job" {
  clone_and_ssh STUB_BOOT=hang SAFBOX_READY_TIMEOUT=1
  assert_equal "$(clone_rc)" 1
  refute_scanned
  assert_file_contains "$STUB/clone.out" 'still booting after 1s'
  assert_file_contains "$STUB/clone.out" 'vulcan.service'
}

@test "a failed ssh while waiting fails unscanned, not as a timeout" {
  clone_and_ssh STUB_BOOT=sshfail
  assert_equal "$(clone_rc)" 1
  refute_scanned
  assert_file_contains "$STUB/clone.out" 'ssh failed (exit 255)'
}

@test "a SAFBOX_READY_TIMEOUT that is not a positive number is refused" {
  clone_and_ssh STUB_BOOT=running SAFBOX_READY_TIMEOUT=10m
  assert_equal "$(clone_rc)" 2
  refute_scanned
}

@test "a clone where safuser never logs in fails unscanned, naming safuser" {
  clone_and_ssh STUB_BOOT=running STUB_SAFUSER_REFUSED=1
  assert_equal "$(clone_rc)" 1
  refute_scanned
  assert_file_contains "$STUB/clone.out" 'SSH as safuser with the deployer.s key failed'
}

# A clone kept for a person (--keep) gets the release gate's read-only
# client mode, which skips the client profile's state-changing controls and
# so leaves safuser's first Keycloak sign-in for that person; a clone the
# run destroys gets the full gate.
@test "a kept clone's release gate runs the client profile read-only and says so" {
  clone_and_ssh STUB_BOOT=running
  assert_scanned
  assert_file_contains "$STUB/validate.args" '^--client-read-only$'
  assert_file_contains "$STUB/validate.args" '^--client-inputs$'
  assert_file_contains "$STUB/clone.out" "first Keycloak sign-in"
}

@test "a clone that is not kept gets the full release gate" {
  KEEP='' clone_and_ssh STUB_BOOT=running
  assert_equal "$(clone_rc)" 0
  assert_file_contains "$STUB/validate.args" '^--client-inputs$'
  assert_file_not_contains "$STUB/validate.args" 'read-only'
}

# A switched-off service has no units on the clone, so it neither holds up
# the wait nor fails it; a switched-on service that never becomes ready
# does both. With STUB_BOOT=units the stub clone's boot settles once every
# unit in STUB_UNITS (unit:active or unit:starting) is active, and its
# queued jobs are the starting ones.
ON_UNITS='heimdall.service:active heimdall-db.service:active safbox-proxy.service:active'

# The reads of the first-boot passwords for the client profile name each
# service's podman secret, which a switched-off service lacks; no other
# remote command names it.
@test "a clone with vulcan switched off waits over ssh, ends running and is scanned" {
  clone_and_ssh STUB_BOOT=units STUB_UNITS="$ON_UNITS"
  assert_equal "$(clone_rc)" 0
  assert_scanned
  assert_file_contains "$STUB/clone.out" 'clone 9170 finished booting$'
  assert_file_contains "$STUB/ssh.cmds" 'is-system-running --wait'
  run -0 grep -v '^sudo -n podman secret inspect ' "$STUB/ssh.cmds"
  refute_output --partial vulcan
}

@test "a clone with vulcan switched on but never ready fails unscanned, naming only vulcan" {
  clone_and_ssh STUB_BOOT=units SAFBOX_READY_TIMEOUT=1 STUB_UNITS="$ON_UNITS vulcan.service:starting"
  assert_equal "$(clone_rc)" 1
  refute_scanned
  assert_file_contains "$STUB/clone.out" 'still booting after 1s (SAFBOX_READY_TIMEOUT); jobs still queued:'
  assert_file_contains "$STUB/clone.out" 'vulcan.service start running'
  assert_file_not_contains "$STUB/clone.out" 'heimdall'
}

# clone-and-ssh.sh hands cloud-init the build key, then every *.pub in the
# checkout's .build/keys/, then every file SAFBOX_EXTRA_SSH_KEYS names
# (colon-separated). It refuses, before any API call, an extra key that
# SAFBox's FIPS-mode sshd does not accept: its PubkeyAcceptedAlgorithms
# are ECDSA (nistp256, nistp384, nistp521) and RSA, with RequiredRSASize
# 2048; Ed25519 is refused.
# extra_keys [env...]: a booting clone without the release gate.
extra_keys() { clone_and_ssh STUB_BOOT=running SAFBOX_SKIP_VALIDATE=1 "$@"; }
# keys_dir: .build/keys with two accepted keys, and a private key without
# .pub, which is not read.
keys_dir() {
  mkdir -p "$R/.build/keys"
  cp "$K/ecdsa384.pub" "$K/rsa3072.pub" "$K/rsa2048" "$R/.build/keys/"
}
# sent: the keys cloud-init got.
sent() { cat "$STUB/sshkeys" 2>/dev/null || echo "no sshkeys sent"; }

@test "cloud-init gets the build key, then .build/keys, then SAFBOX_EXTRA_SSH_KEYS' key lines" {
  extra_keys
  assert_equal "$(clone_rc)" 0
  assert_equal "$(sent)" "$(cat "$R/.build/clone_key.pub")"
  keys_dir
  extra_keys
  assert_equal "$(clone_rc)" 0
  assert_equal "$(sent)" "$(cat "$R/.build/clone_key.pub" "$K/ecdsa384.pub" "$K/rsa3072.pub")"
  extra_keys SAFBOX_EXTRA_SSH_KEYS="$K/ecdsa256.pub:$K/ecdsa521.pub:$K/rsa2048.pub"
  assert_equal "$(clone_rc)" 0
  assert_equal "$(sent)" "$(cat "$R/.build/clone_key.pub" "$K/ecdsa384.pub" "$K/rsa3072.pub" \
    "$K/ecdsa256.pub" "$K/ecdsa521.pub" "$K/rsa2048.pub")"
  # Blank and comment lines are skipped, the key line trimmed.
  extra_keys SAFBOX_EXTRA_SSH_KEYS="$K/commented.pub"
  assert_equal "$(clone_rc)" 0
  assert_equal "$(sent)" "$(cat "$R/.build/clone_key.pub" "$K/ecdsa384.pub" "$K/rsa3072.pub" "$K/ecdsa256.pub")"
}

# A refused key: exit 2, no API call, and a message naming the file and the
# accepted types. Each row: the file named in the message, then what
# SAFBOX_EXTRA_SSH_KEYS is set to (the keys directory row sets nothing and
# puts an Ed25519 key in .build/keys instead, so it runs last).
@test "every key SAFBox's sshd would not accept is refused before any API call" {
  local accepted='ECDSA (nistp256, nistp384, nistp521) or RSA of at least 2048 bits'
  local row file extra
  keys_dir
  for row in \
    "$K/ed25519.pub|$K/ed25519.pub" \
    "$K/mixed.pub|$K/mixed.pub" \
    "$K/rsa1024.pub|$K/rsa1024.pub" \
    "$K/junk.pub|$K/junk.pub" \
    "$K/ecdsa384|$K/ecdsa384" \
    "$K/absent.pub|$K/absent.pub" \
    "$R/.build/keys/ed25519.pub|"; do
    file=${row%%|*} extra=${row#*|}
    [ -n "$extra" ] || cp "$K/ed25519.pub" "$R/.build/keys/"
    extra_keys ${extra:+SAFBOX_EXTRA_SSH_KEYS="$extra"}
    assert_equal "$(clone_rc) $file" "2 $file"
    assert_file_not_exists "$STUB/curl.calls"
    assert_file_contains "$STUB/clone.out" "$file"
    assert_file_contains "$STUB/clone.out" "$accepted"
  done
  # The last row's Ed25519 refusal says what it is.
  assert_file_contains "$STUB/clone.out" 'ED25519'
}

@test "a refused private key's contents are not printed" {
  keys_dir
  extra_keys SAFBOX_EXTRA_SSH_KEYS="$K/ecdsa384"
  assert_equal "$(clone_rc)" 2
  assert_file_not_contains "$STUB/clone.out" 'PRIVATE KEY'
}

# The credentials file check build.sh makes (scripts/lib.sh) protects this
# script too.
@test "a credentials file others can read is refused before any API call" {
  chmod 644 "$T/packer.env"
  clone_and_ssh STUB_BOOT=running
  assert_equal "$(clone_rc)" 1
  assert_file_not_exists "$STUB/curl.calls"
  assert_file_contains "$STUB/clone.out" "refusing $T/packer.env: mode 644, must be 600"
}
