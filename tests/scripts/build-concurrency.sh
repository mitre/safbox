#!/usr/bin/env bash
# Two scripts/build.sh runs on one workstation at the same time must not share
# a key, a Packer debug log, a build log or a galaxy install directory
# (ADR-0001 Quality Standards: the build key stays ephemeral and per-run; the
# token never reaches the debug log). build.sh runs from a scratch copy of
# the repository layout with a stub packer and a stub prerequisite check, so
# nothing here touches the checkout's .build/ or last.log, or a hypervisor.
#
# The stub packer records what build.sh handed it (the private key file, the
# debug log path, the galaxy directory), signals that it started, waits until
# the test releases it, and then reads its key and debug log again, as Packer
# does when the build gate runs at the end of a build.
#
#   tests/scripts/build-concurrency.sh [path to build.sh]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:-$ROOT/scripts/build.sh}

tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

R="$tmp/root"      # the scratch repository
STUB="$tmp/stub"   # stub packer's records and signals
mkdir -p "$R/scripts" "$R/packer" "$tmp/bin" "$tmp/home" "$STUB"
cp "$BUILD" "$R/scripts/build.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/check-tools.sh"
chmod +x "$R/scripts/build.sh" "$R/scripts/check-tools.sh"

TOKEN=00000000-1111-2222-3333-444444444444
umask 077
cat > "$tmp/packer.env" <<EOF
PROXMOX_URL=https://pve.example.invalid:8006/api2/json
PROXMOX_USERNAME=build@pve!test
PROXMOX_TOKEN=$TOKEN
EOF
chmod 600 "$tmp/packer.env"

