#!/usr/bin/env bash
# Static checks for the on-box exercise profiles (ADR-0001 Verification
# Strategy: on-box exercises). Each runs alone through scripts/validate.sh
# with its own threshold and inputs file, never through the release-gate
# wrapper: the FIPS exercise needs outbound HTTPS and the first-boot test
# writes (and removes) a scratch tree on the target.
#
#   verify/el10-fips-exercise  one control per tool exercising TLS or hashing
#                              under FIPS enforcement (safbox-fips-exercise-<n>,
#                              impact 1.0), and one per tool on whether its
#                              crypto is the system OpenSSL FIPS provider
#                              (safbox-fips-provider-<n>, low impact). A
#                              provider control tagged with an issue is a
#                              known finding: it fails by design and its
#                              threshold names it under failed.low.controls.
#   verify/el10-firstboot      the first-boot runner and secrets library
#                              exercised in a scratch tree, impact 1.0
#
# As tests/verify/profile.sh does for the wrapper's children: syntax with
# CINC Auditor's Ruby, every declared control loaded, cinc-auditor check,
# impacts, supports, inputs files naming only declared inputs, every FIPS
# exercise control asserting FIPS enforcement with no skip but a tool left
# out of expected_tools, and each threshold listing exactly the controls by
# status. The thresholds are then
# run with the SAF CLI against a recorded result
# (tests/verify/fixtures/fips-exercise.json, a real scan trimmed with
# tests/verify/fixtures/trim-onbox.py): it passes, and fails when a tool's
# control fails, a known finding passes, or another provider control fails.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERIFY=${1:-$ROOT/verify}
FIXTURES=$ROOT/tests/verify/fixtures
PROFILES=(el10-fips-exercise el10-firstboot)
for tool in cinc-auditor saf; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not installed" >&2; exit 1; }
done
for p in "${PROFILES[@]}"; do
  test -f "$VERIFY/$p/inspec.yml" || { echo "FAIL: verify/$p/inspec.yml missing" >&2; exit 1; }
done

