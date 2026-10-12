#!/usr/bin/env bash
# Static checks for the RHEL 10 STIG overlay (ADR-0001 §Decision: encryption
# at rest). The overlay must include every control of the pinned MITRE
# baseline (no skip_control), mark the data-at-rest requirement Not
# Applicable through the baseline's own input, and explain why in a caveat.
# Included controls only resolve against a RHEL target (the baseline
# supports the redhat family alone), so this checks the profile's source and
# metadata; the live proof is a run against a clone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OVERLAY=${1:-$ROOT/verify/rhel10-stig-overlay}
command -v cinc-auditor >/dev/null || { echo "FAIL: cinc-auditor not installed" >&2; exit 1; }
test -f "$OVERLAY/inspec.yml" || { echo "FAIL: $OVERLAY/inspec.yml missing" >&2; exit 1; }

# CINC Auditor's embedded Ruby, as tests/verify/profile.sh uses.
RUBY=$(dirname "$(readlink -f "$(command -v cinc-auditor)" 2>/dev/null || command -v cinc-auditor)")/ruby
if [ ! -x "$RUBY" ]; then RUBY=/opt/cinc-auditor/embedded/bin/ruby; fi
if [ ! -x "$RUBY" ]; then RUBY=$(command -v ruby); fi
for f in "$OVERLAY"/controls/*.rb; do
  "$RUBY" -c "$f" >/dev/null || { echo "FAIL: $f does not parse" >&2; exit 1; }
done
# The profile and its pinned dependency resolve. check needs a vendored
# profile; vendor a scratch copy so the tree gains no lock file or vendor/.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$OVERLAY" "$work/overlay"
cinc-auditor vendor "$work/overlay" --chef-license accept-silent >/dev/null 2>&1 \
  || { echo "FAIL: cannot fetch the overlay's pinned dependency" >&2; exit 1; }
cinc-auditor check "$work/overlay" --chef-license accept-silent >/dev/null 2>&1 \
  || { echo "FAIL: cinc-auditor check of the overlay" >&2; exit 1; }

read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$OVERLAY" <<'PY'
import pathlib, re, sys, yaml
overlay = pathlib.Path(sys.argv[1])
meta = yaml.safe_load((overlay / "inspec.yml").read_text())
src = "\n".join(p.read_text() for p in sorted((overlay / "controls").glob("*.rb")))
BASE = "redhat-enterprise-linux-10-stig-baseline"
errors = []

dep = next((d for d in meta.get("depends") or [] if d.get("name") == BASE), None)
if not dep:
    errors.append("depends: the MITRE RHEL 10 baseline is not a dependency")
elif not (dep.get("git") and re.fullmatch(r"[0-9a-f]{40}", str(dep.get("ref", "")))):
    errors.append("depends: the baseline must be pinned by git URL and a full commit SHA as ref")

inputs = {(i.get("profile"), i.get("name")): i.get("value") for i in meta.get("inputs") or []}
if inputs.get((BASE, "data_at_rest_exempt")) is not True:
    errors.append(f"inputs: data_at_rest_exempt must be true for profile {BASE}")

if f"include_controls '{BASE}'" not in src:
    errors.append("controls: the overlay does not include_controls the baseline")
if "skip_control" in src:
    errors.append("controls: skip_control hides a baseline control; deviations are marked, never dropped")

m = re.search(r"control 'SV-280935' do(.*?)\n  end", src, re.S)
if not m:
    errors.append("controls: no SV-280935 (data at rest) override")
else:
    body = m.group(1)
    if "desc 'caveat'" not in body:
        errors.append("SV-280935: no caveat description")
    for needle in ["Not Applicable", "template", "hypervisor", "authorizing official",
                   "documented and approved reason for not having data-at-rest encryption"]:
        if needle.lower() not in body.lower():
            errors.append(f"SV-280935: caveat does not mention '{needle}'")
if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print("PASS: overlay includes the pinned baseline; SV-280935 is Not Applicable with a caveat")
PY
