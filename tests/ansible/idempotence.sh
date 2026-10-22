#!/usr/bin/env bash
# Idempotence check: a second run must report zero changed tasks. Runs
# playbooks/safbox.yml twice against one host and fails if the second run
# changed anything. Arguments are passed to both runs. Requires:
#   SAFBOX_HOST  address of a booted build VM or clone
#   SAFBOX_USER  SSH user with passwordless sudo (the build user)
#   SAFBOX_KEY   path to that user's SSH private key
#
# One known upstream defect is tolerated, by exact task name and nothing
# else: the pinned Ansible Lockdown RHEL10-STIG role ends every run with
# "POST | Warning a reboot required but skip option set", a debug task with
# changed_when: true, so it reports one change on every run. Any other
# changed task, or that task changing more than once, still fails. Remove
# the tolerance when the pinned Lockdown release fixes the task.
#
#   tests/ansible/idempotence.sh [ansible-playbook args...]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TOLERATED='RHEL10-STIG : POST | Warning a reboot required but skip option set'

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

# The recap's changed count, and the task headers above each changed result.
changed=$(sed -n '/^PLAY RECAP/,$p' "$log" | grep -oE 'changed=[0-9]+' | awk -F= '{ s += $2 } END { print s + 0 }')
tasks=$(awk '/^(TASK|RUNNING HANDLER) \[/ { name = $0; sub(/^(TASK|RUNNING HANDLER) \[/, "", name); sub(/\] \**$/, "", name) }
  /^changed: / { print name }' "$log" | sort -u)
if [[ "$changed" -eq 0 ]]; then
  echo "PASS: second run changed=0"
elif [[ "$changed" -eq 1 && "$tasks" == "$TOLERATED" ]]; then
  echo "PASS: second run changed only the tolerated upstream task ($TOLERATED)"
else
  echo "FAIL: second run changed $changed task(s):" >&2
  printf '  changed: %s\n' "$tasks" >&2
  exit 1
fi
