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
for needle in 'getent passwd' 'ssh_host_' '/etc/machine-id' 'ks*.cfg' '/var/log/anaconda' '*.env' 'seal_firstboot_state' '/var/lib/cloud/instance' 'system-connections' 'sudoers' 'seal_tls_dir'; do
  grep -qF -- "$needle" <<<"$post" || { echo "FAIL: post-conditions do not check '$needle'" >&2; exit 1; }
done
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
