# shellcheck shell=bash
# Shared by the scripts/build.sh and scripts/clone-and-ssh.sh suites: a
# scratch copy of the repository layout with the committed stub programs
# (tests/scripts/stubs/, each file says what it does), so nothing touches
# the checkout's .build/ or last.log, or a hypervisor, and helpers that run
# the two scripts there. BUILD_SH and CLONE_SH name other copies of the
# scripts to test (a scratch copy with a guard broken, say).
BUILD_SH=${BUILD_SH:-$ROOT/scripts/build.sh}
CLONE_SH=${CLONE_SH:-$ROOT/scripts/clone-and-ssh.sh}
STUBS=$ROOT/tests/scripts/stubs

# scratch <dir>: lay out <dir>; sets and exports
#   T     <dir>
#   R     the scratch repository (scripts/ holds build.sh, clone-and-ssh.sh
#         and the stub check-tools.sh and validate.sh)
#   STUB  the stubs' records and signals
# with <dir>/bin (stub packer, npm) for build.sh, <dir>/cbin (stub curl,
# ssh, sleep) for clone-and-ssh.sh, <dir>/home as HOME and the fake
# credentials (tests/scripts/fixtures/packer.env) at <dir>/packer.env.
scratch() {
  T=$1 R=$1/root STUB=$1/stub
  export T R STUB
  mkdir -p "$R/scripts" "$R/packer" "$T/bin" "$T/cbin" "$T/home" "$STUB"
  cp "$BUILD_SH" "$R/scripts/build.sh"
  cp "$CLONE_SH" "$R/scripts/clone-and-ssh.sh"
  cp "$ROOT/scripts/lib.sh" "$R/scripts/lib.sh"
  chmod +x "$R/scripts/build.sh" "$R/scripts/clone-and-ssh.sh"
  cp "$STUBS/check-tools.sh" "$STUBS/validate.sh" "$R/scripts/"
  cp "$STUBS/packer" "$STUBS/npm" "$T/bin/"
  cp "$STUBS/curl" "$STUBS/ssh" "$STUBS/sleep" "$T/cbin/"
  cp "$ROOT/tests/scripts/fixtures/packer.env" "$T/packer.env"
  chmod 600 "$T/packer.env"
}

# scratch_teardown: stop any build still running (its PID is in
# $STUB/pid.<name>) and make everything removable again (the stub packer
# can leave a read-only directory or an unreadable log behind).
scratch_teardown() {
  local p
  for p in "$STUB"/pid.*; do
    [ -e "$p" ] || continue
    kill "$(cat "$p")" 2>/dev/null || true
  done
  chmod -R u+w "$T" 2>/dev/null || true
}

# wait_for <file>: up to 30 s for the file to appear.
wait_for() {
  local _
  for _ in $(seq 1 300); do [ -e "$1" ] && return 0; sleep 0.1; done
  fail "timed out waiting for $1"
}

# start <name> [env...]: build.sh -var vm_name=<name> in the background with
# the stub packer, which holds the build until $STUB/release.<name> exists.
# Its PID lands in $STUB/pid.<name>, its output in $STUB/out.<name>, its
# exit status in $STUB/rc.<name>. With GROUP=1 it runs in a session and
# process group of its own (setsid), so a signal can go to the whole group,
# as a terminal's or a supervisor's does. A non-interactive shell starts
# background jobs with SIGINT ignored, and bash cannot trap a signal ignored
# on entry, so GROUP=1 also restores SIGINT's default (GNU env
# --default-signal), as a terminal hands it to build.sh. File descriptor 3
# is closed, or bats would wait for the background job.
start() {
  local name=$1 launcher=() envopt=(); shift
  if [ "${GROUP:-0}" = 1 ]; then launcher=(setsid); envopt=(--default-signal=INT); fi
  ( rc=0
    ${launcher[@]+"${launcher[@]}"} env ${envopt[@]+"${envopt[@]}"} -u PROXMOX_URL -u PROXMOX_USERNAME -u PROXMOX_TOKEN -u SAFBOX_DEV "$@" \
      HOME="$T/home" PATH="$T/bin:$PATH" STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$T/packer.env" \
      "$R/scripts/build.sh" -var "vm_name=$name" >"$STUB/out.$name" 2>&1 &
    echo $! > "$STUB/pid.$name"
    wait $! || rc=$?
    echo "$rc" > "$STUB/rc.$name" ) 3>&- &
}

