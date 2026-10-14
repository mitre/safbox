#!/usr/bin/env bash
# Deviation-set consistency (ADR-0001 §Decision: hardened with documented
# deviations; Phase 7). One list, ansible/roles/hardening/vars/deviations.yml,
# drives both sides: the hardening role switches each listed rule off through
# the Lockdown role's per-rule variable, and the STIG overlay
# (verify/safbox-rhel10-stig-overlay) marks each listed control Not
# Applicable with the same justification. This fails when:
#   - an entry is malformed: no SV and RHEL-10 ID, a reason code other than
#     usability, content-defect or deploy-time, no justification, or a
#     content-defect without its upstream issue link;
#   - the first usability entry is not the account lockout requirement;
#   - the overlay's Not Applicable overrides and the deviations differ, by
#     control or by justification text (compared ignoring line wrapping);
#   - a rule switched off because its Lockdown task failed to apply
#     (vars/not_applied.yml) carries a reason or justification, is also a
#     deviation, or is overridden in the overlay: those requirements stay
#     visible as failing findings;
#   - a known baseline defect (verify/safbox-rhel10-stig-overlay/
#     known-defects.yml) is malformed, is also a deviation, or is overridden
#     in the overlay: its result is locked as it is;
#   - baseline-titles.yml (scripts/baseline-titles.sh) is for another
#     baseline ref than the overlay pins, or lacks a STIG control the
#     thresholds lock;
#   - docs/deviations.md is not what scripts/deviations-doc.sh generates.
# Static; no target host or network is needed. The build runs it first, so a
# drifted pair fails the build before anything is provisioned.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v ansible-playbook >/dev/null || { echo "FAIL: ansible-playbook not installed" >&2; exit 1; }
read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"

"${PY[@]}" - "$ROOT" <<'PY'
import pathlib, re, sys, yaml
root = pathlib.Path(sys.argv[1])
role = root / "ansible/roles/hardening"
overlay_dir = root / "verify/safbox-rhel10-stig-overlay"
errors = []
REASONS = {"usability", "content-defect", "deploy-time"}
# The first usability entry (ADR-0001 §Decision: account lockout is the
# example of a requirement relaxed for the non-expert audience): the lock
# that only an administrator can release.
LOCKOUT = "SV-281197"

def load(path, key):
    if not path.exists():
        errors.append(f"{path.relative_to(root)} does not exist")
        return []
    data = yaml.safe_load(path.read_text()) or {}
    value = data.get(key)
    if not isinstance(value, list):
        errors.append(f"{path.relative_to(root)}: {key} must be a list")
        return []
    return value

def norm(text):
    return " ".join(str(text or "").split())

deviations = load(role / "vars/deviations.yml", "hardening_deviations")
not_applied = load(role / "vars/not_applied.yml", "hardening_not_applied")

dev_ids = []
for i, d in enumerate(deviations):
    where = f"deviations.yml entry {i + 1}"
    if not isinstance(d, dict):
        errors.append(f"{where}: not a mapping"); continue
    vid, sid = str(d.get("vuln_id", "")), str(d.get("stig_id", ""))
    where = f"deviations.yml {vid or where}"
    if not re.fullmatch(r"SV-\d+", vid):
        errors.append(f"{where}: vuln_id must be an SV-<n> ID")
    if not re.fullmatch(r"RHEL-10-\d{6}", sid):
        errors.append(f"{where}: stig_id must be a RHEL-10-<6 digits> ID (it names the Lockdown switch)")
    if not str(d.get("title", "")).strip():
        errors.append(f"{where}: no title")
    if d.get("reason") not in REASONS:
        errors.append(f"{where}: reason must be one of {sorted(REASONS)}")
    if not norm(d.get("justification")):
        errors.append(f"{where}: no justification")
    issue = str(d.get("issue") or "")
    if d.get("reason") == "content-defect" and not re.fullmatch(r"https://\S+/issues/\d+", issue):
        errors.append(f"{where}: a content-defect deviation needs its upstream issue link")
    if issue and d.get("reason") != "content-defect":
        errors.append(f"{where}: only a content-defect deviation carries an issue link")
    if vid in dev_ids:
        errors.append(f"{where}: listed twice")
    dev_ids.append(vid)