# packer init: nothing. packer build -var vm_name=<n> ...: record, signal
# started.<n>, wait for release.<n>, then check that the key and the debug
# log it was given are still there and still the ones it saw at the start.
# STUB_LEAK=1 writes the token to the debug log; STUB_RO=1 leaves a
# directory under the galaxy install that its owner cannot delete from;
# STUB_RC=<n> is the exit status (default 0); STUB_UNREADABLE=1 leaves the
# debug log unreadable.
cat > "$tmp/bin/packer" <<'EOF'
#!/usr/bin/env bash
set -u
[ "$1" = build ] || exit 0
shift
name="" key="" galaxy="" site=""
while [ $# -gt 0 ]; do
  case "$1" in
    -var)
      case "$2" in
        vm_name=*) name=${2#vm_name=} ;;
        ssh_private_key_file=*) key=${2#ssh_private_key_file=} ;;
        galaxy_dir=*) galaxy=${2#galaxy_dir=} ;;
        site_dir=*) site=${2#site_dir=} ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
# Like Packer: a signal cancels the build, which says so on its output.
trap 'echo "stub packer $name cancelled"; exit 1' INT TERM HUP
d="$STUB_DIR/$name"; mkdir -p "$d"
echo "$key" > "$d/key"
echo "${PACKER_LOG_PATH:-}" > "$d/debuglog"
echo "$galaxy" > "$d/galaxy"
echo "$site" > "$d/site"
# What ansible-galaxy would install there.
mkdir -p "$galaxy/roles/RHEL10-STIG"
sum() { cksum < "$1" 2>/dev/null || echo missing; }
sum "$key" > "$d/key.before"
echo "stub packer $name debug line" >> "$PACKER_LOG_PATH"
if [ -n "${STUB_LEAK:-}" ]; then echo "leaked $PROXMOX_TOKEN" >> "$PACKER_LOG_PATH"; fi
# The signals the tee writing build.log ignores (SigIgn from /proc).
tee_pid=$(pgrep -f -n "tee -a $(dirname "$PACKER_LOG_PATH")/build.log" || true)
if [ -n "$tee_pid" ] && [ -r "/proc/$tee_pid/status" ]; then
  awk '/^SigIgn:/ {print $2}' "/proc/$tee_pid/status" > "$d/tee.sigign"
fi
touch "$STUB_DIR/started.$name"
for _ in $(seq 1 300); do [ -e "$STUB_DIR/release.$name" ] && break; sleep 0.1; done
sum "$key" > "$d/key.after"
grep -qx "stub packer $name debug line" "$PACKER_LOG_PATH" && echo yes > "$d/debuglog.kept" || echo no > "$d/debuglog.kept"
if [ -n "${STUB_UNREADABLE:-}" ]; then chmod 000 "$PACKER_LOG_PATH"; fi
if [ -n "${STUB_RO:-}" ]; then
  mkdir -p "$galaxy/roles/RHEL10-STIG/ro"; : > "$galaxy/roles/RHEL10-STIG/ro/file"
  chmod 555 "$galaxy/roles/RHEL10-STIG/ro"
fi
echo "stub packer $name done"
exit "${STUB_RC:-0}"
EOF
chmod +x "$tmp/bin/packer"
# Stub npm: build.sh builds the documentation site before Packer.
cat > "$tmp/bin/npm" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/npm.calls"
EOF
chmod +x "$tmp/bin/npm"

failures=0
fail() { echo "FAIL: $*" >&2; failures=1; }
expect() { # description got want
  if [ "$2" = "$3" ]; then echo "ok: $1"; else fail "$1: got '$2', want '$3'"; fi
}
# check <description> <command...>: ok when the command succeeds.
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else fail "$desc"; fi
}
not() { ! "$@"; }
wait_for() { # file
  for _ in $(seq 1 300); do [ -e "$1" ] && return 0; sleep 0.1; done
  echo "FAIL: timed out waiting for $1" >&2; exit 1
}
# start <name> [env...]: build.sh in the background; its PID lands in
# $STUB/pid.<name>, its exit status in $STUB/rc.<name>. With GROUP=1 it
# runs in a session and process group of its own (setsid), so a signal can
# go to the whole group, as a terminal's or a supervisor's does. A
# non-interactive shell starts background jobs with SIGINT ignored, and bash
# cannot trap a signal ignored on entry, so GROUP=1 also restores SIGINT's
# default (GNU env --default-signal), as a terminal hands it to build.sh.
start() {
  local name=$1 launcher=() envopt=(); shift
  if [ "${GROUP:-0}" = 1 ]; then launcher=(setsid); envopt=(--default-signal=INT); fi
  ( rc=0
    ${launcher[@]+"${launcher[@]}"} env ${envopt[@]+"${envopt[@]}"} -u PROXMOX_URL -u PROXMOX_USERNAME -u PROXMOX_TOKEN -u SAFBOX_DEV "$@" \
      HOME="$tmp/home" PATH="$tmp/bin:$PATH" STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$tmp/packer.env" \
      "$R/scripts/build.sh" -var "vm_name=$name" >"$STUB/out.$name" 2>&1 &
    echo $! > "$STUB/pid.$name"
    wait $! || rc=$?
    echo "$rc" > "$STUB/rc.$name" ) &
  pids+=($!)
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# The run directory that holds <file>, relative to the scratch root.
rundir_of() { local d; d=$(dirname "$1"); echo "${d#"$R"/}"; }
RUN_RE='^\.build/runs/[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$'

# Run one starts and is held inside packer build.
start one
wait_for "$STUB/started.one"
key1=$(cat "$STUB/one/key")
log1=$(cat "$STUB/one/debuglog")
run1=$(rundir_of "$key1")

# Run two starts while run one is still building.
start two
wait_for "$STUB/started.two"
key2=$(cat "$STUB/two/key")
log2=$(cat "$STUB/two/debuglog")
run2=$(rundir_of "$key2")

if [[ "$run1" =~ $RUN_RE ]] && [[ "$run2" =~ $RUN_RE ]]; then echo "ok: each key lives in .build/runs/<UTC id>/"
else fail "keys not in a run directory: '$key1', '$key2'"; fi
check "the two runs have different run directories" [ "$run1" != "$run2" ]
expect "run one's debug log is in its run directory" "$(rundir_of "$log1")" "$run1"
expect "run two's debug log is in its run directory" "$(rundir_of "$log2")" "$run2"
for r in "$run1" "$run2"; do
  expect "$r is mode 700" "$(mode "$R/$r" 2>/dev/null || echo missing)" 700
done
expect "run one's build log is in its run directory" "$(sed -n 's/^build log: //p' "$STUB/out.one" | head -1)" "$R/$run1/build.log"
for n in one two; do
  g=$(cat "$STUB/$n/galaxy"); r=$run1; [ "$n" = two ] && r=$run2
  expect "run $n installs galaxy content in its run directory" "$g" "$R/$r/galaxy"
  expect "run $n ships the site it built in its run directory" "$(cat "$STUB/$n/site")" "$R/$r/site"
  check "run $n builds the site into its run directory" grep -qx -- "--prefix $R/site run build -- --outDir $R/$r/site" "$STUB/npm.calls"
done
# last.log goes through .build/runs/latest, so the two can never name
# different runs, whatever order concurrent starts repoint them in.
expect "last.log points through .build/runs/latest" "$(readlink "$R/last.log")" .build/runs/latest/build.log
expect "last.log resolves to the newest run's log while both build" \
  "$(cd -P "$(dirname "$R/$(readlink "$R/last.log")")" && pwd)/build.log" "$(cd -P "$R/$run2" && pwd)/build.log"
expect ".build/runs/latest names the newest run" "$(readlink "$R/.build/runs/latest" 2>/dev/null || echo none)" "$(basename "$run2")"

# Run two finishes first; run one, still building, reads its key afterwards.
touch "$STUB/release.two"; wait_for "$STUB/rc.two"
touch "$STUB/release.one"; wait_for "$STUB/rc.one"
expect "run one exits 0" "$(cat "$STUB/rc.one")" 0
expect "run two exits 0" "$(cat "$STUB/rc.two")" 0
expect "run two starting did not replace or remove run one's key" "$(cat "$STUB/one/key.after")" "$(cat "$STUB/one/key.before")"
check "run one's key existed when its packer read it last" [ "$(cat "$STUB/one/key.after")" != missing ]
expect "run one's debug log survived run two" "$(cat "$STUB/one/debuglog.kept")" yes
expect "run two's debug log survived" "$(cat "$STUB/two/debuglog.kept")" yes
expect "last.log still resolves to the newest run after the older one ends" \
  "$(cd -P "$(dirname "$R/$(readlink "$R/last.log")")" && pwd)/build.log" "$(cd -P "$R/$run2" && pwd)/build.log"
check "run one's output is in its own build log" grep -q 'stub packer one done' "$R/$run1/build.log"
check "build.sh installs the site's pinned packages" grep -qx -- "--prefix $R/site ci --no-audit --no-fund" "$STUB/npm.calls"
check "run two's output is in its own build log" grep -q 'stub packer two done' "$R/$run2/build.log"
check "run two's output is not in run one's build log" not grep -q 'stub packer two' "$R/$run1/build.log"
# Without SAFBOX_DEV each run deletes its own key and galaxy install at the
# end, and keeps its logs.
for r in "$run1" "$run2"; do
  check "$r's private key is deleted at the end" [ ! -e "$R/$r/build_key" ]
  check "$r's public key is deleted at the end" [ ! -e "$R/$r/build_key.pub" ]
  check "$r's galaxy install is deleted at the end" [ ! -e "$R/$r/galaxy" ]
  check "$r keeps its debug log" [ -s "$R/$r/packer-debug.log" ]
  check "$r keeps its build log" [ -s "$R/$r/build.log" ]
done

# The token-leak check reads that run's own debug log, and a failed check
# still removes the key.
start leak STUB_LEAK=1
wait_for "$STUB/started.leak"
runl=$(rundir_of "$(cat "$STUB/leak/key")")
touch "$STUB/release.leak"; wait_for "$STUB/rc.leak"
expect "a token in the run's debug log fails the run with 2" "$(cat "$STUB/rc.leak")" 2
check "the leak message names that run's debug log" \
  grep -qF "FATAL: API token found in $R/$runl/packer-debug.log" "$STUB/out.leak"
check "the key is deleted after a token leak" [ ! -e "$R/$runl/build_key" ]

# A failing packer build keeps its exit status, and the cleanup deletes the
# key even when the galaxy install cannot be removed (it only warns), with
# and without a token leak (which still exits 2).
# cleanup_case <name> <want exit> <galaxy removable: yes|no> [env...]
cleanup_case() {
  local name=$1 want=$2 removable=$3 rd; shift 3
  start "$name" "$@"
  wait_for "$STUB/started.$name"
  rd=$(rundir_of "$(cat "$STUB/$name/key")")
  touch "$STUB/release.$name"; wait_for "$STUB/rc.$name"
  expect "$name: exit status" "$(cat "$STUB/rc.$name")" "$want"
  check "$name: the private key is deleted" [ ! -e "$R/$rd/build_key" ]
  check "$name: the public key is deleted" [ ! -e "$R/$rd/build_key.pub" ]
  if [ "$removable" = yes ]; then
    check "$name: the galaxy install is deleted" [ ! -e "$R/$rd/galaxy" ]
  else
    check "$name: the failed galaxy removal is reported" \
      grep -qF "warning: could not remove $R/$rd/galaxy" "$STUB/out.$name"
  fi
}
cleanup_case packer-fails 7 yes STUB_RC=7
cleanup_case galaxy-stuck 7 no STUB_RC=7 STUB_RO=1
cleanup_case galaxy-stuck-leak 2 no STUB_RC=7 STUB_RO=1 STUB_LEAK=1

# A SIGTERM sent to build.sh alone (not its group) still deletes the key
# once Packer has stopped; the group signal cases, Ctrl-C included, follow.
start term
wait_for "$STUB/started.term"
runt=$(rundir_of "$(cat "$STUB/term/key")")
kill -TERM "$(cat "$STUB/pid.term")"
touch "$STUB/release.term"; wait_for "$STUB/rc.term"
expect "a terminated run exits 143" "$(cat "$STUB/rc.term")" 143
check "the key is deleted after SIGTERM" [ ! -e "$R/$runt/build_key" ]

# A signal to the whole process group reaches build.sh, Packer and the tee
# that writes build.log. The run still ends through its cleanup: the key is
# deleted, the leak check still fails the run with 2 and says so in
# build.log, and Packer's cancellation output reaches build.log.
# group_case <name> <signal> <want exit> [env...]
group_case() {
  local name=$1 sig=$2 want=$3 rd log; shift 3
  GROUP=1 start "$name" "$@"
  wait_for "$STUB/started.$name"
  rd=$(rundir_of "$(cat "$STUB/$name/key")"); log="$R/$rd/build.log"
  kill -s "$sig" -- "-$(cat "$STUB/pid.$name")"
  wait_for "$STUB/rc.$name"
  expect "group $sig ($name): exit status" "$(cat "$STUB/rc.$name")" "$want"
  check "group $sig ($name): Packer's cancellation output is in build.log" grep -qx "stub packer $name cancelled" "$log"
  check "group $sig ($name): the key is deleted" [ ! -e "$R/$rd/build_key" ]
  check "group $sig ($name): the galaxy install is deleted" [ ! -e "$R/$rd/galaxy" ]
  if [ "$want" = 2 ]; then
    check "group $sig ($name): the leak is reported in build.log" grep -qF "FATAL: API token found in $R/$rd/packer-debug.log" "$log"
  fi
  expect "group $sig ($name): the build.log tee ignores INT, TERM and HUP" \
    "$(ignored "$(cat "$STUB/$name/tee.sigign" 2>/dev/null || echo 0)")" "HUP INT TERM"
}
# ignored <SigIgn hex mask>: which of HUP(1), INT(2), TERM(15) it ignores.
ignored() {
  local m=$((16#$1)) out=() n
  for n in 1:HUP 2:INT 15:TERM; do
    if (( (m >> (${n%%:*} - 1)) & 1 )); then out+=("${n#*:}"); fi
  done
  echo "${out[*]:-none}"
}
group_case group-term TERM 143
group_case group-term-leak TERM 2 STUB_LEAK=1
group_case group-hup HUP 129
group_case group-hup-leak HUP 2 STUB_LEAK=1
# Ctrl-C: SIGINT to the whole group.
group_case group-int INT 130
group_case group-int-leak INT 2 STUB_LEAK=1

# A debug log the leak check cannot read is reported, not taken as clean.
start unreadable STUB_UNREADABLE=1
wait_for "$STUB/started.unreadable"
runu=$(rundir_of "$(cat "$STUB/unreadable/key")")
touch "$STUB/release.unreadable"; wait_for "$STUB/rc.unreadable"
check "an unreadable debug log is reported" \
  grep -qF "warning: cannot read $R/$runu/packer-debug.log to check it for the API token" "$STUB/out.unreadable"

# SAFBOX_DEV=1 keeps the run's key for pre-seal diagnostics, as before.
start dev SAFBOX_DEV=1
wait_for "$STUB/started.dev"
rund=$(rundir_of "$(cat "$STUB/dev/key")")
touch "$STUB/release.dev"; wait_for "$STUB/rc.dev"
expect "a SAFBOX_DEV run exits 0" "$(cat "$STUB/rc.dev")" 0
check "SAFBOX_DEV=1 keeps the run's key" [ -f "$R/$rund/build_key" ]
expect "the newest run is now the SAFBOX_DEV run" "$(readlink "$R/.build/runs/latest" 2>/dev/null || echo none)" "$(basename "$rund")"

# scripts/clone-and-ssh.sh, when the clone's user cannot log in, reads the
# development template's state as the build user with the key of the run
# that built it. With several runs' keys kept it offers each, newest first
# (the template accepts only its own); SAFBOX_BUILD_KEY names one. Stub
# curl answers the Proxmox API calls, stub ssh refuses every login and
# records the build user's keys, stub sleep skips the waits. With
# STUB_BOOT set, the clone's user logs in and the clone's boot ends in that
# state (running; degraded: finished with a failed unit; hang: never
# settles; sshfail: ssh itself fails); a stub validate.sh records whether
# the release gate ran.
cp "$ROOT/scripts/clone-and-ssh.sh" "$R/scripts/clone-and-ssh.sh"
older="$R/.build/runs/20200101T000000Z-aaaaaa"
mkdir -p "$older"; ssh-keygen -q -t rsa -b 2048 -N '' -C older -f "$older/build_key"
mkdir -p "$tmp/cbin"
cat > "$tmp/cbin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url=${a%%\?*} ;; esac; done
case "$url" in
  */clone|*/status/start) echo '{"data":"UPID:stub"}' ;;
  */tasks/*/status) echo '{"data":{"status":"stopped","exitstatus":"OK"}}' ;;
  */agent/network-get-interfaces) echo '{"data":{"result":[{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"192.0.2.50"}]}]}}' ;;
  *) echo '{"data":null}' ;;
