# shellcheck shell=bash
# Shared by scripts/build.sh and scripts/clone-and-ssh.sh: ROOT, the
# checkout these scripts belong to; load_env, which reads the Proxmox
# credentials file into the environment; site_var, which reads one site
# setting from the Packer variables file; and api_curl, the curl command
# for the Proxmox API.
# shellcheck disable=SC2034 # used by the scripts that source this file
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# load_env: SAFBOX_PROXMOX_ENV, or ~/.config/proxmox/packer.env, when it
# exists. It holds the API token, so a file anyone but its owner can read
# is refused rather than used. GNU stat first: GNU stat takes BSD's -f as
# "filesystem status" and prints a report before failing, which would turn
# a correct 0600 file into a refusal on Linux. A variable already set in
# the environment (VAR=value scripts/...) wins over the file: the
# environment is noted before the file is read and put back after it.
load_env() {
  ENV_FILE="${SAFBOX_PROXMOX_ENV:-$HOME/.config/proxmox/packer.env}"
  if [ -f "$ENV_FILE" ]; then
    local perm _n _i _names=() _values=()
    perm=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")
    [ "$perm" = 600 ] || { echo "refusing $ENV_FILE: mode $perm, must be 600" >&2; exit 1; }
    for _n in $(compgen -e); do _names+=("$_n"); _values+=("${!_n}"); done
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    for _i in "${!_names[@]}"; do
      _n=${_names[_i]}
      [ "${!_n-}" = "${_values[_i]}" ] || printf -v "$_n" '%s' "${_values[_i]}"
    done
    warn_old_names
  fi
  # One CA for everything: the scripts' API calls use PROXMOX_CA_FILE and
  # Packer reads SSL_CERT_FILE, so Packer gets the same file. The two older
  # names still work until the env file is updated.
  PROXMOX_CA_FILE=${PROXMOX_CA_FILE:-${SAFBOX_CA_FILE:-${SSL_CERT_FILE:-}}}
  if [ -n "$PROXMOX_CA_FILE" ]; then export SSL_CERT_FILE=$PROXMOX_CA_FILE; fi
}

# warn_old_names: the env file holds the credentials and the CA, nothing
# else. Node and pool belong in the Packer variables file, the CA in
# PROXMOX_CA_FILE. An older env file still works; this says which line to
# move. It names the variable, never its value.
warn_old_names() {
  local name
  for name in SAFBOX_NODE SAFBOX_POOL SAFBOX_CA_FILE SSL_CERT_FILE; do
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?$name=" "$ENV_FILE" || continue
    case $name in
      SAFBOX_NODE) echo "warning: $ENV_FILE sets SAFBOX_NODE: move it to proxmox_node in packer/local.auto.pkrvars.hcl and delete the line" >&2 ;;
      SAFBOX_POOL) echo "warning: $ENV_FILE sets SAFBOX_POOL: move it to proxmox_pool in packer/local.auto.pkrvars.hcl and delete the line" >&2 ;;
      *) echo "warning: $ENV_FILE sets $name: rename it to PROXMOX_CA_FILE, the one CA variable for the scripts and Packer" >&2 ;;
    esac
  done
}

# site_var NAME: a site setting from packer/*.auto.pkrvars.hcl (where the
# node, pool and the rest are set, once), from a line NAME = "value".
# Prints nothing when it is not set there.
site_var() {
  local files=("$ROOT"/packer/*.auto.pkrvars.hcl)
  [ -f "${files[0]}" ] || return 0
  sed -n "s/^ *$1 *= *\"\([^\"]*\)\".*/\1/p" "${files[@]}" | tail -1
}

# api_curl: CURL, the curl command for the Proxmox API, and CURLCFG, the
# file holding its token; the caller removes CURLCFG when done. The token
# never appears on a command line (visible in ps and /proc): curl reads it
# from that 0600 file. TLS verification stays on: the CA is
# PROXMOX_CA_FILE, else the system's; only SAFBOX_INSECURE_TLS=1, for a
# self-signed lab certificate, turns it off.
api_curl() {
  CURLCFG=$(umask 077 && mktemp)
  printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PROXMOX_USERNAME" "$PROXMOX_TOKEN" > "$CURLCFG"
  CURL=(curl -fsS -K "$CURLCFG")
  if [ -n "${PROXMOX_CA_FILE:-}" ]; then CURL+=(--cacert "$PROXMOX_CA_FILE"); fi
  if [ "${SAFBOX_INSECURE_TLS:-0}" = 1 ]; then CURL+=(-k); fi
}
