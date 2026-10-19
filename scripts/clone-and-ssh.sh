#!/usr/bin/env bash
# Acceptance check for the install layer: clone the template, hand the clone
# a cloud-init user and key, boot it, learn its IP from the guest agent, and
# prove SSH works, as admin (the deployer's key-only account) and, once
# first boot has made it, as safuser. Uses only the Proxmox API, so it runs
# with the same least-privilege token as the build.
#
#   scripts/clone-and-ssh.sh <template-vmid> <clone-vmid> [--keep]
#
# Env: PROXMOX_URL, PROXMOX_USERNAME, PROXMOX_TOKEN (or the env file),
#      SAFBOX_NODE (node holding the template), SAFBOX_POOL (resource pool the
#      clone joins; authorizes the clone via VM.Allocate on /pool/<name>, which
#      survives VM destruction, unlike an ACL on /vms/<id>), SAFBOX_SSH_KEY
#      (private key; default .build/clone_key, RSA because the clone is FIPS;
#      made if missing),
#      SAFBOX_EXTRA_SSH_KEYS (optional: public key files, colon-separated,
#      whose keys admin also gets, after the build key and every *.pub in
#      .build/keys/; ECDSA or RSA of at least 2048 bits, since the clone's
#      FIPS-mode sshd refuses Ed25519; any other key fails the run with 2
#      before the clone is made). .build/ is the one in the checkout this
#      script runs from: run from a worktree, it makes and uses that
#      worktree's own clone_key and reads no keys from the main checkout's
#      .build/keys/; point SAFBOX_SSH_KEY and SAFBOX_EXTRA_SSH_KEYS there
#      to use them.
#      SAFBOX_BUILD_KEY (optional: when SSH fails on a development template,
#      the build key of the run that built it, .build/runs/<run id>/build_key,
#      kept by SAFBOX_DEV=1; default: every kept run key, newest first),
#      SAFBOX_SITE_INPUTS (optional: a site's inputs file for the release
#      gate, validate.sh --site-inputs), SAFBOX_SSH_CONFIG
#      (optional: the SSH client config CINC Auditor reads instead of its
#      defaults, /dev/null for none; validate.sh --ssh-config),
#      SAFBOX_READY_TIMEOUT (seconds to wait for the clone to finish
#      booting before the release gate; default 600),
#      SAFBOX_CLONE_USER (cloud-init's ciuser, its default user; default
#      admin), SAFBOX_CLONE_PASSWORD (optional: cipassword, which first
#      boot gives safuser, never admin; an 'openssl passwd -6' hash, since
#      Proxmox hashes a plain one with SHA-256; without it first boot
#      generates safuser's password).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE_ID=${1:?template vmid}
CLONE_ID=${2:?clone vmid}
KEEP=${3:-}

ENV_FILE="${SAFBOX_PROXMOX_ENV:-$HOME/.config/proxmox/packer.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
: "${PROXMOX_URL:?}" "${PROXMOX_USERNAME:?}" "${PROXMOX_TOKEN:?}" "${SAFBOX_NODE:?set SAFBOX_NODE}" "${SAFBOX_POOL:?set SAFBOX_POOL}"
READY_TIMEOUT=${SAFBOX_READY_TIMEOUT:-600}
case "$READY_TIMEOUT" in
  '' | *[!0-9]* | 0*) echo "SAFBOX_READY_TIMEOUT must be a positive whole number of seconds, not '$READY_TIMEOUT'" >&2; exit 2 ;;
