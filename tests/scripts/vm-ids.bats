#!/usr/bin/env bats
# Which VM ID scripts/build.sh gives the template and scripts/clone-and-ssh.sh
# gives the clone: an explicit one, else the first ID free in the cluster
# within a configured range (SAFBOX_TEMPLATE_IDS, SAFBOX_CLONE_IDS), asked
# of the stub Proxmox API (tests/scripts/stubs/curl, STUB_VMS in use).
# Also -h/--help on the three scripts, which must name every flag and
# environment variable the scripts read. The IDs are synthetic.
#
#   tests/bats/run.sh tests/scripts/vm-ids.bats
bats_require_minimum_version 1.14.0
load ../bats/common
load helpers

setup() {
  scratch "$BATS_TEST_TMPDIR"
  mkdir -p "$R/.build"
  # The clone key clone-and-ssh.sh would otherwise make; any key will do.
  ssh-keygen -q -t ecdsa -b 256 -N '' -f "$R/.build/clone_key"
}

teardown() {
  scratch_teardown
}

# build_now [env...]: build.sh in the scratch repository, run to the end
# (the stub packer released at once), with BUILD_ARGS after -var vm_name=t.
build_now() {
  touch "$STUB/release.t"
  run env -u PROXMOX_URL -u PROXMOX_USERNAME -u PROXMOX_TOKEN -u SAFBOX_DEV -u SAFBOX_TEMPLATE_IDS "$@" \
    HOME="$T/home" PATH="$T/bin:$PATH" STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$T/packer.env" \
    "$R/scripts/build.sh" -var vm_name=t ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
}

# clone_now ARGS... : clone-and-ssh.sh ARGS in the scratch repository; the
# stub ssh refuses every login, so a run that clones ends there.
clone_now() {
  run env -u SAFBOX_CLONE_IDS ${CLONE_ENV[@]+"${CLONE_ENV[@]}"} HOME="$T/home" PATH="$T/cbin:$PATH" \
    STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$T/packer.env" SAFBOX_NODE=node SAFBOX_POOL=pool \
    timeout 15 "$R/scripts/clone-and-ssh.sh" "$@"
}

# nextid_calls: how many IDs the picker asked the stub API about.
nextid_calls() {
  if [ -e "$STUB/curl.calls" ]; then grep -c 'cluster/nextid' "$STUB/curl.calls" || true; else echo 0; fi
}

@test "build.sh takes the first free ID in SAFBOX_TEMPLATE_IDS, says why, and it beats a vars file's vm_id" {
  build_now SAFBOX_TEMPLATE_IDS=500-503 STUB_VMS="500 501 503"
  assert_success
  assert_equal "$(cat "$STUB/t/vm_id")" 502
  assert_output --partial 'VM ID 502: the first free ID in SAFBOX_TEMPLATE_IDS=500-503 (in use: 500 501)'
  # It stops asking at the first free one.
  refute grep -q 'vmid=503' "$STUB/curl.calls"
}

@test "a full SAFBOX_TEMPLATE_IDS fails before Packer, listing what holds it" {
  rm "$R/packer/local.auto.pkrvars.hcl"
  build_now SAFBOX_TEMPLATE_IDS=500-502 STUB_VMS="500 501 502"
  assert_failure 1
  assert_output --partial 'SAFBOX_TEMPLATE_IDS=500-502 is full'
  assert_output --partial '  500 vm-500 (VM on pve)'
  assert_output --partial '  502 vm-502 (VM on pve)'
  assert_file_not_exists "$STUB/t"
  assert_file_not_exists "$R/.build/runs"
}

@test "an ID the token cannot see is still in use, and listed as such" {
  rm "$R/packer/local.auto.pkrvars.hcl"
  # /cluster/resources lists only the VMs the token may audit; nextid
  # answers for the whole cluster.
  build_now SAFBOX_TEMPLATE_IDS=500-501 STUB_VMS="501" STUB_HIDDEN="500"
  assert_failure 1
  assert_output --partial "  500 (not visible to this token)"
  assert_output --partial "  501 vm-501 (VM on pve)"
}

@test "an explicit -var vm_id wins over the range, and the API is not asked" {
  BUILD_ARGS=(-var vm_id=777)
  build_now SAFBOX_TEMPLATE_IDS=500-502
  assert_success
  assert_equal "$(cat "$STUB/t/vm_id")" 777
  assert_output --partial 'VM ID 777 from -var vm_id'
  assert_equal "$(nextid_calls)" 0
}

@test "-var=vm_id=N counts as explicit too" {
  BUILD_ARGS=(-var=vm_id=778)
  build_now SAFBOX_TEMPLATE_IDS=500-502
  assert_success
  assert_equal "$(nextid_calls)" 0
}

@test "without a range a vars file's vm_id is Packer's to use, and named" {
  build_now
  assert_success
  assert_equal "$(cat "$STUB/t/vm_id")" ""
  assert_output --partial 'VM ID from vm_id in packer/local.auto.pkrvars.hcl'
  assert_equal "$(nextid_calls)" 0
}

@test "with neither a range nor a vm_id build.sh refuses, naming both ways" {
  rm "$R/packer/local.auto.pkrvars.hcl"
  build_now
  assert_failure 2
  assert_output --partial "SAFBOX_TEMPLATE_IDS=FIRST-LAST in $T/packer.env"
  assert_output --partial '-var vm_id=N'
  assert_file_not_exists "$R/.build/runs"
}

@test "a range that is not FIRST-LAST is refused" {
  for bad in 500 502-500 abc 050-060 1-5; do
    build_now SAFBOX_TEMPLATE_IDS=$bad
    assert_failure 1
    assert_output --partial "SAFBOX_TEMPLATE_IDS=$bad"
  done
  assert_file_not_exists "$STUB/t"
}