esac
EOF
cat > "$tmp/cbin/ssh" <<'EOF'
#!/usr/bin/env bash
keys=() target="" cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) keys+=("$2"); shift 2 ;;
    -o) shift 2 ;;
    *@*) target=$1; shift; cmd="$*"; break ;;
    *) shift ;;
  esac
done
case "$target" in packer@*) printf '%s\n' "${keys[@]}" > "$STUB_DIR/build-user-keys" ;; esac
[ -n "${STUB_BOOT:-}" ] || exit 255
# admin (cloud-init's default user) and safuser, which first boot
# gives the same key.
case "$target" in admin@192.0.2.50|safuser@192.0.2.50) ;; *) exit 255 ;; esac
# STUB_SAFUSER_REFUSED=1: first boot did not make safuser, so it never logs in.
case "$target" in safuser@*) [ "${STUB_SAFUSER_REFUSED:-0}" = 1 ] && exit 255 ;; esac
case "$cmd" in
  *is-system-running*)
    case "$STUB_BOOT" in
      hang) exec /usr/bin/sleep 60 ;;
      sshfail) exit 255 ;;
      running) echo running ;;
      *) echo "$STUB_BOOT"; exit 1 ;;
    esac ;;
  *--failed*) echo 'abc-123.service loaded failed failed [systemd-run] /usr/bin/podman healthcheck run abc' ;;
  *list-jobs*) echo '42 vulcan.service start running' ;;
  *) printf 'ok\nfips_enabled=1\nhostname=safbox-clone-9170\n' ;;
