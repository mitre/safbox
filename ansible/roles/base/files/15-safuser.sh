#!/usr/bin/env bash
# 15-safuser.sh: first-boot hook of the base role. Creates safuser, the
# account for using the tools day to day, beside admin, the key-only
# account cloud-init creates for the deployer (its default user).
#
# What the deployer gave cloud-init (its top-level ssh_authorized_keys and
# password) is read from cloud-init's combined configuration:
#   - the SSH keys become safuser's too;
#   - a password, when one was given, is safuser's alone (cloud-init does
#     not run set_passwords, so admin never gets it): a crypt hash as it
#     is, a plain password hashed with SHA-512;
#   - with no password given (or cloud-init's RANDOM, which is not a
#     password), a password that meets the system's password quality
#     policy (the STIG's length and complexity) is generated, hashed with
#     SHA-512 and kept for root only in /etc/safbox/safuser.env.
# The password is not expired, so the first login does not force a change;
# from then on it follows the STIG's ageing in /etc/login.defs (60 days at
# most) like any other, and pam_faillock can lock the account until admin
# releases it (faillock --user safuser --reset).
# safuser's sudo rule (/etc/sudoers.d/50-safuser) asks for this password.
#
# A deployment's own users list may create safuser itself. Its password and
# keys are then kept when it has a usable password; a locked one (cloud-init
# locks every users-list password unless the entry sets lock_passwd: false,
# storing '!' before the hash) counts as none, and safuser gets the
# supplied or generated password as above.
#
# Idempotent: a second run keeps the account, its keys and the password
# the first run set.
# Run by safbox-firstboot after cloud-init has created its users;
# logs to standard output (the journal, under safbox-firstboot).
set -euo pipefail
export LC_ALL=C
umask 077

# shellcheck source-path=SCRIPTDIR
# shellcheck source=secrets.sh
source "${SAFBOX_LIB_DIR:-/usr/local/lib/safbox}/secrets.sh"

readonly USER_NAME=safuser
readonly ENV_FILE="${SAFBOX_ETC_DIR:-/etc/safbox}/safuser.env"
log() { printf '15-safuser: %s\n' "$*"; }

cfg=$(cloud-init query combined_cloud_config)

# Hash with the rounds the PAM stack uses (pam_unix rounds=, from the
# hardening role's authselect profile), as passwd would; chpasswd's own
# default is 5000, and SHA_CRYPT_*_ROUNDS in /etc/login.defs make it pick
# rounds up to 999999999 on EL10.
rounds=$(sed -n 's/^password.*pam_unix\.so.* rounds=\([0-9][0-9]*\).*/\1/p' /etc/pam.d/system-auth 2>/dev/null | head -1 || true)
hash_args=(-c SHA512)
if [[ -n "$rounds" ]]; then hash_args+=(-s "$rounds"); fi

if ! getent passwd "$USER_NAME" >/dev/null; then
  useradd --create-home --comment 'SAFBox tools user' "$USER_NAME"
  log "created $USER_NAME"
fi
home=$(getent passwd "$USER_NAME" | cut -d: -f6)
group=$(id -gn "$USER_NAME")

keys=$(jq -r '.ssh_authorized_keys // [] | .[]' <<<"$cfg")
if [[ -s "$home/.ssh/authorized_keys" ]]; then
  : # keys from a first run or the deployment's users list are kept
elif [[ -z "$keys" ]]; then
  log "WARNING: cloud-init was given no SSH key, so $USER_NAME has none; it logs in with its password at the console only"
else
  install -d -m 0700 -o "$USER_NAME" -g "$group" "$home/.ssh"
  install -m 0600 -o "$USER_NAME" -g "$group" /dev/null "$home/.ssh/authorized_keys"
  printf '%s\n' "$keys" > "$home/.ssh/authorized_keys"
  if command -v restorecon >/dev/null; then restorecon -R "$home/.ssh"; fi
  log "gave $USER_NAME the deployer's SSH keys"
fi

# A usable password (a hash, from a first run or the deployment's users
# list) is kept. A locked one ('!' before any hash) or none ('!!', '*')
# is not usable, and safuser gets the supplied or generated password.
if [[ "$(getent shadow "$USER_NAME" | cut -d: -f2)" == \$* ]]; then
  log "kept $USER_NAME's password"
  exit 0
fi
supplied=$(jq -r '.password // empty' <<<"$cfg")
# cloud-init reads RANDOM (or R) as "generate one", not as a password.
if [[ "$supplied" == RANDOM || "$supplied" == R ]]; then
  supplied=""
fi
if [[ -n "$supplied" ]]; then
  if [[ "$supplied" =~ ^\$[0-9a-z]+\$ ]]; then
    printf '%s:%s\n' "$USER_NAME" "$supplied" | chpasswd -e
    if [[ "$supplied" != \$6\$* ]]; then
      log "WARNING: the supplied password hash is not SHA-512 (\$6\$), which the STIG requires; supply one made with 'openssl passwd -6'"
    fi
  else
    printf '%s:%s\n' "$USER_NAME" "$supplied" | chpasswd "${hash_args[@]}"
  fi
  log "set the password the deployer supplied"
else
  safbox_ensure_env_file "$ENV_FILE"
  password=$(safbox_env_get "$ENV_FILE" SAFUSER_PASSWORD || true)
  if [[ -z "$password" ]]; then
    for _ in $(seq 1 50); do
      candidate=$(pwmake 128)
      if pwscore "$USER_NAME" <<<"$candidate" >/dev/null 2>&1; then
        password=$candidate
        break
      fi
    done
    [[ -n "$password" ]] || { log "ERROR: no generated password met the password quality policy"; exit 1; }
    printf 'SAFUSER_PASSWORD=%s\n' "$password" >> "$ENV_FILE"
  fi
  printf '%s:%s\n' "$USER_NAME" "$password" | chpasswd "${hash_args[@]}"
  log "set a generated password, kept in $ENV_FILE"
fi
