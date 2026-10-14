#!/usr/bin/env bash
# Static checks for the appliance layer: yamllint, ansible-lint (production
# profile, no skips), a syntax check of both playbooks, and shellcheck on the
# scripts the roles install. No target host is needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

for tool in yamllint ansible-lint ansible-playbook shellcheck saf; do
  command -v "$tool" >/dev/null || {
    echo "FAIL: $tool not installed (pipx install --include-deps ansible; pipx inject --include-apps ansible ansible-lint yamllint; brew install shellcheck; npm install -g @mitre/saf)" >&2
    exit 1
  }
done

echo "== yamllint"
yamllint -c ansible/.yamllint --strict ansible/ verify/

echo "== ansible-lint (production profile)"
(cd ansible && ansible-lint -c .ansible-lint .)

echo "== no lint skip comments"
if grep -rnE 'noqa|skip_ansible_lint|yamllint disable|shellcheck disable' ansible/ verify/; then
  echo "FAIL: lint skip comments are not allowed (ADR-0001 Quality Standards)" >&2
  exit 1
fi

echo "== ansible-playbook --syntax-check"
(cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check -i inventory/example.ini \
  playbooks/safbox.yml playbooks/seal.yml)

echo "== shellcheck"
find ansible/roles -path '*/files/*' -type f -print0 | xargs -0 shellcheck --shell=bash --external-sources
shellcheck --external-sources tests/ansible/*.sh tests/verify/*.sh tests/services/*.sh \
  tests/platform-discipline.sh scripts/*.sh

echo "== seal finalize template"
tests/ansible/seal-static.sh

echo "== pinned inputs"
tests/ansible/pins.sh

echo "== task-group structure"
tests/ansible/structure.sh

echo "== validation profiles (wrapper and children)"
tests/verify/profile.sh

echo "== validation thresholds and inputs"
tests/verify/thresholds.sh

echo "== RHEL 10 STIG overlay"
tests/verify/overlay.sh

echo "== on-box exercise profiles (FIPS exercise, first boot)"
tests/verify/onbox.sh

echo "PASS: appliance layer lint"
