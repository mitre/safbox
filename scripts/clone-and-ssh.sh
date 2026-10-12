#!/usr/bin/env bash
# Acceptance check for the install layer: clone the template, hand the clone
# a cloud-init user and key, boot it, learn its IP from the guest agent, and
# prove SSH works. Uses only the Proxmox API, so it runs with the same
# least-privilege token as the build.
#
#   scripts/clone-and-ssh.sh <template-vmid> <clone-vmid> [--keep]
#
# Env: PROXMOX_URL, PROXMOX_USERNAME, PROXMOX_TOKEN (or the env file),
#      SAFBOX_NODE (node holding the template), SAFBOX_POOL (resource pool the
#      clone joins; authorizes the clone via VM.Allocate on /pool/<name>, which
#      survives VM destruction, unlike an ACL on /vms/<id>), SAFBOX_SSH_KEY
#      (private key; default .build/clone_key, RSA because the clone is FIPS).
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
NODE=$SAFBOX_NODE
POOL=$SAFBOX_POOL
USER_NAME=${SAFBOX_CLONE_USER:-safbox}
KEY=${SAFBOX_SSH_KEY:-$ROOT/.build/clone_key}
if [ ! -f "$KEY" ]; then
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -q -t rsa -b 4096 -N '' -C safbox-clone -f "$KEY"
fi
PUB=$(cat "$KEY.pub")
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

echo "waiting for SSH as $USER_NAME (first boot runs cloud-init; allow several minutes on small hosts)"
for _ in $(seq 1 72); do
  if out=$(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        "$USER_NAME@$ip" 'echo ok; echo "fips_enabled=$(cat /proc/sys/crypto/fips_enabled)"; echo "hostname=$(hostnamectl --static)"; sudo -n cloud-init status 2>/dev/null || echo "cloud-init status unavailable to this user"' 2>/dev/null); then
    echo "$out"
    # SSH alone is not enough: the clone must be a FIPS system with cloud-init's hostname.
    echo "$out" | grep -q '^fips_enabled=1$' || { echo "FAIL: clone is not in FIPS mode" >&2; exit 1; }
    echo "$out" | grep -q "^hostname=safbox-clone-$CLONE_ID\$" || { echo "FAIL: cloud-init did not set the clone's hostname" >&2; exit 1; }
    echo "PASS: clone $CLONE_ID reachable over SSH with the cloud-init user, FIPS on"
    # Release gate: the same validation profile the build ran, now from
    # outside against what a consumer receives, after first boot.
    if [ "${SAFBOX_SKIP_VALIDATE:-0}" != 1 ]; then
      "$ROOT/scripts/validate.sh" "$USER_NAME@$ip" "$KEY" "clone-$CLONE_ID" firstboot_completed_expected=true
    fi
    exit 0
  fi
  sleep 5
done
echo "FAIL: SSH to $ip as $USER_NAME never succeeded" >&2
# Development aid: before the seal step exists, the template still carries the
# build user and the ephemeral build key, so cloud-init's own view can be read.
BUILD_KEY="$ROOT/.build/build_key"
if [ -f "$BUILD_KEY" ]; then
  echo "--- diagnostics via build user (pre-seal templates only)" >&2
  ssh -i "$BUILD_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    "${SAFBOX_BUILD_USER:-packer}@$ip" \
    'cloud-init status --long 2>&1 | head -6; echo "--- id"; id '"$USER_NAME"' 2>&1; echo "--- cloud-init errors"; sudo -n grep -iE "error|traceback|warn" /var/log/cloud-init.log 2>/dev/null | tail -8' >&2 || true
fi
exit 1
