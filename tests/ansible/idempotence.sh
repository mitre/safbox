#!/usr/bin/env bash
# Idempotence check: a second run must report zero changed tasks. Runs
# playbooks/safbox.yml twice against one host and fails if the second run
# changed anything. Arguments are passed to both runs, e.g.
# -e safbox_example_quadlet_enabled=true. Requires:
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
#   tests/ansible/idempotence.sh --analyse <second-run log>   (judge a recorded log only)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TOLERATED='RHEL10-STIG : POST | Warning a reboot required but skip option set'

# Judge a second-run log: no failures, and every change is the tolerated task.
analyse() { # log
  local log=$1 recap changed_total changed_tasks other count task
  recap=$(sed -n '/^PLAY RECAP/,$p' "$log" | grep -E 'ok=[0-9]+' || true)
  [[ -n "$recap" ]] || { echo "FAIL: no PLAY RECAP found in second run" >&2; return 1; }
  if grep -qE '(failed|unreachable)=[1-9]' <<<"$recap"; then
    echo "FAIL: second run reported failures:" >&2
    echo "$recap" >&2
    return 1
  fi
  changed_total=$(grep -oE 'changed=[0-9]+' <<<"$recap" | awk -F= '{ s += $2 } END { print s + 0 }')
  # Each changed result is attributed to the TASK or HANDLER header above it,
  # once per task (a loop prints a changed line per item; the recap counts
  # the task once).
  changed_tasks=$(awk '
    /^(TASK|RUNNING HANDLER) \[/ { name = $0; sub(/^(TASK|RUNNING HANDLER) \[/, "", name); sub(/\] \**$/, "", name); seen = 0 }
    /^changed: / && !seen { print name; seen = 1 }' "$log")
  count=$(grep -c . <<<"$changed_tasks" || true)
  if [[ "$count" -ne "$changed_total" ]]; then
    echo "FAIL: the recap counts $changed_total change(s) but $count changed result(s) were found in the log" >&2
    return 1
  fi
  other=$(grep -vxF "$TOLERATED" <<<"$changed_tasks" || true)
  if [[ -n "$other" ]] || [[ "$count" -gt 1 ]]; then
    echo "FAIL: second run reported changes:" >&2
    echo "$recap" >&2
    while IFS= read -r task; do echo "  changed: $task" >&2; done <<<"$changed_tasks"
    return 1
  fi
  if [[ "$count" -eq 1 ]]; then
    echo "PASS: second run changed only the tolerated upstream task ($TOLERATED)"
  else
    echo "PASS: second run changed=0"
  fi
}

if [[ "${1:-}" == "--analyse" ]]; then
  [[ -r "${2:-}" ]] || { echo "usage: $0 --analyse <second-run log>" >&2; exit 2; }
  analyse "$2"
  exit $?
fi

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
analyse "$log"
