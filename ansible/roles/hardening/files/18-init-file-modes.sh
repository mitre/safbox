#!/usr/bin/env bash
# 18-init-file-modes.sh: first-boot hook of the hardening role. Gives the
# local initialization files (the dotfiles in a home directory) of every
# interactive account mode 0740 or less (RHEL-10-400235). Lockdown applies
# the rule at build, before first boot makes admin and safuser from
# /etc/skel, whose files are 0644; this applies it to them.
#
# Idempotent. Run by safbox-firstboot after the account hooks; logs to
# standard output (the journal, under safbox-firstboot).
set -euo pipefail
export LC_ALL=C

log() { printf '18-init-file-modes: %s\n' "$*"; }

while IFS=: read -r name _ uid _ _ home shell; do
  # Interactive accounts: a uid from 1000 (nobody's 65534 excepted) and a
  # login shell.
  [[ "$uid" -ge 1000 && "$uid" -ne 65534 ]] || continue
  case "$shell" in
    */nologin | */false | */true | */sync | */halt | */shutdown) continue ;;
  esac
  [[ -d "$home" ]] || continue
  while IFS= read -r -d '' file; do
    chmod g-wx,o-rwx "$file"
    log "set $file ($name) to $(stat -c %a "$file")"
  done < <(find "$home" -xdev -maxdepth 1 -type f -name '.*' -perm /g+wx,o+rwx -print0)
done < <(getent passwd)
