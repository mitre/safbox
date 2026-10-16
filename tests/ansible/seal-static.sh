#!/usr/bin/env bash
# Static guards for the seal step's final privileged script, whose failure
# modes only show up in a full image build (the build user's own connection
# runs it). Usage: tests/ansible/seal-static.sh [path-to-finalize.sh.j2]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TPL=${1:-$ROOT/ansible/roles/seal/templates/finalize.sh.j2}

# The build user's connection starts the script in that user's home, which the
# script deletes. Anything after the deletion that resolves the working
# directory (CINC Auditor does) then fails with getcwd ENOENT. The script must
# leave the home directory before deleting the account.
cd_line=$(grep -nE '^[[:space:]]*cd /[[:space:]]*$' "$TPL" | head -1 | cut -d: -f1 || true)
del_line=$(grep -nE '^[[:space:]]*userdel ' "$TPL" | head -1 | cut -d: -f1 || true)
[ -n "$del_line" ] || { echo "FAIL: no userdel in $TPL" >&2; exit 1; }
if [ -z "$cd_line" ] || [ "$cd_line" -gt "$del_line" ]; then
  echo "FAIL: $TPL must 'cd /' before deleting the build user (line $del_line)" >&2; exit 1
fi

# The seal verifies its own effects before it returns (nothing outside can
# log in afterwards to check). Each post-condition must be asserted after the
# deletions and fail the script when unmet.
assert_start=$(grep -nE '^# Post-conditions' "$TPL" | head -1 | cut -d: -f1 || true)
if [ -z "$assert_start" ] || [ "$assert_start" -lt "$del_line" ]; then
  echo "FAIL: $TPL has no '# Post-conditions' section after deleting the build user" >&2; exit 1
fi
post=$(tail -n +"$assert_start" "$TPL")
# Root's tool residue is checked from the same variable step 3 deletes, not
# a second list.
for needle in 'getent passwd' 'ssh_host_' '/etc/machine-id' 'ks*.cfg' '/var/log/anaconda' '*.env' 'seal_firstboot_state' '/var/lib/cloud/instance' 'system-connections' 'sudoers' 'seal_tls_dir' 'seal_root_tool_residue'; do
  # Needles count only on code lines, not comments.
  post_code=$(grep -vE '^[[:space:]]*#' <<<"$post")
  grep -qF -- "$needle" <<<"$post_code" || { echo "FAIL: post-conditions do not check '$needle'" >&2; exit 1; }
done
# /tmp and /var/tmp are not checked here: this script runs from Ansible's
# own payload under /tmp, so the check would fail every seal
# (safbox-m5f.24). The scrub checks them instead, right after emptying them.
if grep -vE '^[[:space:]]*#' <<<"$post" | grep -qE 'seal_tmp_dirs|seal_tmp_keep|(^|[^[:alnum:]_])/(var/)?tmp([^[:alnum:]_]|$)'; then
  echo "FAIL: $TPL post-conditions check /tmp or /var/tmp, where this script's own Ansible payload lives" >&2; exit 1
fi
SCRUB=$(dirname "$TPL")/../tasks/scrub.yml
read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$SCRUB" <<'PY' || exit 1
import pathlib, sys, yaml
tasks = yaml.safe_load(open(sys.argv[1])) or []
names = [t.get("name", "") for t in tasks]
def idx(pred):
    return next((i for i, t in enumerate(tasks) if pred(t)), None)
remove = idx(lambda t: "ansible.builtin.file" in t and "seal_tmp_entries" in str(t.get("loop", "")))
# The scrub's own find uses the shared variables, not a second list.
scan = idx(lambda t: t.get("register") == "seal_tmp_entries")
if scan is None or tasks[scan].get("ansible.builtin.find", {}).get("paths") != "{{ seal_tmp_dirs }}" \
        or tasks[scan]["ansible.builtin.find"].get("excludes") != ["{{ seal_tmp_keep }}"]:
    sys.exit(f"FAIL: {sys.argv[1]} must find the temporary files with paths: \"{{{{ seal_tmp_dirs }}}}\" and excludes: [\"{{{{ seal_tmp_keep }}}}\"]")
# Every Ansible module unpacks its payload under /tmp while it runs, so the
# listing must come from ansible.builtin.raw (no payload) and the verdict
# from ansible.builtin.assert (runs on the controller).
listing = idx(lambda t: "seal_tmp_dirs" in str(t) and any(k in t for k in ("ansible.builtin.find", "ansible.builtin.raw", "ansible.builtin.command", "ansible.builtin.shell")) and remove is not None and tasks.index(t) > remove)
check = idx(lambda t: "ansible.builtin.assert" in t and "seal_tmp" in str(t))
if remove is None:
    sys.exit(f"FAIL: {sys.argv[1]} has no task removing the temporary files (loop over seal_tmp_entries)")
