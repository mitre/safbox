#!/usr/bin/env bash
# Build the SAFBox template: source the Proxmox credentials from a 0600 env
# file, mint an ephemeral RSA key pair for the build user (RSA because the
# target runs in FIPS mode), and run packer with any extra arguments passed
# through. scripts/build.sh --help lists its arguments, environment and
# files.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
cd "$ROOT"

usage() {
  cat <<'USAGE'
usage: scripts/build.sh [-h | --help] [PACKER-BUILD-ARGUMENTS...]

Build the SAFBox template on Proxmox VE: Packer installs the build VM,
Ansible configures it, scripts/validate.sh checks it, and it is sealed and
made a template. Every argument but -h/--help goes to `packer build`
unchanged, for example:
  -var vm_id=N          the template's VM ID (see VM ID below)
  -var vm_name=NAME     the template's name (default safbox-el10-base)
  -var vm_memory=4096   any other Packer variable (packer/variables.pkr.hcl)
  -var vga=std          standard VGA instead of the default qxl (SPICE)
  -on-error=cleanup     delete the build VM when the build fails (default:
                        -on-error=abort, which keeps it; see below)
  -timestamp-ui         any other packer build option

  -h, --help            print this and exit

A failed or interrupted (Ctrl-C) build keeps its VM, still running, and
its build key in .build/run/, and prints the VM ID, an ssh command for
the build user and how to delete the VM (scripts/delete-vm.sh <id>, or
qm stop and qm destroy on the node). Pass -on-error=cleanup to have
Packer delete it instead. When Proxmox refuses the VM ID because a VM
already has it, the build made no VM: it says so and suggests no delete,
since that VM is not the build's.

VM ID: vm_id in packer/local.auto.pkrvars.hcl, or -var vm_id=N on the
command line, which wins. Packer never reuses an ID: to rebuild, delete
the previous template or give a free ID.

Credentials, from the env file (scripts/example.env is its template; copy
it to ~/.config/proxmox/packer.env and chmod 600 it) or the shell, which
wins over the file:
  SAFBOX_PROXMOX_ENV    the env file (default ~/.config/proxmox/packer.env);
                        read when it exists, refused unless its mode is 0600
  PROXMOX_URL           https://<node>:8006/api2/json (required)
  PROXMOX_USERNAME      the API token ID, <user>@pve!<token-name> (required)
  PROXMOX_TOKEN         the API token secret (required; never printed)
  PROXMOX_CA_FILE       the cluster CA Packer trusts for the API, passed to
                        it as SSL_CERT_FILE (default: the system trust
                        store); Packer's switch to turn TLS verification
                        off is proxmox_insecure_skip_tls_verify

Files:
  packer/*.auto.pkrvars.hcl  Packer variables, git-ignored; copy
                             packer/example.pkrvars.hcl to
                             packer/local.auto.pkrvars.hcl and fill it in:
                             node, pool, VM ID, ISO, storage, bridge, CPU,
                             sizes, install_timeout (default 45m), seal.
  .build/run/                this build's files, replaced by the next build:
                             build.log, Packer's debug log, the build gate's
                             results (scans/), the built site and, after a
                             failure, the build key

The build needs packer, ansible-playbook, cinc-auditor, saf, npm and more
on PATH (scripts/check-tools.sh checks; ~/.local/bin is added in front).
Guide: docs/guides/proxmox/build.md
USAGE
}

for a in "$@"; do
  case "$a" in -h | --help) usage; exit 0 ;; esac
done

umask 077
load_env
: "${PROXMOX_URL:?set PROXMOX_URL or provide $ENV_FILE}"
: "${PROXMOX_USERNAME:?set PROXMOX_USERNAME}"
: "${PROXMOX_TOKEN:?set PROXMOX_TOKEN}"

# The build keeps its files in .build/run/ (mode 0700), emptied first: the
# build log, the ephemeral key pair, Packer's debug log, the galaxy install,
# the built site and the build gate's results (scans/, which the seal
# installs in the template with the run ID, the build's start time).
RUN_DIR="$ROOT/.build/run"
mkdir -p "$ROOT/.build"
chmod 700 "$ROOT/.build"
rm -rf "$RUN_DIR"
mkdir "$RUN_DIR"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
KEY="$RUN_DIR/build_key"
# Full debug log (HTTP kickstart fetches, plugin API calls): it can contain
# the API URL and VM details, never the token.
export PACKER_LOG=1
export PACKER_LOG_PATH="$RUN_DIR/packer-debug.log"

# Packer's -on-error: abort keeps a failed or interrupted build's VM for
# diagnosis; the operator's own -on-error=MODE wins (cleanup deletes it).
ON_ERROR=abort
for a in "$@"; do
  case "$a" in -on-error=* | --on-error=*) ON_ERROR=${a#*=} ;; esac
done

# packer_var NAME DEFAULT: a Packer variable as this build sets it: the
# last -var NAME=VALUE on the command line, else packer/*.auto.pkrvars.hcl,
# else DEFAULT.
PACKER_ARGS=("$@")
packer_var() {
  local v
  v=$(printf '%s\n' "${PACKER_ARGS[@]}" | sed -n "s/^\(-var=\)\{0,1\}$1=//p" | tail -1)
  [ -n "$v" ] || v=$(cat packer/*.auto.pkrvars.hcl 2>/dev/null | sed -n "s/^ *$1 *= *\"\{0,1\}\([^\" #]*\).*/\1/p" | tail -1)
  echo "${v:-$2}"
}