# release <name>: let the held build end, and wait until it has.
release() {
  touch "$STUB/release.$1"
  wait_for "$STUB/rc.$1"
}

# build <name> [env...]: one whole build.sh run, held and released at once.
build() {
  local name=$1; shift
  start "$name" "$@"
  wait_for "$STUB/started.$name"
  release "$name"
}

# The run directory that holds <file>, relative to the scratch root.
rundir_of() { local d; d=$(dirname "$1"); echo "${d#"$R"/}"; }
# run_of <name>: the run directory of build <name>, from the key it was given.
run_of() { rundir_of "$(cat "$STUB/$1/key")"; }
# rc_of <name>: the exit status of build <name>.
rc_of() { cat "$STUB/rc.$1"; }
# The physical path of the build log last.log resolves to.
last_log() { echo "$(cd -P "$(dirname "$R/$(readlink "$R/last.log")")" && pwd)/build.log"; }
# The physical path of build <name>'s build log.
build_log_of() { echo "$(cd -P "$R/$(run_of "$1")" && pwd)/build.log"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# ignored <SigIgn hex mask>: which of HUP(1), INT(2), TERM(15) it ignores.
ignored() {
  local m=$((16#$1)) out=() n
  for n in 1:HUP 2:INT 15:TERM; do
    if (( (m >> (${n%%:*} - 1)) & 1 )); then out+=("${n#*:}"); fi
  done
  echo "${out[*]:-none}"
}

# clone_and_ssh [env...]: scripts/clone-and-ssh.sh 9000 9170 --keep in the
# scratch repository with the stub curl, ssh and sleep, its output in
# $STUB/clone.out, its exit status in $STUB/clone.rc. The stub ssh records
# the build user's keys in $STUB/build-user-keys and, once logged in,
# each remote command in $STUB/ssh.cmds; the stub curl records the API
# calls in $STUB/curl.calls and the cloud-init keys in $STUB/sshkeys; the
# stub validate.sh leaves $STUB/scanned when the release gate runs. Each
# run is cut at 15 s (exit 124): the stub's never-settling boot lasts 60 s,
# so a case that ends in time shows clone-and-ssh.sh enforced its own
# timeout. The stub validate.sh also records its arguments in
# $STUB/validate.args. KEEP= (empty) runs it without --keep: its cleanup
# then finds no run ID in the stub API's clone and destroys nothing.
clone_and_ssh() {
  local rc=0 keep=${KEEP---keep}
  rm -f "$STUB/build-user-keys" "$STUB/ssh.cmds" "$STUB/sshkeys" "$STUB/curl.calls" "$STUB/scanned" "$STUB/validate.args"
  env "$@" HOME="$T/home" PATH="$T/cbin:$PATH" STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$T/packer.env" \
    SAFBOX_NODE=node SAFBOX_POOL=pool timeout 15 "$R/scripts/clone-and-ssh.sh" 9000 9170 ${keep:+"$keep"} \
    >"$STUB/clone.out" 2>&1 3>&- || rc=$?
  echo "$rc" > "$STUB/clone.rc"
}
# The exit status of the last clone_and_ssh.
clone_rc() { cat "$STUB/clone.rc"; }

# assert_scanned / refute_scanned: whether the release gate ran.
assert_scanned() { assert_file_exists "$STUB/scanned"; }
refute_scanned() { assert_file_not_exists "$STUB/scanned"; }
