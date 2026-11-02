#!/usr/bin/env bash
# Delete one VM or template, with its disks, after the operator types its
# ID: a failed build's kept VM, a clone kept with --keep, an old template.
# Uses only the Proxmox API and the build's token. It cannot be undone.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
usage: scripts/delete-vm.sh [-h | --help] <vmid>

Show the VM's name, node and whether it is a template, ask you to type its
ID, then stop it if it runs and delete it with its disks (purge: also from
backup, replication and HA jobs). Exit 0 deleted, 2 usage, anything else
not deleted or not finished (check the VM in the Proxmox UI).

From the env file, as for scripts/build.sh:
  PROXMOX_URL, PROXMOX_USERNAME, PROXMOX_TOKEN   the API and its token
  PROXMOX_CA_FILE        the cluster CA trusted for the API

Environment, set in the shell (SAFBOX_PROTECTED_IDS=... scripts/delete-vm.sh):
  SAFBOX_PROXMOX_ENV     the env file (default ~/.config/proxmox/packer.env)
  SAFBOX_INSECURE_TLS    1 turns off TLS verification, as for the clone test
  SAFBOX_PROTECTED_IDS   VM IDs this script refuses to delete, separated
                         by spaces or commas (default: none)

Guide: docs/guides/proxmox/build.md
USAGE
}

case "${1:-}" in -h | --help) usage; exit 0 ;; esac
if [ $# -ne 1 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: scripts/delete-vm.sh <vmid>; see --help" >&2
  exit 2
fi
ID=$1

load_env
: "${PROXMOX_URL:?}" "${PROXMOX_USERNAME:?}" "${PROXMOX_TOKEN:?}"
PROTECTED=${SAFBOX_PROTECTED_IDS:-}
for p in ${PROTECTED//,/ }; do
  [ "$p" != "$ID" ] || { echo "refusing VM $ID: it is in SAFBOX_PROTECTED_IDS" >&2; exit 1; }
done

api_curl
trap 'rm -f "$CURLCFG"' EXIT
API=$PROXMOX_URL

# Find the VM among those the token can see, on any node; type=vm also
# lists containers, which this script does not handle.
vm=$("${CURL[@]}" "$API/cluster/resources?type=vm" | jq -c --argjson id "$ID" '.data[] | select(.vmid == $id and .type == "qemu")')
if [ -z "$vm" ]; then
  echo "no VM $ID that this token can see; nothing was deleted" >&2
  exit 1
fi
NODE=$(jq -r .node <<<"$vm")
NAME=$(jq -r '.name // "(no name)"' <<<"$vm")
KIND=VM
[ "$(jq -r '.template // 0' <<<"$vm")" != 1 ] || KIND=template

wait_task() { # upid: wait for a Proxmox task, then fail unless it ended OK
  local status
  if [ -z "$1" ] || [ "$1" = null ]; then echo "no task ID returned (request refused?)" >&2; return 1; fi
  while status=$("${CURL[@]}" "$API/nodes/$NODE/tasks/$1/status") &&
    [ "$(jq -r .data.status <<<"$status")" = running ]; do sleep 2; done
  [ "$(jq -r .data.exitstatus <<<"$status")" = OK ] || { echo "task $1 failed: $(jq -r .data.exitstatus <<<"$status")" >&2; return 1; }
}

echo "This deletes $KIND $ID ($NAME) on node $NODE, with its disks. It cannot be undone."
read -r -p "Type $ID to delete it: " answer
[ "$answer" = "$ID" ] || { echo "not confirmed; nothing was deleted" >&2; exit 1; }

if [ "$(jq -r .status <<<"$vm")" = running ]; then
  echo "stopping $ID"
  wait_task "$("${CURL[@]}" -X POST "$API/nodes/$NODE/qemu/$ID/status/stop" | jq -r .data)" ||
    { echo "VM $ID did not stop; nothing was deleted" >&2; exit 1; }
fi
wait_task "$("${CURL[@]}" -X DELETE "$API/nodes/$NODE/qemu/$ID?purge=1&destroy-unreferenced-disks=1" | jq -r .data)" ||
  { echo "deleting VM $ID did not finish OK; check it in the Proxmox UI" >&2; exit 1; }
echo "deleted $KIND $ID ($NAME) from node $NODE"
