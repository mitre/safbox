#!/usr/bin/env bash
# Idempotence check (ADR-0001 Quality Standards: a second run reports zero
# changed tasks). Runs playbooks/safbox.yml twice against one host and fails
# if the second run changed anything. Arguments are passed to both runs,
# e.g. -e safbox_example_quadlet_enabled=true. Requires:
#   SAFBOX_HOST  address of a booted build VM or clone
#   SAFBOX_USER  SSH user with passwordless sudo (the build user)
#   SAFBOX_KEY   path to that user's SSH private key
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

if [[ -z "${SAFBOX_HOST:-}" || -z "${SAFBOX_USER:-}" || -z "${SAFBOX_KEY:-}" ]]; then
  cat >&2 <<'MSG'
SKIP: idempotence check needs a live target.
Set SAFBOX_HOST, SAFBOX_USER and SAFBOX_KEY (path to the SSH private key)
to the booted VM the appliance layer should be applied to, then rerun.
MSG
  exit 2
fi
[[ -r "$SAFBOX_KEY" ]] || { echo "FAIL: SAFBOX_KEY=$SAFBOX_KEY is not readable" >&2; exit 2; }
# The playbook runs from ansible/; resolve the key before changing directory.
SAFBOX_KEY=$(cd "$(dirname "$SAFBOX_KEY")" && pwd)/$(basename "$SAFBOX_KEY")
command -v ansible-playbook >/dev/null || { echo "FAIL: ansible-playbook not installed" >&2; exit 1; }

cd "$ROOT/ansible"
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
export ANSIBLE_FORCE_COLOR=0
export ANSIBLE_NOCOLOR=1

run_playbook() {
  ansible-playbook playbooks/safbox.yml \
    -i "${SAFBOX_HOST}," \
    -u "$SAFBOX_USER" \
    --private-key "$SAFBOX_KEY" \
    "$@"
}

echo "== first run"
run_playbook "$@"

echo "== second run (must change nothing)"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
run_playbook "$@" | tee "$log"

# PLAY RECAP lines look like: host : ok=12 changed=0 unreachable=0 failed=0 ...
recap=$(sed -n '/^PLAY RECAP/,$p' "$log" | grep -E 'ok=[0-9]+' || true)
[[ -n "$recap" ]] || { echo "FAIL: no PLAY RECAP found in second run" >&2; exit 1; }
if ! grep -qE 'changed=0 ' <<<"$recap" || grep -qE 'changed=[1-9]' <<<"$recap"; then
  echo "FAIL: second run reported changes:" >&2
  echo "$recap" >&2
  exit 1
fi
if grep -qE '(failed|unreachable)=[1-9]' <<<"$recap"; then
  echo "FAIL: second run reported failures:" >&2
  echo "$recap" >&2
  exit 1
fi
echo "PASS: second run changed=0"