esac
EOF
cat > "$R/scripts/validate.sh" <<'EOF'
#!/bin/sh
echo scanned > "$STUB_DIR/scanned"
EOF
chmod +x "$R/scripts/validate.sh"
printf '#!/bin/sh\nexit 0\n' > "$tmp/cbin/sleep"
chmod +x "$tmp/cbin/curl" "$tmp/cbin/ssh" "$tmp/cbin/sleep"
clone() { # env...
  rm -f "$STUB/build-user-keys"
  env "$@" HOME="$tmp/home" PATH="$tmp/cbin:$PATH" STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$tmp/packer.env" \
    SAFBOX_NODE=node SAFBOX_POOL=pool "$R/scripts/clone-and-ssh.sh" 9000 9170 --keep >"$STUB/clone.out" 2>&1 || true
  cat "$STUB/build-user-keys" 2>/dev/null || echo "build user not tried; clone-and-ssh.sh said: $(tail -3 "$STUB/clone.out")"
}
expect "clone-and-ssh offers every kept run key, newest first" \
  "$(clone)" "$(printf '%s\n' "$R/$rund/build_key" "$older/build_key")"
expect "SAFBOX_BUILD_KEY names the run's key" \
  "$(clone SAFBOX_BUILD_KEY="$older/build_key")" "$older/build_key"

