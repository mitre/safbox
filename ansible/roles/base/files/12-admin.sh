#!/usr/bin/env bash
# 12-admin.sh: first-boot hook of the base role. Settles admin, the
# account cloud-init creates as its default user for the deployer: deploying
# and automation (Ansible, the release gate), key login only, passwordless
# sudo. The name is the one cloud-init used (a deployment may rename the
# default user; SAFBox's own default is admin, set in the template's
# /etc/cloud/cloud.cfg.d/80-safbox-users.cfg).
#
#   - No password, ever: its password field is a lock with no hash. cloud-init
#     creates it locked and does not run set_passwords, so this only acts when
#     a deployment's own users list gave it a password.
#   - Exempt from password ageing and inactivity (chage -M -1 -I -1). The
#     STIG's 60-day maximum in /etc/login.defs would otherwise expire its
#     unusable password, and sshd then refuses its key login because a
#     password change is required that it cannot make.
#   - Hidden from the desktop login screen (AccountsService SystemAccount),
#     where AccountsService is installed.
# pam_faillock cannot lock it out of what it is for: SSH key login and
# passwordless sudo run no PAM authentication, so failed password attempts
# never reach them.
#
# Idempotent. Run by safbox-firstboot after cloud-init has created the
# account; logs to standard output (the journal, under safbox-firstboot).
set -euo pipefail
export LC_ALL=C
umask 077

readonly ACCOUNTS_DIR=/var/lib/AccountsService/users
log() { printf '12-admin: %s\n' "$*"; }

cfg=$(cloud-init query combined_cloud_config)
# cloud-init's default user: the top-level user (a name, or a mapping with
# one) renames system_info.default_user.
name=$(jq -r '
  if (.user | type) == "string" then .user
  elif (.user | type) == "object" then .user.name // .system_info.default_user.name
  else .system_info.default_user.name end // empty' <<<"$cfg")
if [[ "$name" == root ]]; then
  log "cloud-init's user is root; leaving it as it is"
  exit 0
fi
if [[ -z "$name" ]] || ! getent passwd "$name" >/dev/null; then
  log "cloud-init created no default user${name:+ ($name)}; nothing to do"
  exit 0
fi

field=$(getent shadow "$name" | cut -d: -f2)
if [[ ! "$field" =~ ^[!*]+$ ]]; then
  usermod -p '!' "$name"
  log "WARNING: $name had a password, from the deployment's own user data; removed it: $name logs in with its SSH key only"
fi

chage -M -1 -I -1 "$name"
log "exempted $name from password ageing and inactivity"

if [[ -d "$ACCOUNTS_DIR" ]]; then
  file="$ACCOUNTS_DIR/$name"
  if [[ ! -f "$file" ]]; then
    printf '[User]\nSystemAccount=true\n' > "$file"
  elif ! grep -qx 'SystemAccount=true' "$file"; then
    sed -i -e '/^SystemAccount=/d' -e '/^\[User\]$/a SystemAccount=true' "$file"
    grep -qx 'SystemAccount=true' "$file" || printf '[User]\nSystemAccount=true\n' >> "$file"
  fi
  systemctl try-restart accounts-daemon.service || log "WARNING: accounts-daemon did not restart; the login screen may list $name until the next boot"
  log "hid $name from the login screen"
fi
