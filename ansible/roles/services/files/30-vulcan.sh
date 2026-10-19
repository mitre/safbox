#!/usr/bin/env bash
# 30-vulcan.sh: first-boot hook of Vulcan (services role). The one place
# Vulcan's per-install secrets are generated: on first boot, never at
# build, so no two installs share them.
#
# Writes, root-only (0600), with the strength of upstream's
# setup-docker-secrets.sh (https://github.com/mitre/vulcan/blob/master/setup-docker-secrets.sh):
#   /etc/safbox/vulcan.env     POSTGRES_PASSWORD (openssl rand -hex 33),
#                              SECRET_KEY_BASE (-hex 64), CIPHER_PASSWORD
#                              (-hex 64), CIPHER_SALT (-hex 32),
#                              VULCAN_ADMIN_PASSWORD, the password of the one
#                              local account, the administrator, which Vulcan
#                              makes on its first start (lib/tasks/
#                              admin_bootstrap.rake): -hex 24 and a fixed
#                              run of two upper case letters, two lower case,
#                              two digits and two symbols, as Vulcan's own
#                              generator does, so it meets Vulcan's default
#                              complexity rule whatever the random part holds
#   /etc/safbox/vulcan-oidc.env VULCAN_OIDC_CLIENT_SECRET (-hex 32), Vulcan's
#                              client secret in Keycloak, read by both;
#                              unused while Keycloak is switched off
#   /etc/safbox/vulcan-db.env  POSTGRESQL_PASSWORD, the same database password,
#                              for the PostgreSQL container, which needs
#                              nothing else: the password of Vulcan's role,
#                              which the image sets on every start
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
if ! grep -q '^VULCAN_ADMIN_PASSWORD=' "$env_file"; then
  printf 'VULCAN_ADMIN_PASSWORD=%sAZaz09!@\n' "$(openssl rand -hex 24)" >> "$env_file"
fi
safbox_ensure_secret "${SAFBOX_ETC_DIR}/vulcan-oidc.env" VULCAN_OIDC_CLIENT_SECRET 32

safbox_ensure_env_file "$db_env_file"
if ! grep -q '^POSTGRESQL_PASSWORD=' "$db_env_file"; then
  printf 'POSTGRESQL_PASSWORD=%s\n' "$(safbox_env_get "$env_file" POSTGRES_PASSWORD)" >> "$db_env_file"
fi
