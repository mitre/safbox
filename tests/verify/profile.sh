#!/usr/bin/env bash
# Static checks for the validation profiles (ADR-0001 §Validation stages:
# one root wrapper over per-family children).
#
#   verify/inspec-safbox         root wrapper: depends on every child by path,
#                                includes each one's controls, declares no
#                                platform support of its own and no controls
#   verify/el10-infrastructure   SAFBox infrastructure controls for the RHEL 10
#                                family, every one impact 1.0 (critical)
#   verify/safbox-rhel10-stig-overlay   the STIG overlay (tests/verify/overlay.sh)
#
# `cinc-auditor check` skips a control file that fails to parse and still
# reports the profile valid, so syntax is checked directly, and every control
# declared in el10-infrastructure must be loaded. `cinc-auditor json` does
# not resolve a dependency's controls, so the wrapper is checked by its
# metadata and source, and resolved with a vendored scratch copy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERIFY=${1:-$ROOT/verify}
WRAPPER=$VERIFY/inspec-safbox
INFRA=$VERIFY/el10-infrastructure
OVERLAY=$VERIFY/safbox-rhel10-stig-overlay
command -v cinc-auditor >/dev/null || { echo "FAIL: cinc-auditor not installed" >&2; exit 1; }
for p in "$WRAPPER" "$INFRA" "$OVERLAY"; do
  test -f "$p/inspec.yml" || { echo "FAIL: $p/inspec.yml missing" >&2; exit 1; }
done

# CINC Auditor's embedded Ruby, so the syntax is checked by the parser that
# will load the profiles.
RUBY=$(dirname "$(readlink -f "$(command -v cinc-auditor)" 2>/dev/null || command -v cinc-auditor)")/ruby
if [ ! -x "$RUBY" ]; then RUBY=/opt/cinc-auditor/embedded/bin/ruby; fi
if [ ! -x "$RUBY" ]; then RUBY=$(command -v ruby); fi

fails=0
for f in "$WRAPPER"/controls/*.rb "$INFRA"/controls/*.rb "$OVERLAY"/controls/*.rb; do
  if ! out=$("$RUBY" -c "$f" 2>&1); then
    echo "FAIL: $f does not parse: $out" >&2; fails=1
  fi
done
[ "$fails" -eq 0 ] || exit 1

# Every control declared in el10-infrastructure is loaded, and the loaded
# profile is handed to the metadata checks below.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cinc-auditor json "$INFRA" --chef-license accept-silent 2>/dev/null >"$work/infra.json"
declared=$(cat "$INFRA"/controls/*.rb | grep -cE "^control '")
loaded=$("$RUBY" -rjson -e "puts JSON.parse(File.read(ARGV[0]))['controls'].length" "$work/infra.json")
if [ "$declared" != "$loaded" ]; then
  echo "FAIL: el10-infrastructure declares $declared controls but $loaded load" >&2; exit 1
fi

read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$VERIFY" "$work/infra.json" <<'PY'
import json, pathlib, re, sys, yaml
verify = pathlib.Path(sys.argv[1])
infra_json = json.loads(pathlib.Path(sys.argv[2]).read_text())
errors = []

def meta(name):
    return yaml.safe_load((verify / name / "inspec.yml").read_text()) or {}

def source(name):
    return "\n".join(p.read_text() for p in sorted((verify / name / "controls").glob("*.rb")))

wrapper, infra, overlay = meta("inspec-safbox"), meta("el10-infrastructure"), meta("safbox-rhel10-stig-overlay")

# el10-infrastructure: RHEL 10 family only, every control critical.
if infra.get("supports") != [{"platform-family": "redhat", "release": "10.*"}]:
    errors.append(f"el10-infrastructure: supports must be exactly redhat family release 10.* (is {infra.get('supports')})")
controls = infra_json.get("controls") or []
if not controls:
    errors.append("el10-infrastructure: no controls loaded")
for c in controls:
    if c.get("impact") != 1.0:
        errors.append(f"el10-infrastructure: {c['id']} has impact {c.get('impact')}; every infrastructure control is 1.0")
ids = [c["id"] for c in controls]
if len(ids) != len(set(ids)):
    errors.append("el10-infrastructure: duplicate control IDs")

# The wrapper: depends on each child by path, includes each child's
# controls, narrows no platform and holds no controls or inputs of its own
# (a child that does not match the target is skipped by its own supports).
children = {"el10-infrastructure": infra["name"], "safbox-rhel10-stig-overlay": overlay["name"]}
deps = {d.get("name"): d for d in wrapper.get("depends") or []}
for directory, name in children.items():
    dep = deps.get(name)
    if not dep:
        errors.append(f"inspec-safbox: does not depend on {name}")
    elif dep.get("path") != f"../{directory}" or set(dep) != {"name", "path"}:
        errors.append(f"inspec-safbox: {name} must be a path dependency on ../{directory} (is {dep})")
if set(deps) != set(children.values()):
    errors.append(f"inspec-safbox: depends on {sorted(deps)}; expected exactly {sorted(children.values())}")
if "supports" in wrapper:
    errors.append("inspec-safbox: the wrapper declares supports; platform support belongs to each child")
if wrapper.get("inputs"):
    errors.append("inspec-safbox: the wrapper declares inputs; inputs belong to the child that reads them")
src = source("inspec-safbox")
for name in children.values():
    if not re.search(rf"^include_controls '{re.escape(name)}'$", src, re.M):
        errors.append(f"inspec-safbox: does not include_controls '{name}' (whole, without a block)")
if re.search(r"^\s*control '", src, re.M) or "skip_control" in src or "require_controls" in src:
    errors.append("inspec-safbox: the wrapper only includes its children; no controls, skips or partial requires")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print(f"PASS: el10-infrastructure loads all {len(ids)} declared controls at impact 1.0 for redhat 10.*; "
      "inspec-safbox depends on and includes both children")
PY

# The wrapper resolves: vendor a scratch copy of verify/ (the path
# dependencies are relative) so the tree gains no lock file or vendor/, then
# check it. Needs the network for the overlay's pinned baseline.
cp -R "$VERIFY" "$work/verify"
find "$work/verify" \( -name inspec.lock -o -name vendor \) -prune -exec rm -rf {} +
cinc-auditor vendor "$work/verify/inspec-safbox" --chef-license accept-silent >/dev/null 2>&1 \
  || { echo "FAIL: cannot vendor the wrapper's dependencies" >&2; exit 1; }
cinc-auditor check "$work/verify/inspec-safbox" --chef-license accept-silent >/dev/null 2>&1 \
  || { echo "FAIL: cinc-auditor check of the wrapper" >&2; exit 1; }
cinc-auditor check "$work/verify/el10-infrastructure" --chef-license accept-silent >/dev/null 2>&1 \
  || { echo "FAIL: cinc-auditor check of el10-infrastructure" >&2; exit 1; }
echo "PASS: the wrapper and el10-infrastructure resolve and pass cinc-auditor check"