# CINC Auditor's embedded Ruby, as tests/verify/profile.sh uses.
RUBY=$(dirname "$(readlink -f "$(command -v cinc-auditor)" 2>/dev/null || command -v cinc-auditor)")/ruby
if [ ! -x "$RUBY" ]; then RUBY=/opt/cinc-auditor/embedded/bin/ruby; fi
if [ ! -x "$RUBY" ]; then RUBY=$(command -v ruby); fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for p in "${PROFILES[@]}"; do
  for f in "$VERIFY/$p"/controls/*.rb; do
    out=$("$RUBY" -c "$f" 2>&1) || { echo "FAIL: $f does not parse: $out" >&2; exit 1; }
  done
  cinc-auditor check "$VERIFY/$p" --chef-license accept-silent >/dev/null 2>&1 \
    || { echo "FAIL: cinc-auditor check of verify/$p" >&2; exit 1; }
  cinc-auditor json "$VERIFY/$p" --chef-license accept-silent 2>/dev/null >"$work/$p.json"
  declared=$(cat "$VERIFY/$p"/controls/*.rb | grep -cE "^control '")
  loaded=$("$RUBY" -rjson -e "puts JSON.parse(File.read(ARGV[0]))['controls'].length" "$work/$p.json")
  if [ "$declared" != "$loaded" ]; then
    echo "FAIL: verify/$p declares $declared controls but $loaded load" >&2; exit 1
  fi
done

read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$ROOT" "$VERIFY" "$work" "$FIXTURES" <<'PY'
import copy, json, pathlib, re, subprocess, sys, yaml
root, verify, work, fixtures = (pathlib.Path(a) for a in sys.argv[1:5])
errors = []

def loaded(name):
    return json.loads((work / f"{name}.json").read_text())

def meta(name):
    return yaml.safe_load((verify / name / "inspec.yml").read_text()) or {}

def is_low(impact):  # the SAF CLI's low band
    return isinstance(impact, float) and 0.1 <= impact < 0.4

expected = {}  # profile -> {status.severity: [ids]}

# The FIPS exercise: per tool group n, safbox-fips-exercise-n (impact 1.0)
# and safbox-fips-provider-n (low). A provider control with an issue tag is
# a known finding (a tool whose crypto bypasses the system FIPS provider).
fips = loaded("el10-fips-exercise")
by_id = {c["id"]: c for c in fips.get("controls") or []}
exercise = sorted(i for i in by_id if re.fullmatch(r"safbox-fips-exercise-\d+", i))
provider = sorted(i for i in by_id if re.fullmatch(r"safbox-fips-provider-\d+", i))
for cid in sorted(set(by_id) - set(exercise) - set(provider)):
    errors.append(f"el10-fips-exercise: {cid} is neither safbox-fips-exercise-<n> nor safbox-fips-provider-<n>")
if not exercise:
    errors.append("el10-fips-exercise: no safbox-fips-exercise-<n> controls")
if [i.rsplit("-", 1)[1] for i in exercise] != [i.rsplit("-", 1)[1] for i in provider]:
    errors.append(f"el10-fips-exercise: every tool needs both controls (exercise {exercise}, provider {provider})")
for cid in exercise:
    if by_id[cid]["impact"] != 1.0:
        errors.append(f"el10-fips-exercise: {cid} has impact {by_id[cid]['impact']}; a tool's exercise is 1.0")
findings = []
for cid in provider:
    c = by_id[cid]
    if not is_low(c["impact"]):
        errors.append(f"el10-fips-exercise: {cid} has impact {c['impact']}; a provider control is low (0.1 to below 0.4)")
    issue = (c.get("tags") or {}).get("issue")
    if issue is not None:
        if not re.fullmatch(r"safbox-[a-z0-9]+(\.\d+)*", str(issue)):
            errors.append(f"el10-fips-exercise: {cid} tag issue {issue!r} is not a tracker id")
        findings.append(cid)
if not findings:
    errors.append("el10-fips-exercise: no known finding is tagged with an issue")
# Without FIPS enforcement the profile fails rather than skips: every control
# asserts it (directly or through the exercise helper), and the only skip is
# a tool left out of expected_tools.
src = "\n".join(p.read_text() for p in sorted((verify / "el10-fips-exercise/controls").glob("*.rb")))
for m in re.finditer(r"^control '([^']+)' do\n(.*?)^end$", src, re.S | re.M):
    cid, body = m.group(1), m.group(2)
    if "&fips_precondition)" not in body and "&exercise)" not in body:
        errors.append(f"el10-fips-exercise: {cid} does not assert FIPS enforcement")
    for cond in re.findall(r"only_if\([^)]*\)\s*(?:do|\{)\s*(.*?)\s*(?:end|\})\n", body, re.S):
        if not re.fullmatch(r"tool_expected\.call\('[a-z-]+'\)", cond):
            errors.append(f"el10-fips-exercise: {cid} skips on `{cond}`; only a tool left out of expected_tools skips")
expected["el10-fips-exercise"] = {
    "passed.critical": exercise,
    "passed.low": sorted(set(provider) - set(findings)),
    "failed.low": sorted(findings),
}

# The first-boot test: every control impact 1.0.
firstboot = loaded("el10-firstboot")
fb_ids = sorted(c["id"] for c in firstboot.get("controls") or [])
if not fb_ids:
    errors.append("el10-firstboot: no controls loaded")
for c in firstboot.get("controls") or []:
    if c["impact"] != 1.0:
        errors.append(f"el10-firstboot: {c['id']} has impact {c['impact']}; every first-boot control is 1.0")
expected["el10-firstboot"] = {"passed.critical": fb_ids}

# Thresholds hold exactly those lists, nothing may fail outside them, and
# no control errors. Every other severity may not fail at all.
CONTEXT = {"el10-fips-exercise": "fips-exercise", "el10-firstboot": "firstboot"}
for name, ctx in CONTEXT.items():
    m = meta(name)
    if m.get("supports") != [{"platform-family": "redhat", "release": "10.*"}]:
        errors.append(f"{name}: supports must be exactly redhat family release 10.* (is {m.get('supports')})")
    tpath, ipath = verify / f"thresholds/{ctx}.yml", verify / f"inputs/{ctx}.yml"
    if not tpath.exists() or not ipath.exists():
        errors.append(f"{name}: {tpath.relative_to(verify.parent)} and {ipath.relative_to(verify.parent)} must both exist")
        continue
    declared = {i["name"] for i in m.get("inputs") or []}
    for key in sorted(set(yaml.safe_load(ipath.read_text()) or {}) - declared):
        errors.append(f"{ipath.relative_to(verify.parent)}: {key} is not an input of {name}")
    t = yaml.safe_load(tpath.read_text()) or {}
    want = {"error": {"total": {"max": 0}}, "passed": {}, "failed": {}}
    for key, ids in expected[name].items():
        status, sev = key.split(".")
        want[status][sev] = {"controls": ids}
    for sev in ("critical", "high", "medium", "low"):
        want["failed"].setdefault(sev, {"max": 0})
    if t != want:
        errors.append(f"{tpath.relative_to(verify.parent)} must be exactly {json.dumps(want, sort_keys=True)} "
                      f"(is {json.dumps(t, sort_keys=True)})")

# Neither profile is part of the release gate.
wrapper = meta("inspec-safbox")
for d in wrapper.get("depends") or []:
    if d.get("name") in CONTEXT or str(d.get("path", "")).rstrip("/").split("/")[-1] in CONTEXT:
        errors.append(f"inspec-safbox: depends on {d}; the on-box exercise profiles run alone")

# The SAF CLI against a recorded FIPS exercise result.
def saf_passes(hdf, tfile, label):
    results = work / f"{label}.json"
    results.write_text(json.dumps(hdf))
    run = subprocess.run(["saf", "validate", "threshold", "-i", str(results), "-T", str(tfile)],
                         cwd=work, capture_output=True, text=True)
    return run.returncode == 0, (run.stdout + run.stderr).strip()

def force(hdf, cid, status):
    for p in hdf["profiles"]:
        for c in p.get("controls") or []:
            if c["id"] == cid:
                for r in c["results"]:
                    r["status"] = status
                    r.pop("message", None)
                    if status == "failed":
                        r["message"] = "fixture: forced failure"
    return hdf

fixture = fixtures / "fips-exercise.json"
tfile = verify / "thresholds/fips-exercise.yml"
if not errors and not fixture.exists():
    errors.append(f"no recorded result at {fixture.relative_to(root)}")
elif not errors:
    real = json.loads(fixture.read_text())
    ok, out = saf_passes(real, tfile, "real")
    if not ok:
        errors.append(f"fips-exercise: the recorded result does not meet the threshold:\n{out}")
    else:
        print("fips-exercise: recorded result meets verify/thresholds/fips-exercise.yml")
        exp = expected["el10-fips-exercise"]
        cases = {f"{exp['passed.critical'][0]} fails": (exp["passed.critical"][0], "failed"),
                 f"known finding {exp['failed.low'][0]} passes": (exp["failed.low"][0], "passed")}
        if exp["passed.low"]:
            cases[f"{exp['passed.low'][0]} fails as a new finding"] = (exp["passed.low"][0], "failed")
        for label, (cid, status) in cases.items():
            ok, out = saf_passes(force(copy.deepcopy(real), cid, status), tfile, label.replace(" ", "-"))
            if ok:
                errors.append(f"fips-exercise: the threshold still passes when {label}")
            elif "Failed to convert" in out or "Error:" not in out:
                errors.append(f"fips-exercise: the SAF CLI did not judge the results when {label}:\n{out}")
            else:
                print(f"fips-exercise: fails as it must when {label}")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print(f"PASS: el10-fips-exercise ({len(exercise)} tools, known findings {', '.join(findings)}) and "
      f"el10-firstboot ({len(fb_ids)} controls) load, check, and match their thresholds; neither is in the wrapper")
PY
