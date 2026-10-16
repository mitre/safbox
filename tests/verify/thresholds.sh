#!/usr/bin/env bash
# Thresholds and tracked inputs (ADR-0001 §Validation stages: thresholds).
#
# Every infrastructure control is impact 1.0 (critical) and STIG controls
# never are (CAT I is 0.7), so each tracked threshold lists the
# infrastructure controls a repository-default image passes in its context
# under passed.critical.controls, an exact set, with failed.critical.max 0
# and error.total.max 0. The STIG controls of the hardened image are held at
# their documented state: exact lists of which pass and which fail per
# severity (passed.<sev>.controls, failed.<sev>.controls, or max: 0 for an
# empty set), from scripts/lock-stig-threshold.sh.
#
# Static: for each context (build, release) the critical list must equal the
# el10-infrastructure controls whose only_if conditions hold for the
# profile's input defaults plus verify/inputs/<context>.yml, so adding,
# removing or re-gating a control without updating the threshold fails here.
# The exception is a documented finding: a known weakness recorded as a
# low-impact infrastructure control that fails on a repository-default
# image. Where it applies it must be listed in failed.low.controls, which
# lock-stig-threshold.sh fills from the scan like any low-severity failure.
#
# With the SAF CLI against recorded results (tests/verify/fixtures/): the
# critical clauses of each tracked threshold pass on the real result and
# fail when one infrastructure control fails, is missing, is skipped, or an
# extra one passes. The fixtures are the infrastructure part of real
# wrapper scans through scripts/validate.sh, trimmed by dropping whole
# elements with tests/verify/fixtures/trim-infrastructure.py:
#   build-infrastructure.json    build-time gate of a development build
#                                (repository defaults, seal = false)
#   release-infrastructure.json  release gate against a deployed clone of a
#                                full-sealed template, with the current
#                                appliance playbook applied to it
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIXTURES=$ROOT/tests/verify/fixtures
command -v saf >/dev/null || { echo "FAIL: the SAF CLI (saf) is not installed" >&2; exit 1; }
for p in el10-infrastructure safbox-rhel10-stig-overlay; do
  test -f "$ROOT/verify/$p/inspec.yml" || { echo "FAIL: verify/$p/inspec.yml missing" >&2; exit 1; }
done
read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"${PY[@]}" - "$ROOT" <<'PY'
import pathlib, re, sys, yaml
root = pathlib.Path(sys.argv[1])
verify = root / "verify"
errors = []

infra_meta = yaml.safe_load((verify / "el10-infrastructure/inspec.yml").read_text())
overlay_meta = yaml.safe_load((verify / "safbox-rhel10-stig-overlay/inspec.yml").read_text())
defaults = {i["name"]: i.get("value") for i in infra_meta.get("inputs") or []}
known_inputs = set(defaults) | {i["name"] for i in overlay_meta.get("inputs") or []}
group_vars = yaml.safe_load((root / "ansible/group_vars/all/main.yml").read_text())

# only_if conditions that depend on the target's state rather than an
# input, with the repository default that decides them. A new kind of
# condition must be added here before its control can be counted.
TARGET_STATE = {
    "file('/etc/containers/systemd/safbox-example.container').exist?":
        ("safbox_example_quadlet_enabled", "the smoke-test Quadlet unit is opt-in"),
}
for expr, (var, _why) in TARGET_STATE.items():
    if var not in group_vars:
        errors.append(f"group_vars: {var} (decides `{expr}`) is not defined")

def condition(expr, inputs, cid):
    expr = expr.strip()
    # One only_if may join conditions with && (InSpec reports a single skip
    # message, so a control gated on two things says both in one place).
    if "&&" in expr:
        return all([condition(part, inputs, cid) for part in expr.split("&&")])
    m = re.fullmatch(r"input\('(\w+)'\)", expr)
    if m:
        if m.group(1) not in inputs:
            errors.append(f"{cid}: only_if reads input {m.group(1)}, which el10-infrastructure does not declare")
            return False
        return bool(inputs[m.group(1)])
    m = re.fullmatch(r"tool_expected\.call\('([a-z-]+)'\)", expr)
    if m:
        return m.group(1) in [str(t) for t in inputs.get("expected_tools") or []]
    m = re.fullmatch(r"service_expected\.call\('([a-z-]+)'\)", expr)
    if m:
        return m.group(1) in [str(s) for s in inputs.get("expected_services") or []]
    if expr in TARGET_STATE:
        return bool(group_vars.get(TARGET_STATE[expr][0]))
    errors.append(f"{cid}: unclassified only_if condition `{expr}`; teach tests/verify/thresholds.sh how a "
                  "repository-default image decides it")
    return False