usability = [d.get("vuln_id") for d in deviations if isinstance(d, dict) and d.get("reason") == "usability"]
if not usability or usability[0] != LOCKOUT:
    errors.append(f"deviations.yml: the first usability entry must be the account lockout requirement ({LOCKOUT})")

na_ids = []
for i, n in enumerate(not_applied):
    if not isinstance(n, dict):
        errors.append(f"not_applied.yml entry {i + 1}: not a mapping"); continue
    vid, sid = str(n.get("vuln_id", "")), str(n.get("stig_id", ""))
    where = f"not_applied.yml {vid or i + 1}"
    if not re.fullmatch(r"SV-\d+", vid) or not re.fullmatch(r"RHEL-10-\d{6}", sid):
        errors.append(f"{where}: needs vuln_id (SV-<n>) and stig_id (RHEL-10-<6 digits>)")
    if not str(n.get("failure", "")).strip():
        errors.append(f"{where}: record the task failure seen")
    if not re.match(r"(passes|fails|skipped)\b", str(n.get("scan", "")).strip()):
        errors.append(f"{where}: record the control's scan result (passes, fails or skipped, and why)")
    for key in ("reason", "justification", "issue"):
        if key in n:
            errors.append(f"{where}: a rule not applied because its task failed is not a deviation; no {key}")
    if vid in dev_ids:
        errors.append(f"{where}: also a deviation")
    if vid in na_ids:
        errors.append(f"{where}: listed twice")
    na_ids.append(vid)

# Known upstream content defects that are not deviations: the control stays
# in force and its (wrong) result is locked as it is. Recorded so the guide
# explains them; each names the control and what is wrong, and the issue
# once one is filed.
known = load(overlay_dir / "known-defects.yml", "known_defects")
known_ids = []
for i, k in enumerate(known):
    if not isinstance(k, dict):
        errors.append(f"known-defects.yml entry {i + 1}: not a mapping"); continue
    vid = str(k.get("vuln_id", ""))
    where = f"known-defects.yml {vid or i + 1}"
    if not re.fullmatch(r"SV-\d+", vid):
        errors.append(f"{where}: vuln_id must be an SV-<n> ID")
    if not str(k.get("defect", "")).strip():
        errors.append(f"{where}: describe the defect")
    if k.get("issue") and not re.fullmatch(r"https://\S+/issues/\d+", str(k["issue"])):
        errors.append(f"{where}: issue must link an upstream issue")
    for key in ("reason", "justification"):
        if key in k:
            errors.append(f"{where}: a known defect is not a deviation; no {key}")
    if vid in dev_ids:
        errors.append(f"{where}: also a deviation (a content-defect deviation replaces the known-defect entry)")
    if vid in known_ids:
        errors.append(f"{where}: listed twice")
    known_ids.append(vid)

src = "\n".join(p.read_text() for p in sorted((overlay_dir / "controls").glob("*.rb")))
overrides = dict(re.findall(r"\n  control '([^']+)' do\n(.*?)\n  end\n", src, re.S))
just = {}
for cid, body in overrides.items():
    m = re.search(r"desc 'justification', <<~(\w+)\n(.*?)\n\s*\1\n", body, re.S)
    if re.search(r"^\s*impact 0\.0\s*$", body, re.M) and m:
        just[cid] = m.group(2)
by_id = {d["vuln_id"]: d for d in deviations if isinstance(d, dict) and "vuln_id" in d}
for cid in sorted(set(by_id) - set(just)):
    errors.append(f"{cid}: in deviations.yml but the overlay does not mark it Not Applicable")
for cid in sorted(set(just) - set(by_id)):
    errors.append(f"{cid}: Not Applicable in the overlay but not in deviations.yml")
for cid in sorted(set(just) & set(by_id)):
    if norm(just[cid]) != norm(by_id[cid].get("justification")):
        errors.append(f"{cid}: the overlay's justification differs from deviations.yml")
