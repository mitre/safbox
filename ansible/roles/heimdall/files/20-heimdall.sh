#!/usr/bin/env bash
# 20-heimdall.sh: first-boot hook of the heimdall role. The one place
# Heimdall's per-install secrets are generated (ADR-0001 §Decision: secrets
# are generated on first boot, never at build).
#
# Writes, root-only (0600), with the strength of upstream's
# setup-docker-env.sh (https://github.com/mitre/heimdall2/blob/master/setup-docker-env.sh):
#   /etc/safbox/heimdall.env     DATABASE_PASSWORD (openssl rand -hex 33),
#                                JWT_SECRET (-hex 64), API_KEY_SECRET (-hex 33)
#   /etc/safbox/heimdall-db.env  POSTGRES_PASSWORD, the same database password,
#                                for the PostgreSQL container, which needs
#                                nothing else (upstream's compose passes
#                                POSTGRES_PASSWORD=${DATABASE_PASSWORD})
# Idempotent: an existing value is kept, so a retried first boot leaves the
# database password the database was initialised with. Run by
# safbox-firstboot; as root it can also be run by hand.
set -euo pipefail
umask 077

SAFBOX_ETC_DIR=${SAFBOX_ETC_DIR:-/etc/safbox}
SAFBOX_LIB_DIR=${SAFBOX_LIB_DIR:-/usr/local/lib/safbox}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../base/files/secrets.sh
source "${SAFBOX_LIB_DIR}/secrets.sh"

env_file="${SAFBOX_ETC_DIR}/heimdall.env"
db_env_file="${SAFBOX_ETC_DIR}/heimdall-db.env"

safbox_ensure_secret "$env_file" DATABASE_PASSWORD 33
safbox_ensure_secret "$env_file" JWT_SECRET 64
safbox_ensure_secret "$env_file" API_KEY_SECRET 33

safbox_ensure_env_file "$db_env_file"
if ! grep -q '^POSTGRES_PASSWORD=' "$db_env_file"; then
  printf 'POSTGRES_PASSWORD=%s\n' "$(safbox_env_get "$env_file" DATABASE_PASSWORD)" >> "$db_env_file"
fi
