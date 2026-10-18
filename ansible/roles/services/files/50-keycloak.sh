#!/usr/bin/env bash
# 50-keycloak.sh: first-boot hook of Keycloak (services role). The one place
# Keycloak's per-install secrets are generated (ADR-0001 §Decision: secrets
# are generated on first boot, never at build).
#
# Writes, root-only (0600), each value from openssl rand -hex (the FIPS
# DRBG; FIPS strict mode needs passwords of 14 characters or more):
#   /etc/safbox/keycloak.env     KC_DB_PASSWORD (-hex 33), the password of
#                                the temporary administrator Keycloak makes
#                                on its first start, KC_BOOTSTRAP_ADMIN_PASSWORD
#                                (-hex 24), and SAFUSER_PASSWORD (-hex 16, 32
#                                characters), the Keycloak password of safuser,
#                                its own and not the OS account's, which the
#                                realm import gives it on Keycloak's first
#                                start
#   /etc/safbox/keycloak-db.env  POSTGRES_PASSWORD, the same database password,
#                                for the PostgreSQL container
# Each application's client secret is its own hook's (20-heimdall.sh,
# 30-vulcan.sh), in a file Keycloak's unit reads as well. Idempotent: an
# existing value is kept, so a retried first boot leaves the database
# password the database was initialised with. Run by safbox-firstboot; as
# root it can also be run by hand.
set -euo pipefail
umask 077

SAFBOX_ETC_DIR=${SAFBOX_ETC_DIR:-/etc/safbox}
SAFBOX_LIB_DIR=${SAFBOX_LIB_DIR:-/usr/local/lib/safbox}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../base/files/secrets.sh
source "${SAFBOX_LIB_DIR}/secrets.sh"

env_file="${SAFBOX_ETC_DIR}/keycloak.env"
db_env_file="${SAFBOX_ETC_DIR}/keycloak-db.env"

safbox_ensure_secret "$env_file" KC_DB_PASSWORD 33
safbox_ensure_secret "$env_file" KC_BOOTSTRAP_ADMIN_PASSWORD 24
safbox_ensure_secret "$env_file" SAFUSER_PASSWORD 16

safbox_ensure_env_file "$db_env_file"
if ! grep -q '^POSTGRES_PASSWORD=' "$db_env_file"; then
  printf 'POSTGRES_PASSWORD=%s\n' "$(safbox_env_get "$env_file" KC_DB_PASSWORD)" >> "$db_env_file"
fi
