#!/usr/bin/env bash
# Static checks with the standard linters: yamllint, ansible-lint (production
# profile), a syntax check of the three playbooks, shellcheck, packer validate and
# cinc-auditor check on the three validation profiles. No target host needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

echo "== yamllint"
yamllint -c .yamllint --strict ansible/ verify/

echo "== ansible-lint (production profile)"
(cd ansible && ansible-lint -c .ansible-lint --yamllint-file ../.yamllint .)

echo "== ansible-playbook --syntax-check"
(cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check -i inventory/example.ini \
  playbooks/safbox.yml playbooks/seal.yml)
# The first-boot play the template_os role ships, with the clone_ roles
# from the same roles directory.
(cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check -i localhost, -c local \
  playbooks/firstboot.yml)

echo "== shellcheck"
# The roles' files, the template_ and the clone_ roles', include images
# and text; only the shell scripts (a shell shebang or a shellcheck shell
# directive on the first line) are checked.
find ansible/roles -path '*/files/*' -type f -exec awk 'FNR == 1 && /^(#!.*sh|# shellcheck shell=)/ { printf "%s\0", FILENAME } { nextfile }' {} + \
  | xargs -0 shellcheck --shell=bash
# Tracked and new files alike, but only those still on disk.
mapfile -d '' scripts < <(git ls-files -z -co --exclude-standard -- '*.sh')
existing=()
for f in "${scripts[@]}"; do [ -f "$f" ] && existing+=("$f"); done
shellcheck --external-sources "${existing[@]}"

echo "== packer validate"
tests/packer/validate.sh

echo "== cinc-auditor check"
# check wants dependencies vendored (the overlay's baseline is fetched from
# GitHub); the vendor directory and lockfile are removed again afterwards so
# no scan reads a stale copy.
for profile in verify/profiles/safbox verify/profiles/safbox-rhel10-stig-overlay verify/profiles/safbox-client; do
  cinc-auditor vendor "$profile" --overwrite --chef-license accept-silent
  cinc-auditor check "$profile" --chef-license accept-silent
  rm -rf "$profile/vendor" "$profile/inspec.lock"
done

echo "PASS: lint"
