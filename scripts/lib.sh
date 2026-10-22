# shellcheck shell=bash
# Shared by scripts/build.sh and scripts/clone-and-ssh.sh: ROOT, the
# checkout these scripts belong to, and load_env, which reads the Proxmox
# credentials file into the environment.
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
