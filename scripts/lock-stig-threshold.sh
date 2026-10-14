#!/usr/bin/env bash
# Lock the STIG state in a tracked threshold (ADR-0001 "Validation layout"):
# replace the STIG clauses of verify/thresholds/<context>.yml with the exact
# lists of STIG control IDs that pass and fail, per severity (high, medium,
# low), in a results file from scripts/validate.sh. The infrastructure
# clauses (passed.critical.controls, failed.critical, error) are kept as
# they are. Run it whenever the documented state changes on purpose, and
# review the diff: every control that moves shows up in it.
#
#   scripts/lock-stig-threshold.sh <build|release> <results.json>
#
# Needs the SAF CLI and ansible-core's Python (for PyYAML) on this machine.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONTEXT=${1:?context: build or release}
RESULTS=${2:?results JSON from scripts/validate.sh}
case "$CONTEXT" in build|release) ;; *) echo "lock-stig-threshold.sh: context must be build or release" >&2; exit 1 ;; esac
[[ -r "$RESULTS" ]] || { echo "lock-stig-threshold.sh: cannot read $RESULTS" >&2; exit 1; }
RESULTS=$(cd "$(dirname "$RESULTS")" && pwd)/$(basename "$RESULTS")
THRESHOLD="$ROOT/verify/thresholds/$CONTEXT.yml"
for tool in saf ansible-playbook; do
  command -v "$tool" >/dev/null || { echo "lock-stig-threshold.sh: $tool not found" >&2; exit 1; }
done

# The SAF CLI writes saf-cli.log to its working directory.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
(cd "$WORK" && saf generate threshold -i "$RESULTS" -c -o generated.yml >/dev/null)

read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$THRESHOLD" "$WORK/generated.yml" "$(basename "$RESULTS")" <<'PY'
import datetime, pathlib, re, sys, yaml
threshold, generated, source = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
SEVERITIES = ("high", "medium", "low")
PROVENANCE = "# STIG lists: "


class Dumper(yaml.SafeDumper):
    """Indents lists under their key, as yamllint (ansible/.yamllint) expects."""
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


current = yaml.safe_load(threshold.read_text())
gen = yaml.safe_load(generated.read_text())

# The leading comment block (comments and blank lines up to the first YAML
# key), without the previous provenance lines.
header = []
for line in threshold.read_text().splitlines():
    if line == "---":
        continue
    if line and not line.startswith("#"):
        break
    if not line.startswith(PROVENANCE):
        header.append(line)
while header and not header[-1]:
    header.pop()

# Results files are named validate-<label>-<UTC timestamp>.json, and a label
# can carry lab details (a clone's VM ID), so only the timestamp is recorded.
stamp_match = re.search(r"-(\d{8}T\d{6}Z)\.json$", source)
source = f"a scan taken {stamp_match.group(1)}" if stamp_match else "a scan (timestamp not in its file name)"

out = {"passed": {"critical": current["passed"]["critical"]},
       "failed": {"critical": current["failed"]["critical"]}}
counts = []
for status in ("passed", "failed"):
    for sev in SEVERITIES:
        ids = sorted((gen.get(status, {}).get(sev) or {}).get("controls") or [])
        out[status][sev] = {"controls": ids}
        counts.append(f"{sev} {status} {len(ids)}")
out["error"] = current["error"]

stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
provenance = [f"{PROVENANCE}generated {stamp} by scripts/lock-stig-threshold.sh",
              f"{PROVENANCE}from {source}",
              f"{PROVENANCE}" + ", ".join(f"{sev} {len(out['passed'][sev]['controls'])}/"
                                           f"{len(out['failed'][sev]['controls'])}" for sev in SEVERITIES)
              + " (passed/failed)"]
threshold.write_text("---\n" + "\n".join(header + provenance) + "\n"
                     + yaml.dump(out, Dumper=Dumper, sort_keys=False, default_flow_style=False))
print(f"lock-stig-threshold.sh: {threshold.name}: {', '.join(counts)}")
PY
