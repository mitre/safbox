#!/usr/bin/env bash
# A failing first-boot step (ansible/firstboot/step.yml) stops the play
# under its own name, and a no_log task's failure leaves none of its values
# in the output: ansible_failed_result is not censored for the rescue, so
# the step must not print it. A failing hook, which is not no_log, still
# shows its error. Runs step.yml locally with ansible-playbook -c local and
# two throwaway steps; nothing is changed outside a temporary directory.
#
#   tests/ansible/firstboot-step.sh            the repository's step.yml
#   FIRSTBOOT_STEP=/path/step.yml tests/ansible/firstboot-step.sh
#                                              another copy (on a box: the
#                                              installed play's, with the
#                                              box's own ansible-core)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STEP=${FIRSTBOOT_STEP:-$ROOT/ansible/firstboot/step.yml}
[[ -r "$STEP" ]] || { echo "FAIL: $STEP is not readable" >&2; exit 1; }
command -v ansible-playbook >/dev/null || { echo "FAIL: ansible-playbook not installed" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
secret="not-a-real-secret-$RANDOM$RANDOM"
mkdir -p "$work/roles/leaky/tasks" "$work/roles/leaky_block/tasks" "$work/hooks"

# A role whose no_log task fails with the secret in its message and stderr.
cat > "$work/roles/leaky/tasks/main.yml" <<EOF
---
- name: Fail while holding a secret
  ansible.builtin.command:
    argv: [sh, -c, 'echo "$secret" >&2; exit 3', '$secret']
  changed_when: false
  no_log: true
EOF
# The same, with no_log templated on an enclosing block.
cat > "$work/roles/leaky_block/tasks/main.yml" <<EOF
---
- name: Hold a secret
  no_log: "{{ leaky_secret_flag | default(true) }}"
  block:
    - name: Fail inside a no_log block
      ansible.builtin.command:
        argv: [sh, -c, 'echo "$secret" >&2; exit 3', '$secret']
      changed_when: false
EOF
# A hook that fails with a diagnostic, which the step must show.
cat > "$work/hooks/20-noisy.sh" <<'EOF'
#!/bin/sh
echo "hook diagnostic: disk full" >&2
exit 4
EOF
chmod 0755 "$work/hooks/20-noisy.sh"
cat > "$work/play.yml" <<EOF
---
- name: One first-boot step
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    firstboot_role_by_step: {15-leaky: leaky, 16-leaky-block: leaky_block}
    firstboot_hook_dir: $work/hooks
  tasks:
    - name: Run the step
      ansible.builtin.include_tasks: $STEP
EOF

# run STEP-NAME: run the play for one step; its output is in $work/out.
run() {
  local rc=0
  ANSIBLE_ROLES_PATH="$work/roles" ANSIBLE_LOCAL_TMP="$work/tmp" ANSIBLE_REMOTE_TMP="$work/tmp" \
    ANSIBLE_NOCOLOR=1 ANSIBLE_RETRY_FILES_ENABLED=0 \
    ansible-playbook -i localhost, -c local "$work/play.yml" -e "firstboot_step=$1" > "$work/out" 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || { echo "FAIL: step $1 should have failed"; cat "$work/out"; return 1; }
}

fail=0
run 15-leaky
grep -q "first-boot step 15-leaky failed at 'Fail while holding a secret'" "$work/out" \
  || { echo "FAIL: the failure does not name the step and task"; fail=1; }
if grep -qF -e "$secret" "$work/out"; then
  echo "FAIL: a no_log task's value reached the output:"
  grep -F -e "$secret" "$work/out" | sed "s/$secret/<secret>/g"
  fail=1
fi
run 16-leaky-block
grep -q "first-boot step 16-leaky-block failed at 'Fail inside a no_log block'" "$work/out" \
  || { echo "FAIL: the block step's failure does not name the step and task"; fail=1; }
if grep -qF -e "$secret" "$work/out"; then
  echo "FAIL: a no_log block's value reached the output:"
  grep -F -e "$secret" "$work/out" | sed "s/$secret/<secret>/g"
  fail=1
fi
run 20-noisy.sh
grep -q "first-boot step 20-noisy.sh failed at .*hook diagnostic: disk full" "$work/out" \
  || { echo "FAIL: a failing hook's error is not shown"; sed -n '/fatal/,$p' "$work/out"; fail=1; }

[[ $fail -eq 0 ]] || exit 1
echo "PASS: first-boot step failures are named; no_log values stay out ($(ansible-playbook --version | head -1))"
