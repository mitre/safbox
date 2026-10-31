# shellcheck shell=bash
# Shared by scripts/build.sh and scripts/clone-and-ssh.sh: ROOT, the
# checkout these scripts belong to; load_env, which reads the Proxmox
# credentials file into the environment; api_curl, the curl command for the
# Proxmox API; and pick_vmid, which finds a free VM ID in a configured range.
# shellcheck disable=SC2034 # used by the scripts that source this file
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# load_env: SAFBOX_PROXMOX_ENV, or ~/.config/proxmox/packer.env, when it
# exists. It holds the API token, so a file anyone but its owner can read
# is refused rather than used. GNU stat first: GNU stat takes BSD's -f as
# "filesystem status" and prints a report before failing, which would turn
# a correct 0600 file into a refusal on Linux.
load_env() {
  ENV_FILE="${SAFBOX_PROXMOX_ENV:-$HOME/.config/proxmox/packer.env}"
  [ -f "$ENV_FILE" ] || return 0
  local perm
  perm=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")
  [ "$perm" = 600 ] || { echo "refusing $ENV_FILE: mode $perm, must be 600" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

# api_curl: CURL, the curl command for the Proxmox API, and CURLCFG, the
# file holding its token; the caller removes CURLCFG when done. The token
# never appears on a command line (visible in ps and /proc): curl reads it
# from that 0600 file. TLS verification stays on: the CA is SAFBOX_CA_FILE,
# else SSL_CERT_FILE (the one Packer trusts), else the system's; only
# SAFBOX_INSECURE_TLS=1, for a self-signed lab certificate, turns it off.
api_curl() {
  local ca=${SAFBOX_CA_FILE:-${SSL_CERT_FILE:-}}
  CURLCFG=$(umask 077 && mktemp)
  printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PROXMOX_USERNAME" "$PROXMOX_TOKEN" > "$CURLCFG"
  CURL=(curl -fsS -K "$CURLCFG")
  if [ -n "$ca" ]; then CURL+=(--cacert "$ca"); fi
  if [ "${SAFBOX_INSECURE_TLS:-0}" = 1 ]; then CURL+=(-k); fi
}

# pick_vmid VAR: the first ID in the range the variable VAR holds
# (FIRST-LAST) that no VM or template in the cluster holds, in PICKED, and
# why, in PICK_NOTE. Needs api_curl. VM IDs are cluster-wide, so the
# question goes to /cluster/nextid, which answers from the cluster's own
# list whatever the token may see; a VM listing would show only the VMs the
# token may audit, and an ID held outside the pool would look free. A
# malformed range, a full one or an API that does not answer returns 1 with
# the reason on stderr; a full range lists what holds it, as far as the
# token can see. Two runs picking at once can choose the same ID: the
# second one's create then fails.
pick_vmid() {
  local var=$1 range=${!1:-} first last id code vms line taken=()
  PICKED="" PICK_NOTE=""
  # No leading zero, so bash never reads an ID as octal.
  if ! [[ $range =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
    echo "$var=$range is not a range: give FIRST-LAST, such as 1000-1009" >&2
    return 1
  fi
  first=${BASH_REMATCH[1]} last=${BASH_REMATCH[2]}
  # Proxmox takes VM IDs from 100 to 999999999.
  if [ "$first" -lt 100 ] || [ "$last" -gt 999999999 ] || [ "$first" -gt "$last" ]; then
    echo "$var=$range is not a range of VM IDs: FIRST <= LAST, both between 100 and 999999999" >&2
    return 1
  fi
  for ((id = first; id <= last; id++)); do
    # 200 names the ID free, 400 says a VM already has it.
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$PROXMOX_URL/cluster/nextid?vmid=$id" 2>/dev/null) || true
    case "$code" in
      200) PICKED=$id; break ;;
      400) taken+=("$id") ;;
      *) echo "cannot ask the Proxmox API whether VM ID $id is free (HTTP ${code:-no answer} from $PROXMOX_URL)" >&2; return 1 ;;
    esac
  done
  if [ -n "$PICKED" ]; then
    PICK_NOTE="VM ID $PICKED: the first free ID in $var=$range"
    if [ ${#taken[@]} -gt 0 ]; then PICK_NOTE+=" (in use: ${taken[*]})"; fi
    return 0
  fi
  vms=$("${CURL[@]}" "$PROXMOX_URL/cluster/resources?type=vm" 2>/dev/null) || vms='{}'
  echo "$var=$range is full; every ID in it is in use:" >&2
  for id in "${taken[@]}"; do
    line=$(jq -r --argjson id "$id" 'first(.data[]? | select(.vmid == $id)
      | "\(.name // "unnamed") (\(if .template == 1 then "template" else "VM" end) on \(.node))") // empty' <<<"$vms" 2>/dev/null) || line=""
    echo "  $id ${line:-(not visible to this token)}" >&2
  done
  return 1
}