esac
NODE=$SAFBOX_NODE
POOL=$SAFBOX_POOL
USER_NAME=${SAFBOX_CLONE_USER:-admin}
KEY=${SAFBOX_SSH_KEY:-$ROOT/.build/clone_key}
if [ ! -f "$KEY" ]; then
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -q -t rsa -b 4096 -N '' -C safbox-clone -f "$KEY"
fi
PUB=$(cat "$KEY.pub")
# Extra public keys for the clone's admin (first boot gives safuser the
# same keys): every *.pub in this checkout's .build/keys/, then every file
# SAFBOX_EXTRA_SSH_KEYS names, colon-separated. SAFBox's FIPS-mode sshd
# accepts only ECDSA and RSA keys (sshd -T on a clone: PubkeyAcceptedAlgorithms
# ecdsa-sha2-nistp256/384/521 and rsa-sha2-256/512, RequiredRSASize 2048),
# so any other key, Ed25519 included, stops the run before any API call:
# the clone would never accept it.
ACCEPTED='ECDSA (nistp256, nistp384, nistp521) or RSA of at least 2048 bits'
refuse_key() { # file reason
  echo "refusing extra SSH key file $1: $2. SAFBox's FIPS-mode sshd accepts only these keys: $ACCEPTED; make one with 'ssh-keygen -t ecdsa -b 384' or 'ssh-keygen -t rsa -b 4096'" >&2
  exit 2
}
EXTRA_FILES=()
for f in "$ROOT"/.build/keys/*.pub; do
  if [ -e "$f" ]; then EXTRA_FILES+=("$f"); fi
done
IFS=: read -r -a NAMED <<<"${SAFBOX_EXTRA_SSH_KEYS:-}"
for f in ${NAMED[@]+"${NAMED[@]}"}; do
  if [ -n "$f" ]; then EXTRA_FILES+=("$f"); fi
done
for f in ${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then refuse_key "$f" "not a readable file"; fi
  n=0 keys=0
  # One key per line, as in authorized_keys; blank and # lines are skipped.
  # A line that is not a public key (a private key's, say) is never printed.
  mapfile -t LINES < "$f"
  for raw in ${LINES[@]+"${LINES[@]}"}; do
    n=$((n + 1))
    read -r line <<<"$raw" || true   # trims surrounding blanks
    case "$line" in '' | '#'*) continue ;; esac
    fp=$(ssh-keygen -l -f - <<<"$line" 2>/dev/null) || refuse_key "$f" "line $n is not a public key"
    bits=${fp%% *} type=${fp##* }
    case "$type" in
      '(ECDSA)') ;;
      '(RSA)') [ "$bits" -ge 2048 ] || refuse_key "$f" "line $n is an RSA key of $bits bits" ;;
      *) type=${type#(}; refuse_key "$f" "line $n holds a key of type ${type%)}" ;;
    esac
    PUB+=$'\n'"$line"
    keys=$((keys + 1))
  done
  [ "$keys" -gt 0 ] || refuse_key "$f" "it holds no public key"
  echo "extra SSH key for $USER_NAME: $f"
done
# TLS verification stays on unless the caller opts out for a self-signed lab
# API certificate (mirrors Packer's proxmox_insecure_skip_tls_verify).
# The token never appears on a command line (visible in ps and /proc); curl
# reads it from a 0600 config file that is removed on exit.
umask 077
CURLCFG=$(mktemp)
printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PROXMOX_USERNAME" "$PROXMOX_TOKEN" > "$CURLCFG"
CURL=(curl -fsS -K "$CURLCFG")
if [ -n "${SAFBOX_CA_FILE:-}" ]; then CURL+=(--cacert "$SAFBOX_CA_FILE"); fi
if [ "${SAFBOX_INSECURE_TLS:-0}" = 1 ]; then CURL+=(-k); fi
API=$PROXMOX_URL

wait_task() { # upid
  local upid=$1 status
  if [ -z "$upid" ] || [ "$upid" = null ]; then
    echo "no task id returned (request refused?)" >&2
    return 1
  fi
  while :; do
    status=$("${CURL[@]}" "$API/nodes/$NODE/tasks/$upid/status" | jq -r '.data.status')
    [ "$status" = running ] || break
    sleep 2
  done
  local exit; exit=$("${CURL[@]}" "$API/nodes/$NODE/tasks/$upid/status" | jq -r '.data.exitstatus')
  [ "$exit" = OK ] || { echo "task $upid failed: $exit" >&2; return 1; }
}

# Every run gets a unique ID that is written into the clone's description at
# creation. Cleanup destroys a VM only if (a) this run created it and (b) the
# VM's own description still carries this run ID, so a pre-existing VM with
# the same number, or one replaced mid-run, is never touched.
RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
RUN_MARK="safbox-clone-test run=$RUN_ID"
CREATED=0
# Runs from the EXIT trap; shellcheck cannot see trap call sites and its wiki
# says to ignore SC2317 for exactly this case.
# shellcheck disable=SC2317,SC2329
cleanup() {
  if [ "$CREATED" = 1 ] && [ "$KEEP" != --keep ]; then
    desc=$("${CURL[@]}" "$API/nodes/$NODE/qemu/$CLONE_ID/config" 2>/dev/null | jq -r '.data.description // ""')
    if [ "$desc" != "$RUN_MARK" ]; then
      echo "refusing to destroy VM $CLONE_ID: its description does not match this run ($RUN_ID)" >&2
      rm -f "$CURLCFG"; return
    fi
    echo "destroying clone $CLONE_ID (run $RUN_ID)"
    u=$("${CURL[@]}" -X POST "$API/nodes/$NODE/qemu/$CLONE_ID/status/stop" | jq -r .data) && wait_task "$u" || echo "stop failed; not deleting a running VM" >&2
    # Proxmox removes ACLs on /vms/<id> on every destroy; purge is unrelated
    # to that and is never used here.
    u=$("${CURL[@]}" -X DELETE "$API/nodes/$NODE/qemu/$CLONE_ID?destroy-unreferenced-disks=1" | jq -r .data) && wait_task "$u" || echo "destroy failed; clone $CLONE_ID left in place" >&2
  fi
  rm -f "$CURLCFG"
}
trap cleanup EXIT

echo "cloning $TEMPLATE_ID -> $CLONE_ID on $NODE (run $RUN_ID)"
upid=$("${CURL[@]}" -X POST "$API/nodes/$NODE/qemu/$TEMPLATE_ID/clone" \
  --data-urlencode "newid=$CLONE_ID" --data-urlencode "name=safbox-clone-$CLONE_ID" --data-urlencode "full=1" --data-urlencode "pool=$POOL" \
  --data-urlencode "description=$RUN_MARK" | jq -r .data)
wait_task "$upid"
CREATED=1

echo "configuring cloud-init"
"${CURL[@]}" -X PUT "$API/nodes/$NODE/qemu/$CLONE_ID/config" \
  --data-urlencode "ciuser=$USER_NAME" \
  --data-urlencode "sshkeys=$(printf '%s' "$PUB" | jq -sRr @uri)" \
  --data-urlencode "ipconfig0=ip=dhcp" \
  --data-urlencode "ciupgrade=0" >/dev/null   # no first-boot dnf upgrade (qemu-server >= 8.1)
if [ -n "${SAFBOX_CLONE_PASSWORD:-}" ]; then
  "${CURL[@]}" -X PUT "$API/nodes/$NODE/qemu/$CLONE_ID/config" \
    --data-urlencode "cipassword=$SAFBOX_CLONE_PASSWORD" >/dev/null
fi

echo "starting"
upid=$("${CURL[@]}" -X POST "$API/nodes/$NODE/qemu/$CLONE_ID/status/start" | jq -r .data)
wait_task "$upid"

echo "waiting for guest agent and an IPv4 address"
ip=""
for _ in $(seq 1 90); do
  ip=$("${CURL[@]}" "$API/nodes/$NODE/qemu/$CLONE_ID/agent/network-get-interfaces" 2>/dev/null \
    | jq -r '.data.result[]? | select(.name != "lo") | .["ip-addresses"][]? | select(.["ip-address-type"]=="ipv4") | .["ip-address"] | select(startswith("169.254.") | not) | select(startswith("10.88.") | not)' | head -1 || true)
  [ -n "$ip" ] && break
  sleep 5
done
[ -n "$ip" ] || { echo "no IP from guest agent" >&2; exit 1; }
echo "clone IP: $ip"

# LogLevel=ERROR keeps ssh's own warnings and the login banner out of the
# output; only the remote commands' output is shown.
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
echo "waiting for SSH as $USER_NAME (first boot runs cloud-init; allow several minutes on small hosts)"
for _ in $(seq 1 72); do
  if out=$(ssh "${SSH_OPTS[@]}" "$USER_NAME@$ip" 'echo ok; echo "fips_enabled=$(cat /proc/sys/crypto/fips_enabled)"; echo "hostname=$(hostnamectl --static)"; sudo -n cloud-init status 2>/dev/null || echo "cloud-init status unavailable to this user"' 2>/dev/null); then
    echo "$out"
    # SSH alone is not enough: the clone must be a FIPS system with cloud-init's hostname.
    echo "$out" | grep -q '^fips_enabled=1$' || { echo "FAIL: clone is not in FIPS mode" >&2; exit 1; }
    echo "$out" | grep -q "^hostname=safbox-clone-$CLONE_ID\$" || { echo "FAIL: cloud-init did not set the clone's hostname" >&2; exit 1; }
    echo "PASS: clone $CLONE_ID reachable over SSH with the cloud-init user, FIPS on"
    if [ "${SAFBOX_SKIP_VALIDATE:-0}" = 1 ]; then exit 0; fi
    # SSH answers before first boot has finished: the secrets, the pods and
    # the proxy come later. Wait until the boot's job queue has settled; a
    # switched-off service has no units, so it neither holds this up nor
    # fails it. "degraded" is a finished boot too: a podman healthcheck that
    # fails while its container is still starting leaves a failed transient
    # unit. The scan judges the services; the failed units are listed here.
    echo "waiting up to ${READY_TIMEOUT}s for the clone to finish booting (first boot, pods, proxy)"
    rc=0
    state=$(timeout "$READY_TIMEOUT" ssh "${SSH_OPTS[@]}" "$USER_NAME@$ip" 'systemctl is-system-running --wait' 2>/dev/null) || rc=$?
    case "$state" in
      running) echo "clone $CLONE_ID finished booting" ;;
      degraded)
        echo "clone $CLONE_ID finished booting with failed units:"
        timeout 30 ssh "${SSH_OPTS[@]}" "$USER_NAME@$ip" 'systemctl --failed --plain --no-legend' 2>/dev/null || true ;;
      *)
        if [ "$rc" = 124 ]; then
          echo "FAIL: clone $CLONE_ID still booting after ${READY_TIMEOUT}s (SAFBOX_READY_TIMEOUT); jobs still queued:" >&2
        elif [ -z "$state" ]; then
          echo "FAIL: clone $CLONE_ID: ssh failed (exit $rc) while waiting for the boot to finish; jobs still queued:" >&2
        else
          echo "FAIL: clone $CLONE_ID ended its boot in state '$state'; jobs still queued:" >&2
        fi
        timeout 30 ssh "${SSH_OPTS[@]}" "$USER_NAME@$ip" 'systemctl list-jobs --plain --no-legend' >&2 2>/dev/null || true
        exit 1 ;;
    esac
    # First boot gives safuser the deployer's key.
    if ! timeout 30 ssh "${SSH_OPTS[@]}" "safuser@$ip" true 2>/dev/null; then
      echo "FAIL: clone $CLONE_ID: SSH as safuser with the deployer's key failed" >&2
      exit 1
    fi
    echo "PASS: safuser logs in with the deployer's key"
    # Release gate: both profiles, from outside, against what a consumer
    # receives, after first boot.
    site=()
    if [ -n "${SAFBOX_SITE_INPUTS:-}" ]; then site+=(--site-inputs "$SAFBOX_SITE_INPUTS"); fi
    if [ -n "${SAFBOX_SSH_CONFIG:-}" ]; then site+=(--ssh-config "$SAFBOX_SSH_CONFIG"); fi
    "$ROOT/scripts/validate.sh" ${site[@]+"${site[@]}"} "$USER_NAME@$ip" "$KEY" release "clone-$CLONE_ID"
    exit 0
  fi
  sleep 5
done
echo "FAIL: SSH to $ip as $USER_NAME never succeeded" >&2
# Development aid: a development template (seal = false) still carries the
# build user, and a build run with SAFBOX_DEV=1 keeps its ephemeral key in its
# own run directory, so cloud-init's own view can be read. SAFBOX_BUILD_KEY
# names the key of the run that built this template; without it every kept
# run key is offered, newest first, and the template accepts only its own.
BUILD_KEYS=()
if [ -n "${SAFBOX_BUILD_KEY:-}" ]; then
  BUILD_KEYS=("$SAFBOX_BUILD_KEY")
  [ -f "$SAFBOX_BUILD_KEY" ] || echo "SAFBOX_BUILD_KEY $SAFBOX_BUILD_KEY not found; no build-user diagnostics" >&2
else
  for k in "$ROOT"/.build/runs/*/build_key; do
    # runs/latest is a link to one of the others.
    case "$k" in */runs/latest/build_key) continue ;; esac
    if [ -f "$k" ]; then BUILD_KEYS=("$k" ${BUILD_KEYS[@]+"${BUILD_KEYS[@]}"}); fi
  done
fi
ID_ARGS=()
for k in ${BUILD_KEYS[@]+"${BUILD_KEYS[@]}"}; do
  if [ -f "$k" ]; then ID_ARGS+=(-i "$k"); fi
done
if [ ${#ID_ARGS[@]} -gt 0 ]; then
  echo "--- diagnostics via build user (development templates only)" >&2
  ssh "${ID_ARGS[@]}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    "${SAFBOX_BUILD_USER:-packer}@$ip" \
    'cloud-init status --long 2>&1 | head -6; echo "--- id"; id '"$USER_NAME"' 2>&1; echo "--- cloud-init errors"; sudo -n grep -iE "error|traceback|warn" /var/log/cloud-init.log 2>/dev/null | tail -8' >&2 || true
fi
exit 1
