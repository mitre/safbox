#!/usr/bin/env bash
# Static checks with the standard linters: yamllint, ansible-lint (production
# profile), a syntax check of both playbooks, shellcheck, packer validate and
# cinc-auditor check on the two validation profiles. No target host needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

echo "== yamllint"
yamllint -c ansible/.yamllint --strict ansible/ verify/

echo "== ansible-lint (production profile)"
(cd ansible && ansible-lint -c .ansible-lint .)

echo "== ansible-playbook --syntax-check"
(cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check -i inventory/example.ini \
  playbooks/safbox.yml playbooks/seal.yml)

echo "== shellcheck"
# The roles' files include images and text; only the shell scripts (a shell
# shebang or a shellcheck shell directive on the first line) are checked.
find ansible/roles -path '*/files/*' -type f -exec awk 'FNR == 1 && /^(#!.*sh|# shellcheck shell=)/ { printf "%s\0", FILENAME } { nextfile }' {} + \
  | xargs -0 shellcheck --shell=bash --external-sources
# The test stubs are named after the programs they stand in for (packer,
# curl, ...), so most have no .sh suffix; their directory is listed too.
git ls-files -z -- '*.sh' 'tests/scripts/stubs/*' | xargs -0 shellcheck --external-sources

echo "== packer validate"
tests/packer/validate.sh

echo "== cinc-auditor check"
# check wants dependencies vendored (the overlay's baseline is fetched from
# GitHub); the vendor directory and lockfile are removed again afterwards so
# no scan reads a stale copy.
for profile in verify/profiles/safbox verify/profiles/safbox-rhel10-stig-overlay; do
  cinc-auditor vendor "$profile" --overwrite --chef-license accept-silent
  cinc-auditor check "$profile" --chef-license accept-silent
  rm -rf "$profile/vendor" "$profile/inspec.lock"
done

echo "PASS: lint"