# Control ID -> list of only_if condition expressions, from the source.
# Every infrastructure control is impact 1.0 except documented findings:
# known weaknesses recorded as low-severity controls that fail on a
# repository-default image (tests/verify/profile.sh checks their shape).
MESSAGE = r"'(?:[^'\\]|\\.)*'"
controls = {}
findings = set()
for path in sorted((verify / "el10-infrastructure/controls").glob("*.rb")):
    src = path.read_text()
    for m in re.finditer(r"^control '([^']+)' do\n(.*?)^end$", src, re.S | re.M):
        cid, body = m.group(1), m.group(2)
        # only_if('<message>') { <condition> } or a do ... end block.
        conds = re.findall(rf"only_if\({MESSAGE}\)\s*\{{(.*?)\}}", body, re.S)
        conds += re.findall(rf"only_if\({MESSAGE}\)\s*do\n(.*?)\n\s*end\n", body, re.S)
        if body.count("only_if") != len(conds):
            errors.append(f"{cid}: an only_if this test cannot parse")
        if cid in controls:
            errors.append(f"{cid}: declared twice")
        controls[cid] = conds
        impact = re.search(r"^\s*impact (\d+(?:\.\d+)?)\s*$", body, re.M)
        if not impact:
            errors.append(f"{cid}: no literal impact this test can read")
        elif float(impact.group(1)) != 1.0:
            findings.add(cid)
if not controls:
    errors.append("el10-infrastructure: no controls found")

SEVERITIES = ("high", "medium", "low")
for ctx in ("build", "release"):
    tpath, ipath = verify / f"thresholds/{ctx}.yml", verify / f"inputs/{ctx}.yml"
    if not tpath.exists() or not ipath.exists():
        errors.append(f"{ctx}: {tpath.relative_to(root)} and {ipath.relative_to(root)} must both exist")
        continue
    ctx_inputs = yaml.safe_load(ipath.read_text()) or {}
    for name in sorted(set(ctx_inputs) - known_inputs):
        errors.append(f"{ipath.relative_to(root)}: {name} is not an input of el10-infrastructure or the overlay")
    inputs = {**defaults, **ctx_inputs}
    applies = sorted(c for c, conds in controls.items() if all([condition(e, inputs, c) for e in conds]))
    applicable = [c for c in applies if c not in findings]
    applicable_findings = {c for c in applies if c in findings}

    t = yaml.safe_load(tpath.read_text()) or {}
    passed, failed, error = t.get("passed") or {}, t.get("failed") or {}, t.get("error") or {}
    listed = (passed.get("critical") or {}).get("controls")
    if not isinstance(listed, list):
        errors.append(f"{ctx}: passed.critical.controls must list the infrastructure controls")
        listed = []
    if len(listed) != len(set(listed)):
        errors.append(f"{ctx}: passed.critical.controls lists a control twice")
    if set(passed.get("critical") or {}) != {"controls"}:
        errors.append(f"{ctx}: passed.critical holds only the exact controls list")
    for missing in sorted(set(applicable) - set(listed)):
        errors.append(f"{ctx}: {missing} applies to a repository-default image here but is not in passed.critical.controls")
    for extra in sorted(set(listed) - set(applicable)):
        errors.append(f"{ctx}: {extra} is in passed.critical.controls but does not apply here (or does not exist)")
    if failed.get("critical") != {"max": 0}:
        errors.append(f"{ctx}: failed.critical must be exactly max: 0")
    if error != {"total": {"max": 0}}:
        errors.append(f"{ctx}: error must be exactly total.max: 0")
    # STIG: the documented state, as exact lists of which controls pass and
    # which fail per severity (scripts/lock-stig-threshold.sh).
    stig_ids = {}
    for status, clauses in (("passed", passed), ("failed", failed)):
        for sev in SEVERITIES:
            clause = clauses.get(sev) or {}
            ids = clause.get("controls")
            # The SAF CLI cannot judge an empty controls list (it reports the
            # received list as undefined and fails), so an empty set is
            # written as max: 0, which is the same exact set.
            if clause == {"max": 0}:
                continue
            if set(clause) != {"controls"} or not isinstance(ids, list) or not ids:
                errors.append(f"{ctx}: {status}.{sev} must hold exactly a non-empty controls list, or max: 0 "
                              "for none (scripts/lock-stig-threshold.sh)")
                continue
            for cid in ids:
                if cid in stig_ids:
                    errors.append(f"{ctx}: {cid} is listed under both {stig_ids[cid]} and {status}.{sev}")
                stig_ids[cid] = f"{status}.{sev}"
    # A documented finding that applies here fails on a repository-default
    # image, so it sits in failed.low (where lock-stig-threshold.sh puts
    # it) and nowhere else; any other infrastructure control in a STIG
    # clause is an error.
    for cid in sorted(applicable_findings):
        if stig_ids.get(cid) != "failed.low":
            errors.append(f"{ctx}: finding {cid} applies here but is not in failed.low.controls")
    for cid in sorted((set(stig_ids) & set(controls)) - applicable_findings):
        errors.append(f"{ctx}: infrastructure control {cid} is listed in a STIG clause")
    if not stig_ids:
        errors.append(f"{ctx}: no STIG controls are locked")
    if not errors:
        print(f"{ctx}: {len(listed)} infrastructure controls listed, matching the controls that apply")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
