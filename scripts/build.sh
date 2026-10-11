#!/usr/bin/env bash
# Build the SAFBox template. Sources Proxmox credentials from a 0600 env file,
# mints an ephemeral RSA key pair for the build user (RSA because the target
# runs in FIPS mode), and runs packer with any extra arguments passed through.
#
#   scripts/build.sh                 # uses packer/*.auto.pkrvars.hcl
#   scripts/build.sh -var vm_memory=4096
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

umask 077
ENV_FILE="${SAFBOX_PROXMOX_ENV:-$HOME/.config/proxmox/packer.env}"
if [ -f "$ENV_FILE" ]; then
  perm=$(stat -f %Lp "$ENV_FILE" 2>/dev/null || stat -c %a "$ENV_FILE")
  [ "$perm" = 600 ] || { echo "refusing $ENV_FILE: mode $perm, must be 600" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
# Development-only conveniences (installer SSH, keeping the build key) need an
# explicit opt-in so a release build cannot carry them by accident.
if [ "${SAFBOX_DEV:-0}" != 1 ] && grep -Eqs '^\s*installer_ssh\s*=\s*true' packer/*.auto.pkrvars.hcl; then
  echo "installer_ssh=true found in a vars file; set SAFBOX_DEV=1 for a development build" >&2; exit 1
fi
: "${PROXMOX_URL:?set PROXMOX_URL or provide $ENV_FILE}"
: "${PROXMOX_USERNAME:?set PROXMOX_USERNAME}"
: "${PROXMOX_TOKEN:?set PROXMOX_TOKEN}"

KEYDIR="$ROOT/.build"
mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"
KEY="$KEYDIR/build_key"
rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t rsa -b 4096 -N '' -C "safbox-build-$(date -u +%Y%m%dT%H%M%SZ)" -f "$KEY"

# Full debug log (HTTP kickstart fetches, plugin API calls) lands next to the
# ephemeral key; it can contain the API URL and VM details, never the token.
export PACKER_LOG=1
export PACKER_LOG_PATH="$KEYDIR/packer-debug.log"
rm -f "$PACKER_LOG_PATH"

packer init packer/
packer build \
  -var "ssh_public_key=$(cat "$KEY.pub")" \
  -var "ssh_private_key_file=$KEY" \
  -var "git_revision=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  "$@" packer/
rc=$?

# The token must never reach the debug log (Packer redacts sensitive vars;
# this makes it a test rather than a belief).
if grep -qF -- "$PROXMOX_TOKEN" "$PACKER_LOG_PATH" 2>/dev/null; then
  echo "FATAL: API token found in $PACKER_LOG_PATH" >&2; exit 2
fi
# The ephemeral build key is only useful afterwards for pre-seal diagnostics.
if [ "${SAFBOX_DEV:-0}" != 1 ]; then rm -f "$KEY" "$KEY.pub"; fi
exit $rc