# After a failed or interrupted packer build that kept its VM: print how to
# reach it with the kept build key and how to delete it. The address is the
# one Packer tried SSH on, from its debug log (build.log never names it before
# the build gate); a build that failed before that point shows it only in the
# Proxmox UI.
keep_vm() {
  local ip id
  ip=$(sed -n 's/.*Attempting SSH connection to \([^ ]*\):[0-9]*\.\.\..*/\1/p' "$PACKER_LOG_PATH" | tail -1)
  id=$(packer_var vm_id "<vm_id>")
  echo
  echo "The build failed or was interrupted. Its VM is kept for diagnosis:"
  echo "  VM ID:   $id"
  echo "  ssh:     ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(packer_var build_user packer)@${ip:-<the VM address, from the Proxmox UI>}"
  echo "  delete:  scripts/delete-vm.sh $id (or on the node: qm stop $id; qm destroy $id --purge)"
  echo "The key stays in .build/run/ until the next build empties it."
}

# Whether Proxmox refused the build's VM ID because a VM already has it. The
# build then made no VM, and the VM with that ID is someone else's: never
# offer to delete it.
vm_id_taken() {
  grep -qE 'unable to create VM [0-9]+ - VM [0-9]+ already exists' "$RUN_DIR/build.log"
}

# However the run ends (SIGKILL aside): the build key goes, unless packer
# build failed and kept its VM (keep_vm); and the token must not be in the
# debug log (Packer redacts sensitive variables; this makes it a test rather
# than a belief). The token reaches grep on its standard input, never on a
# command line. A leak exits 2.
PACKER_STARTED=0
finish() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$PACKER_STARTED" = 1 ] && vm_id_taken; then
    echo
    echo "VM ID $(packer_var vm_id "<vm_id>") belongs to a VM that already exists; the build made no VM."
    echo "Leave that VM alone and give a free ID (vm_id in packer/local.auto.pkrvars.hcl, or -var vm_id=N)."
    rm -f "$KEY" "$KEY.pub"
  elif [ "$rc" -ne 0 ] && [ "$PACKER_STARTED" = 1 ] && [ "$ON_ERROR" != cleanup ]; then
    keep_vm
  else
    rm -f "$KEY" "$KEY.pub"
  fi
  if [ -e "$PACKER_LOG_PATH" ] && printf '%s\n' "$PROXMOX_TOKEN" | grep -qFf - "$PACKER_LOG_PATH"; then
    echo "FATAL: API token found in $PACKER_LOG_PATH" >&2
    rc=2
  fi
  exit "$rc"
}
trap finish EXIT

# Everything printed also goes to build.log. tee ignores Ctrl-C so that,
# after an interrupt, Packer can still write its last lines and exit
# normally instead of dying on a closed pipe halfway through.
exec > >(trap '' INT; exec tee "$RUN_DIR/build.log") 2>&1
echo "build log: $RUN_DIR/build.log"

ssh-keygen -q -t rsa -b 4096 -N '' -C "safbox-build-$RUN_ID" -f "$KEY"

# Revision recorded in the template: the commit, marked -dirty when tracked
# files are modified or untracked project files exist, so an image built from
# uncommitted work is never mistaken for one built from that commit.
REVISION=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then REVISION="$REVISION-dirty"; fi

# The Ansible provisioner runs ansible-playbook on this machine.
export PATH="$HOME/.local/bin:$PATH"
# The build validates the VM from this machine before sealing it.
"$ROOT/scripts/check-tools.sh"

# The documentation site the box serves (docs/, built with VitePress), built
# here from its lockfile so the box needs neither npm nor the registry.
SITE_DIR="$RUN_DIR/site"
npm --prefix "$ROOT/site" ci --no-audit --no-fund
npm --prefix "$ROOT/site" run build -- --outDir "$SITE_DIR"

packer init packer/
PACKER_STARTED=1
packer build \
  -on-error="$ON_ERROR" \
  -var "ssh_public_key=$(cat "$KEY.pub")" \
  -var "ssh_private_key_file=$KEY" \
  -var "galaxy_dir=$RUN_DIR/galaxy" \
  -var "site_dir=$SITE_DIR" \
  -var "git_revision=$REVISION" \
  -var "build_run_id=$RUN_ID" \
  -var "build_scans_dir=$RUN_DIR/scans" \
  "$@" packer/