if listing is None or "ansible.builtin.raw" not in tasks[listing]:
    sys.exit(f"FAIL: {sys.argv[1]} must list /tmp and /var/tmp after removing them with ansible.builtin.raw (a module would find its own payload)")
want_raw = "find {{ seal_tmp_dirs | map('quote') | join(' ') }} -mindepth 1 -maxdepth 1 ! -name {{ seal_tmp_keep | quote }} -print"
if " ".join(str(tasks[listing]["ansible.builtin.raw"]).split()) != want_raw:
    sys.exit(f"FAIL: {sys.argv[1]} raw listing must be exactly: {want_raw}")
reg = tasks[listing].get("register")
if check is None or check < listing:
    sys.exit(f"FAIL: {sys.argv[1]} does not assert /tmp and /var/tmp are empty after listing them")
a = tasks[check]
if a["ansible.builtin.assert"].get("that") != ["seal_tmp_leftovers | length == 0"] \
        or (a.get("vars") or {}).get("seal_tmp_leftovers") != "{{ " + str(reg) + ".stdout_lines | map('trim') | select | list }}":
    sys.exit(f"FAIL: {sys.argv[1]} assert must be 'seal_tmp_leftovers | length == 0' over the raw listing's trimmed, non-empty stdout_lines")
NEUTERING = {"ignore_errors", "failed_when", "tags", "check_mode", "ignore_unreachable", "any_errors_fatal"}
for i in (listing, check):
    bad = NEUTERING & set(tasks[i])
    if bad:
        sys.exit(f"FAIL: {sys.argv[1]} task '{tasks[i].get('name')}' carries {sorted(bad)}, which can stop it failing the seal")
for i in (listing, check):
    if tasks[i].get("when") != "seal_mode == 'full'":
        sys.exit(f"FAIL: {sys.argv[1]} task '{tasks[i].get('name')}' must run in full mode only (when: seal_mode == 'full'; owner decision, development templates are not verified)")
defaults = yaml.safe_load(open(pathlib.Path(sys.argv[1]).parent.parent / "defaults/main.yml")) or {}
if defaults.get("seal_tmp_dirs") != ["/tmp", "/var/tmp"] or defaults.get("seal_tmp_keep") != "systemd-private-*":
    sys.exit("FAIL: seal defaults must scrub and check seal_tmp_dirs [/tmp, /var/tmp], keeping only seal_tmp_keep 'systemd-private-*'")
PY

# The residue variable must sit in the array the residue loop checks, not
# merely be named somewhere in the section.
residue_array=$(awk '/^residue=\(/{f=1} f{print} f && /\)$/{exit}' <<<"$post")
grep -qF 'seal_root_tool_residue' <<<"$residue_array" \
  || { echo "FAIL: seal_root_tool_residue is not in the residue=( ... ) array the post-conditions check" >&2; exit 1; }
grep -qE 'for f in "\$\{residue\[@\]\}"; do' <<<"$post" \
  || { echo "FAIL: the post-conditions do not loop over the residue array" >&2; exit 1; }

# fail() must stop the script, or every check below is decorative.
grep -qE '^fail\(\) \{.*exit 1; \}$' <<<"$post" || { echo "FAIL: fail() in the post-conditions does not exit 1" >&2; exit 1; }
# Every check must fail the script: each `if` in the section ends in `then fail`.
while IFS= read -r line; do
  case "$line" in
    *"then fail "*) ;;
    *) echo "FAIL: post-condition does not fail the script: $line" >&2; exit 1 ;;
  esac
done < <(grep -E '^[[:space:]]*if ' <<<"$post")

# The template must be valid Jinja (bash's ${#array[@]} opens a Jinja
# comment, for one). Parse it with the Jinja that ships with Ansible.
read -r -a ANSIBLE_PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${ANSIBLE_PY[@]}" - "$TPL" <<'PY' || { echo "FAIL: $TPL is not valid Jinja" >&2; exit 1; }
import sys, jinja2
jinja2.Environment().parse(open(sys.argv[1]).read())
PY

# Lint the template with each Jinja expression replaced by a distinct
# quoted word.
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
{ echo '#!/usr/bin/env bash'
  perl -pe 'BEGIN{$n=0} s/\{\{.*?\}\}/"\x27j".(++$n)."\x27"/ge; s/\{%.*?%\}//g' "$TPL"
} > "$rendered"
shellcheck -s bash "$rendered"
echo "PASS: seal finalize script leaves the build user's home first and passes shellcheck"