# The release gate runs only once the clone has finished booting. A finished
# boot with failed units (degraded) is scanned, the units listed; a boot that
# never settles within SAFBOX_READY_TIMEOUT fails, naming the queued jobs,
# without a scan. The stub's hang lasts 60 s and each run here is cut at
# 15 s (exit 124), so the hang case passes only if clone-and-ssh.sh
# enforces its own timeout.
boot() { # state [env...]: "<exit status> <scanned|not scanned>"
  local state=$1 rc=0; shift
  rm -f "$STUB/scanned"
  env "$@" STUB_BOOT="$state" HOME="$tmp/home" PATH="$tmp/cbin:$PATH" STUB_DIR="$STUB" SAFBOX_PROXMOX_ENV="$tmp/packer.env" \
    SAFBOX_NODE=node SAFBOX_POOL=pool timeout 15 "$R/scripts/clone-and-ssh.sh" 9000 9170 --keep >"$STUB/clone.out" 2>&1 || rc=$?
  if [ -e "$STUB/scanned" ]; then echo "$rc scanned"; else echo "$rc not scanned"; fi
}
expect "a clone that finished booting is scanned" "$(boot running)" "0 scanned"
check "safuser logs in with the deployer's key before the scan" grep -q 'PASS: safuser logs in' "$STUB/clone.out"
expect "a clone whose boot ends degraded is scanned" "$(boot degraded)" "0 scanned"
check "the failed units are listed" grep -q 'healthcheck' "$STUB/clone.out"
expect "a clone whose boot never settles fails unscanned within SAFBOX_READY_TIMEOUT" "$(boot hang SAFBOX_READY_TIMEOUT=1)" "1 not scanned"
check "the timeout message says it timed out" grep -q 'still booting after 1s' "$STUB/clone.out"
check "the timeout message names the queued job" grep -q 'vulcan.service' "$STUB/clone.out"
expect "a failed ssh while waiting fails unscanned" "$(boot sshfail)" "1 not scanned"
check "the ssh failure is not reported as a timeout" grep -q 'ssh failed (exit 255)' "$STUB/clone.out"
expect "a SAFBOX_READY_TIMEOUT that is not a positive number is refused" "$(boot running SAFBOX_READY_TIMEOUT=10m)" "2 not scanned"
expect "a clone where safuser never logs in fails unscanned" "$(boot running STUB_SAFUSER_REFUSED=1)" "1 not scanned"
check "the failure names safuser" grep -q 'SSH as safuser with the deployer.s key failed' "$STUB/clone.out"

[ "$failures" -eq 0 ] || exit 1
echo "PASS: concurrent build.sh runs keep their own keys, logs and galaxy installs; clone-and-ssh finds them"
