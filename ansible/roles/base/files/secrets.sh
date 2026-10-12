# shellcheck shell=bash
# SAFBox first-boot helper library. Source from a hook; do not execute.
#
#   source /usr/local/lib/safbox/secrets.sh
#   safbox_ensure_secret /etc/safbox/heimdall.env DATABASE_PASSWORD
#   safbox_ensure_secret /etc/safbox/heimdall.env JWT_SECRET 64
#
# Every function is idempotent: an existing value is never overwritten, so a
# retried first boot or a manual re-run keeps the credentials a service
# already uses.

# safbox_ensure_env_file FILE
#   Create FILE as an empty root-owned 0600 file if it does not exist and
#   enforce ownership and mode if it does.
safbox_ensure_env_file() {
  local env_file=$1
  if [[ ! -e "$env_file" ]]; then
    (umask 077 && : > "$env_file")
  fi
  chown root:root "$env_file"
  chmod 0600 "$env_file"
}

# safbox_ensure_secret FILE KEY [BYTES]
#   Append KEY=<random hex> to FILE unless KEY is already present. BYTES is
#   the number of random bytes (default 32, giving 64 hex characters) drawn
#   from openssl rand, which uses the FIPS-approved DRBG in FIPS mode.
safbox_ensure_secret() {
  local env_file=$1 key=$2 bytes=${3:-32} value
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf 'safbox_ensure_secret: invalid key name %q\n' "$key" >&2
    return 1
  fi
  if [[ ! "$bytes" =~ ^[0-9]+$ ]] || (( bytes < 16 )); then
    printf 'safbox_ensure_secret: BYTES must be an integer >= 16, got %q\n' "$bytes" >&2
    return 1
  fi
  safbox_ensure_env_file "$env_file"
  if grep -q "^${key}=" "$env_file"; then
    return 0
  fi
  value=$(openssl rand -hex "$bytes")
  printf '%s=%s\n' "$key" "$value" >> "$env_file"
}

# safbox_env_get FILE KEY
#   Print the value of KEY from FILE, or return 1 if absent.
safbox_env_get() {
  local env_file=$1 key=$2 line
  line=$(grep -m1 "^${key}=" "$env_file") || return 1
  printf '%s\n' "${line#*=}"
}