# A deviation that holds only until a site provides a setting (site_setting:
# <name>) is conditional on both sides with one name: the hardening role
# switches the rule off only while group_vars safbox_<name> is empty, and the
# overlay marks the control Not Applicable only while its input <name> is
# unset (its whole override guarded by unless input_object('<name>').has_value?;
# InSpec holds an empty input as having no value). The
# repository default leaves both empty, so the deviation applies.
group_vars = yaml.safe_load((root / "ansible/group_vars/all/main.yml").read_text()) or {}
overlay_meta = yaml.safe_load((overlay_dir / "inspec.yml").read_text()) or {}
overlay_inputs = {i.get("name"): i for i in overlay_meta.get("inputs") or []}
for d in deviations:
    if not isinstance(d, dict) or "site_setting" not in d:
        continue
    name, vid = str(d["site_setting"]), d.get("vuln_id")
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        errors.append(f"deviations.yml {vid}: site_setting must be a variable name")
        continue
    if group_vars.get(f"safbox_{name}", None) != "":
        errors.append(f"deviations.yml {vid}: group_vars must define safbox_{name} as an empty string by default")
    i = overlay_inputs.get(name)
    if not i or i.get("profile") or (i.get("value") or "") != "":
        errors.append(f"deviations.yml {vid}: the overlay must declare its own input {name}, empty by default")
    body = overrides.get(vid, "")
    if not re.match(rf"\s*unless input_object\('{name}'\)\.has_value\?\n", body) \
            or not re.search(r"\n    end\s*$", body):
        errors.append(f"{vid}: the overlay override must be wrapped in "
                      f"unless input_object('{name}').has_value? ... end")
for cid, body in sorted(overrides.items()):
    if "input_object(" in body and not (cid in by_id and "site_setting" in by_id[cid]):
        errors.append(f"{cid}: a conditional override needs a site_setting in deviations.yml")

# The baseline's control titles, used by the guide's list of remaining
# failures, come from a generated file (scripts/baseline-titles.sh) so this
# check needs no network. It must be for the overlay's pinned ref and name
# every STIG control the thresholds lock.
titles_path = overlay_dir / "baseline-titles.yml"
if not titles_path.exists():
    errors.append(f"{titles_path.relative_to(root)} does not exist; run scripts/baseline-titles.sh")
else:
    titles = yaml.safe_load(titles_path.read_text()) or {}
    pinned = next((d.get("ref") for d in overlay_meta.get("depends") or []
                   if d.get("name") == "redhat-enterprise-linux-10-stig-baseline"), None)
    if titles.get("baseline_ref") != pinned:
        errors.append(f"baseline-titles.yml: generated for {titles.get('baseline_ref')}, but the overlay pins "
                      f"{pinned}; run scripts/baseline-titles.sh")
    named = set((titles.get("controls") or {}))
    for ctx in ("build", "release"):
        t = yaml.safe_load((root / f"verify/thresholds/{ctx}.yml").read_text()) or {}
        for status in ("passed", "failed"):
            for sev in ("high", "medium", "low"):
                for cid in ((t.get(status) or {}).get(sev) or {}).get("controls") or []:
                    # Only STIG IDs: documented infrastructure findings
                    # (safbox-*) may sit in failed.low beside them.
                    if cid.startswith("SV-") and cid not in named:
                        errors.append(f"baseline-titles.yml: no title for {cid} ({ctx} {status}.{sev})")

for cid in sorted(set(overrides) & set(na_ids)):
    errors.append(f"{cid}: not applied because its task failed; it must not be overridden in the overlay")
for cid in sorted(set(overrides) & set(known_ids)):
    errors.append(f"{cid}: a known defect, not a deviation; it must not be overridden in the overlay")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print(f"PASS: {len(by_id)} deviation(s) match the overlay's Not Applicable overrides; "
      f"{len(na_ids)} rule(s) not applied (task failed) stay out of the overlay")
PY

# The deviations guide is generated; regenerate into scratch and compare.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/scripts/deviations-doc.sh" "$work/deviations.md" >/dev/null
if ! diff -u "$ROOT/docs/deviations.md" "$work/deviations.md" >&2; then
  echo "FAIL: docs/deviations.md is stale; run scripts/deviations-doc.sh" >&2
  exit 1
fi
echo "PASS: docs/deviations.md matches deviations.yml"
