#!/usr/bin/env bash
# Acceptance check for the install layer: clone the template, hand the clone
# a cloud-init user and key, boot it, learn its IP from the guest agent, and
# prove SSH works, as admin (the deployer's key-only account) and, once
# first boot has made it, as safuser, then run the release gate: the box's
# profiles over SSH and the safbox-client profile from here
# (scripts/validate.sh --client).
# Uses only the Proxmox API, so it runs with the same least-privilege token
# as the build. scripts/clone-and-ssh.sh --help lists its arguments,
# environment and files.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
usage: scripts/clone-and-ssh.sh [-h | --help] <template-vmid> <clone-vmid> [--keep]

Clone a SAFBox template through the Proxmox API, give the clone a cloud-init
user and SSH keys, boot it, log in over SSH as that user and as safuser,
and run the release gate (scripts/validate.sh) against it.

Arguments:
  <template-vmid>  the template to clone
  <clone-vmid>     the clone's VM ID, a free one the token may use
  --keep           leave the clone running for a person. Without --keep
                   the clone is destroyed after the gate (only if its
                   description still carries this run's ID).
  -h, --help       print this and exit

Credentials, from the env file (scripts/example.env is its template; copy
it to ~/.config/proxmox/packer.env and chmod 600 it) or the shell, which
wins over the file:
  SAFBOX_PROXMOX_ENV     the env file (default ~/.config/proxmox/packer.env);
                         read when it exists, refused unless its mode is 0600
  PROXMOX_URL            https://<node>:8006/api2/json (required)
  PROXMOX_USERNAME       the API token ID, <user>@pve!<token-name> (required)
  PROXMOX_TOKEN          the API token secret (required; never printed)
  PROXMOX_CA_FILE        the cluster CA trusted for the API (default: the
                         system trust store)

Node and pool come from proxmox_node and proxmox_pool in
packer/local.auto.pkrvars.hcl, the same values the build uses. The pool
is the one the clone joins: the token's VM.Allocate on /pool/<name>
authorizes it.

Environment, set in the shell (SAFBOX_NODE=... scripts/clone-and-ssh.sh):
  SAFBOX_NODE            the node holding the template, instead of
                         proxmox_node
  SAFBOX_POOL            the pool the clone joins, instead of proxmox_pool
  SAFBOX_INSECURE_TLS    1 turns off TLS verification, for a throwaway lab's
                         self-signed certificate (default 0)
  SAFBOX_CLONE_USER      cloud-init's user, ciuser (default admin); a site
                         inputs file must then name it as admin_user
  SAFBOX_CLONE_PASSWORD  cipassword, which first boot gives safuser, never
                         admin: an 'openssl passwd -6' hash, since Proxmox
                         hashes a plain one with SHA-256 (default: none, and
                         first boot generates safuser's password)
  SAFBOX_SSH_KEY         the private key admin gets (default
                         .build/clone_key; RSA 4096, made if missing)
  SAFBOX_EXTRA_SSH_KEYS  more public key files for admin (and safuser),
                         colon-separated, after every .build/keys/*.pub;
                         ECDSA or RSA of at least 2048 bits, since the
                         clone's FIPS-mode sshd refuses Ed25519; any other
                         key fails the run with 2 before the clone is made
                         (default: none)
  SAFBOX_READY_TIMEOUT   seconds to wait for the clone to finish booting
                         before the release gate (default 600)
  SAFBOX_SKIP_VALIDATE   1 stops after the first SSH check, before the wait
                         and the release gate (default 0)
  SAFBOX_SITE_INPUTS     a site's inputs file for the release gate
                         (validate.sh --site-inputs; default: none)
  SAFBOX_SSH_CONFIG      the SSH client config CINC Auditor reads instead of
                         its defaults, /dev/null for none (validate.sh
                         --ssh-config; default: its defaults)

Files (.build/ is the one in the checkout this script runs from; run from a
git worktree, that worktree's):
  packer/*.auto.pkrvars.hcl  the build's site settings: proxmox_node and
                             proxmox_pool are read from here
  .build/clone_key           the default SSH key, made if missing
  .build/keys/*.pub          extra public keys every clone's admin gets

Guide: docs/guides/proxmox/build.md
USAGE
}

KEEP="" ARGS=()
for a in "$@"; do
  case "$a" in
    -h | --help) usage; exit 0 ;;
    --keep) KEEP=--keep ;;
    -*) echo "unknown option $a; see scripts/clone-and-ssh.sh --help" >&2; exit 2 ;;
    *) ARGS+=("$a") ;;
  esac
done
if [ ${#ARGS[@]} -ne 2 ]; then
  echo "usage: scripts/clone-and-ssh.sh <template-vmid> <clone-vmid> [--keep]; see --help" >&2
  exit 2
fi
TEMPLATE_ID=${ARGS[0]}
CLONE_ID=${ARGS[1]}

load_env
: "${PROXMOX_URL:?}" "${PROXMOX_USERNAME:?}" "${PROXMOX_TOKEN:?}"
READY_TIMEOUT=${SAFBOX_READY_TIMEOUT:-600}
case "$READY_TIMEOUT" in
  '' | *[!0-9]* | 0*) echo "SAFBOX_READY_TIMEOUT must be a positive whole number of seconds, not '$READY_TIMEOUT'" >&2; exit 2 ;;
esac
# Node and pool are set once, in the Packer variables file; the shell may
# override them for one run.
NODE=${SAFBOX_NODE:-$(site_var proxmox_node)}
POOL=${SAFBOX_POOL:-$(site_var proxmox_pool)}
: "${NODE:?set proxmox_node in packer/local.auto.pkrvars.hcl}" "${POOL:?set proxmox_pool in packer/local.auto.pkrvars.hcl}"
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
umask 077
# The API's curl and its token file (scripts/lib.sh), removed on exit.
api_curl
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
      rm -rf "$CURLCFG"; return
    fi
    echo "destroying clone $CLONE_ID (run $RUN_ID)"
    u=$("${CURL[@]}" -X POST "$API/nodes/$NODE/qemu/$CLONE_ID/status/stop" | jq -r .data) && wait_task "$u" || echo "stop failed; not deleting a running VM" >&2
    # Proxmox removes ACLs on /vms/<id> on every destroy; purge is unrelated
    # to that and is never used here.
    u=$("${CURL[@]}" -X DELETE "$API/nodes/$NODE/qemu/$CLONE_ID?destroy-unreferenced-disks=1" | jq -r .data) && wait_task "$u" || echo "destroy failed; clone $CLONE_ID left in place" >&2
  fi
  rm -rf "$CURLCFG"
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
    # Release gate: the box's profiles over SSH and the client profile from
    # here, against what a consumer receives, after first boot.
    site=()
    if [ -n "${SAFBOX_SITE_INPUTS:-}" ]; then site+=(--site-inputs "$SAFBOX_SITE_INPUTS"); fi
    if [ -n "${SAFBOX_SSH_CONFIG:-}" ]; then site+=(--ssh-config "$SAFBOX_SSH_CONFIG"); fi
    "$ROOT/scripts/validate.sh" ${site[@]+"${site[@]}"} --client \
      "$USER_NAME@$ip" "$KEY" release "clone-$CLONE_ID"
    exit 0
  fi
  sleep 5
done
echo "FAIL: SSH to $ip as $USER_NAME never succeeded" >&2
exit 1