@test "an API that does not answer fails the pick, not as a full range" {
  build_now SAFBOX_TEMPLATE_IDS=500-502 STUB_API_DOWN=1
  assert_failure 1
  assert_output --partial 'cannot ask the Proxmox API whether VM ID 500 is free'
  refute_output --partial 'is full'
}

@test "the range in the env file is used" {
  echo 'SAFBOX_TEMPLATE_IDS=510-519' >> "$T/packer.env"
  build_now STUB_VMS="510"
  assert_success
  assert_equal "$(cat "$STUB/t/vm_id")" 511
}

@test "clone-and-ssh.sh without a clone ID takes the first free one in SAFBOX_CLONE_IDS" {
  CLONE_ENV=(SAFBOX_CLONE_IDS=600-605 STUB_VMS="600 601")
  clone_now 500 --keep
  assert_output --partial 'VM ID 602: the first free ID in SAFBOX_CLONE_IDS=600-605 (in use: 600 601)'
  assert_output --partial 'cloning 500 -> 602'
  assert_file_contains "$STUB/curl.calls" '/nodes/node/qemu/500/clone'
}

@test "clone-and-ssh.sh with a clone ID uses it and asks nothing" {
  CLONE_ENV=(SAFBOX_CLONE_IDS=600-605)
  clone_now 500 650 --keep
  assert_output --partial 'cloning 500 -> 650'
  assert_equal "$(nextid_calls)" 0
}

@test "a full SAFBOX_CLONE_IDS fails before anything is cloned" {
  CLONE_ENV=(SAFBOX_CLONE_IDS=600-601 STUB_VMS="600 601")
  clone_now 500
  assert_failure 1
  assert_output --partial 'SAFBOX_CLONE_IDS=600-601 is full'
  assert_output --partial '  601 vm-601 (VM on pve)'
  refute grep -q '/clone$' "$STUB/curl.calls"
}

@test "clone-and-ssh.sh with neither a clone ID nor a range refuses, naming both ways" {
  clone_now 500 --keep
  assert_failure 2
  assert_output --partial "SAFBOX_CLONE_IDS=FIRST-LAST in $T/packer.env"
  assert_output --partial 'clone ID as the second argument'
  assert_file_not_exists "$STUB/curl.calls"
}

@test "clone-and-ssh.sh refuses an unknown option or a third ID" {
  clone_now 500 650 --kept
  assert_failure 2
  clone_now 500 650 651
  assert_failure 2
  assert_file_not_exists "$STUB/curl.calls"
}

# names <file...>: every environment variable the files read.
names() { grep -ohE '\b(SAFBOX|PROXMOX)_[A-Z_]+\b|\bSSL_CERT_FILE\b' "$@" | sort -u; }

@test "build.sh --help names every variable it and lib.sh read, and runs nothing" {
  for h in -h --help; do
    run env -u PROXMOX_URL PATH="$T/bin:$PATH" STUB_DIR="$STUB" "$R/scripts/build.sh" -var vm_id=1 "$h"
    assert_success
    assert_line --index 0 --partial 'usage: scripts/build.sh'
    for n in $(names "$R/scripts/build.sh" "$R/scripts/lib.sh"); do assert_output --partial "$n"; done
    assert_output --partial 'packer/local.auto.pkrvars.hcl'
    # shellcheck disable=SC2088 # the help prints the tilde as written
    assert_output --partial '~/.config/proxmox/packer.env'
  done
  assert_file_not_exists "$STUB/t"
  assert_file_not_exists "$R/.build/runs"
}

@test "clone-and-ssh.sh --help names every flag and variable it and lib.sh read" {
  for h in -h --help; do
    run env -u PROXMOX_URL PATH="$T/cbin:$PATH" STUB_DIR="$STUB" "$R/scripts/clone-and-ssh.sh" "$h"
    assert_success
    assert_line --index 0 --partial 'usage: scripts/clone-and-ssh.sh'
    for n in $(names "$R/scripts/clone-and-ssh.sh" "$R/scripts/lib.sh"); do assert_output --partial "$n"; done
    assert_output --partial '--keep'
  done
  assert_file_not_exists "$STUB/curl.calls"
}

@test "validate.sh --help names every flag it takes" {
  for h in -h --help; do
    run "$ROOT/scripts/validate.sh" "$h"
    assert_success
    assert_line --index 0 --partial 'usage: scripts/validate.sh'
    for f in $(grep -oE '^\s+--[a-z-]+\)' "$ROOT/scripts/validate.sh" | tr -d ' )'); do
      assert_output --partial -- "$f"
    done
  done
}

# scripts/example.env is what people copy to make their env file, so it
# must offer every variable the scripts read, as a NAME= line (commented
# out for the optional ones), and stay valid shell with placeholders only.
@test "scripts/example.env offers every variable the scripts read and sources cleanly" {
  local ex=$ROOT/scripts/example.env n
  for n in $(names "$ROOT/scripts/build.sh" "$ROOT/scripts/clone-and-ssh.sh" "$ROOT/scripts/lib.sh"); do
    # SAFBOX_PROXMOX_ENV names the file itself, so the file only mentions it.
    if [ "$n" = SAFBOX_PROXMOX_ENV ]; then assert_file_contains "$ex" "$n"; continue; fi
    assert_file_contains "$ex" "^\(# \)\{0,1\}$n="
  done
  # shellcheck disable=SC2016 # the inner shell expands them
  run env -i HOME="$T/home" bash -euc 'set -a; . "$1"; echo "$PROXMOX_URL $SAFBOX_TEMPLATE_IDS"' _ "$ex"
  assert_success
  assert_output 'https://pve.example.invalid:8006/api2/json 1000-1009'
}
