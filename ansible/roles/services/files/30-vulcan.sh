#!/usr/bin/env bash
# 30-vulcan.sh: first-boot hook of Vulcan (services role). The one place
# Vulcan's per-install secrets are generated (ADR-0001 §Decision: secrets
# are generated on first boot, never at build).
#
# Writes, root-only (0600), with the strength of upstream's
# setup-docker-secrets.sh (https://github.com/mitre/vulcan/blob/master/setup-docker-secrets.sh):
#   /etc/safbox/vulcan.env     POSTGRES_PASSWORD (openssl rand -hex 33),
#                              SECRET_KEY_BASE (-hex 64), CIPHER_PASSWORD
#                              (-hex 64), CIPHER_SALT (-hex 32)
#   /etc/safbox/vulcan-db.env  POSTGRES_PASSWORD, the same database password,
#                              for the PostgreSQL container, which needs
#                              nothing else
# Vulcan reads POSTGRES_PASSWORD itself (config/database.yml), so no
# DATABASE_URL carrying the password is written. Idempotent: an existing
# value is kept, so a retried first boot leaves the database password the
# database was initialised with. Run by safbox-firstboot; as root it can
# also be run by hand.
set -euo pipefail
umask 077

SAFBOX_ETC_DIR=${SAFBOX_ETC_DIR:-/etc/safbox}
SAFBOX_LIB_DIR=${SAFBOX_LIB_DIR:-/usr/local/lib/safbox}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../base/files/secrets.sh
source "${SAFBOX_LIB_DIR}/secrets.sh"

env_file="${SAFBOX_ETC_DIR}/vulcan.env"
db_env_file="${SAFBOX_ETC_DIR}/vulcan-db.env"

safbox_ensure_secret "$env_file" POSTGRES_PASSWORD 33
safbox_ensure_secret "$env_file" SECRET_KEY_BASE 64
safbox_ensure_secret "$env_file" CIPHER_PASSWORD 64
safbox_ensure_secret "$env_file" CIPHER_SALT 32

safbox_ensure_env_file "$db_env_file"
if ! grep -q '^POSTGRES_PASSWORD=' "$db_env_file"; then
  printf 'POSTGRES_PASSWORD=%s\n' "$(safbox_env_get "$env_file" POSTGRES_PASSWORD)" >> "$db_env_file"
fi