PY

# The critical clauses against recorded results. A copy of each tracked
# threshold with only its critical and error clauses is checked, because the
# fixtures hold only the infrastructure controls.
"${PY[@]}" - "$ROOT" "$FIXTURES" "$work" <<'PY'
import copy, json, pathlib, subprocess, sys, yaml
root, fixtures, work = (pathlib.Path(a) for a in sys.argv[1:4])
errors = []

def controls_by_id(hdf, cid):
    return [c for p in hdf["profiles"] for c in p.get("controls") or [] if c.get("id") == cid]

def saf_passes(hdf, threshold, name):
    results, tfile = work / f"{name}.json", work / f"{name}.threshold.yml"
    results.write_text(json.dumps(hdf))
    tfile.write_text(yaml.safe_dump(threshold))
    # The SAF CLI writes saf-cli.log to its working directory.
    run = subprocess.run(["saf", "validate", "threshold", "-i", str(results), "-T", str(tfile)],
                         cwd=work, capture_output=True, text=True)
    return run.returncode == 0, (run.stdout + run.stderr).strip()

for ctx in ("build", "release"):
    fixture = fixtures / f"{ctx}-infrastructure.json"
    if not fixture.exists():
        errors.append(f"{ctx}: no recorded results at {fixture.relative_to(root)}"); continue
    tracked = yaml.safe_load((root / f"verify/thresholds/{ctx}.yml").read_text())
    listed = tracked["passed"]["critical"]["controls"]
    threshold = {"passed": {"critical": {"controls": listed}},
                 "failed": {"critical": {"max": 0}},
                 "error": {"total": {"max": 0}}}
    real = json.loads(fixture.read_text())
    ok, out = saf_passes(real, threshold, f"{ctx}-real")
    if not ok:
        errors.append(f"{ctx}: the recorded result does not meet the critical clauses:\n{out}"); continue
    print(f"{ctx}: recorded result meets the critical clauses ({len(listed)} controls)")

    victim = listed[0]
    cases = {}
    hdf = copy.deepcopy(real)
    for c in controls_by_id(hdf, victim):
        for r in c["results"]:
            r["status"] = "failed"; r["message"] = "fixture: forced failure"
    cases[f"{victim} fails"] = hdf
    hdf = copy.deepcopy(real)
    for p in hdf["profiles"]:
        p["controls"] = [c for c in p.get("controls") or [] if c.get("id") != victim]
    cases[f"{victim} is missing"] = hdf
    hdf = copy.deepcopy(real)
    for c in controls_by_id(hdf, victim):
        if c.get("results"):  # the wrapper's own entry carries no results
            c["results"] = [{"status": "skipped", "code_desc": "fixture: forced skip", "run_time": 0,
                             "start_time": c["results"][0]["start_time"], "skip_message": "fixture: forced skip"}]
    cases[f"{victim} is skipped"] = hdf
    # A control outside the list that passes breaks the exact set too.
    outsider = next((c["id"] for p in real["profiles"] for c in p.get("controls") or []
                     if c.get("impact") == 1.0 and c["id"] not in listed), None)
    if outsider is None:
        errors.append(f"{ctx}: the fixture has no skipped infrastructure control to promote")
    else:
        hdf = copy.deepcopy(real)
        for c in controls_by_id(hdf, outsider):
            if c.get("results"):
                c["results"] = [{"status": "passed", "code_desc": "fixture: forced pass", "run_time": 0,
                                 "start_time": c["results"][0]["start_time"]}]
        cases[f"{outsider} passes as well"] = hdf
    for label, mutated in cases.items():
        ok, out = saf_passes(mutated, threshold, f"{ctx}-{label.replace(' ', '-')}")
        if ok:
            errors.append(f"{ctx}: the critical clauses still pass when {label}")
        elif "Failed to convert" in out or "Error:" not in out:  # a verdict, not an unreadable file
            errors.append(f"{ctx}: the SAF CLI did not judge the results when {label}:\n{out}")
        else:
            print(f"{ctx}: fails as it must when {label}")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print("PASS: thresholds list exactly the infrastructure controls that apply; the SAF CLI enforces the exact set")
PY
