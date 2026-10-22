#!/usr/bin/env bash
# Build the SAFBox template. Sources Proxmox credentials from a 0600 env file,
# mints an ephemeral RSA key pair for the build user (RSA because the target
# runs in FIPS mode), and runs packer with any extra arguments passed through.
#
#   scripts/build.sh                 # uses packer/*.auto.pkrvars.hcl
#   scripts/build.sh -var vm_memory=4096
#   scripts/build.sh -var vga=std      # standard VGA instead of the default qxl (SPICE)
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
cd "$ROOT"

umask 077
load_env
# Development-only conveniences (installer SSH, keeping the build key) need an
# explicit opt-in so a release build cannot carry them by accident.
if [ "${SAFBOX_DEV:-0}" != 1 ] && grep -Eqs '^\s*installer_ssh\s*=\s*true' packer/*.auto.pkrvars.hcl; then
  echo "installer_ssh=true found in a vars file; set SAFBOX_DEV=1 for a development build" >&2; exit 1
fi
: "${PROXMOX_URL:?set PROXMOX_URL or provide $ENV_FILE}"
: "${PROXMOX_USERNAME:?set PROXMOX_USERNAME}"
: "${PROXMOX_TOKEN:?set PROXMOX_TOKEN}"

# Each run keeps its state in its own directory, .build/runs/<UTC time>-<random>
# (mode 0700, from mktemp): the build log, the ephemeral key pair, Packer's
# debug log, the galaxy install and the build gate's results (scans/, which
# the seal installs in the template; the run ID is the directory's name).
# Two runs on one workstation share none of it, so they can build at the
# same time (with distinct vm_id and vm_name).
mkdir -p "$ROOT/.build/runs"
chmod 700 "$ROOT/.build"
RUN_DIR=$(mktemp -d "$ROOT/.build/runs/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
RUN_ID=$(basename "$RUN_DIR")
KEY="$RUN_DIR/build_key"
GALAXY_DIR="$RUN_DIR/galaxy"
# Full debug log (HTTP kickstart fetches, plugin API calls): it can contain
# the API URL and VM details, never the token.
export PACKER_LOG=1
export PACKER_LOG_PATH="$RUN_DIR/packer-debug.log"

# However the run ends (success, failure, a signal bash can trap): the key
# goes unless SAFBOX_DEV=1 keeps it for pre-seal diagnostics
# (scripts/clone-and-ssh.sh), the token must never reach the debug log
# (Packer redacts sensitive vars; this makes it a test rather than a belief),
# and the galaxy install goes. The run's exit status is kept, or 2 on a
# leak; a cleanup step that fails only warns, so it can neither skip the
# steps after it nor replace that status. SIGKILL runs no trap at all.
# SIGPIPE is ignored here so that a message to a closed output cannot end
# the cleanup half-way. A debug log that exists but cannot be read is
# reported rather than taken as clean.
finish() {
  local rc=$? grc
  set +e
  trap '' PIPE
  if [ "${SAFBOX_DEV:-0}" != 1 ]; then
    rm -f "$KEY" "$KEY.pub" || echo "warning: could not delete the build key $KEY" >&2
  fi
  if [ -e "$PACKER_LOG_PATH" ]; then
    grep -qF -- "$PROXMOX_TOKEN" "$PACKER_LOG_PATH" 2>/dev/null
    grc=$?
    if [ "$grc" -eq 0 ]; then
      echo "FATAL: API token found in $PACKER_LOG_PATH" >&2
      rc=2
    elif [ "$grc" -ne 1 ]; then
      echo "warning: cannot read $PACKER_LOG_PATH to check it for the API token" >&2
    fi
  fi
  rm -rf "$GALAXY_DIR" 2>/dev/null || echo "warning: could not remove $GALAXY_DIR" >&2
  # Let tee write the last lines to build.log before the run ends.
  if [ -n "${TEE_PID:-}" ]; then exec >&- 2>&-; wait "$TEE_PID" 2>/dev/null; fi
  exit "$rc"
}
trap finish EXIT
# A signal ends the run through finish. Bash runs these traps only once the
# command in the foreground has returned. A signal to the whole process group
# (Ctrl-C, kill -TERM -<pgid>, a closed terminal's SIGHUP) also reaches
# Packer, which cancels the build and removes its VM, then the run ends; a
# SIGTERM or SIGHUP sent to this script alone waits for Packer to finish.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# .build/runs/latest points at the newest run, and last.log in the
# repository root at .build/runs/latest/build.log, so the two always agree
# and `tail -F last.log` follows builds across runs. Only latest changes per
# run; GNU ln -sfn replaces it with one rename. Where ln unlinks first
# instead, a run that loses a race to repoint it still builds.
ln -sfn "$RUN_ID" "$ROOT/.build/runs/latest" || echo "warning: could not repoint .build/runs/latest" >&2
if [ "$(readlink "$ROOT/last.log" 2>/dev/null)" != .build/runs/latest/build.log ]; then
  ln -sfn .build/runs/latest/build.log "$ROOT/last.log" || echo "warning: could not point last.log at .build/runs/latest" >&2
fi
# tee ignores the signals that end a run (ignored dispositions survive
# exec): a signal to the whole process group must not kill it while Packer
# and finish still have output for build.log. It ends at EOF, when the run
# closes its output. Bash already starts a process substitution with INT
# (and QUIT) ignored; naming INT in this trap would reset it to the default
# before exec, so only TERM and HUP are added.
exec > >(trap '' TERM HUP; exec tee -a "$RUN_DIR/build.log") 2>&1
TEE_PID=$!
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
# here from its lockfile so the box needs neither npm nor the registry. It
# goes into this run's own directory; npm and VitePress also write inside
# site/ itself (node_modules, .vitepress/.temp), so concurrent runs take
# turns there under a lock.
SITE_DIR="$RUN_DIR/site"
(
  flock 9
  npm --prefix "$ROOT/site" ci --no-audit --no-fund
  npm --prefix "$ROOT/site" run build -- --outDir "$SITE_DIR"
) 9>"$ROOT/.build/site.lock"

packer init packer/
packer build \
  -var "ssh_public_key=$(cat "$KEY.pub")" \
  -var "ssh_private_key_file=$KEY" \
  -var "galaxy_dir=$GALAXY_DIR" \
  -var "site_dir=$SITE_DIR" \
  -var "git_revision=$REVISION" \
  -var "build_run_id=$RUN_ID" \
  -var "build_scans_dir=$RUN_DIR/scans" \
  "$@" packer/
