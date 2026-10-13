#!/usr/bin/env bash
# Task-group structure (ADR-0001 "Role layout and task groups"): in the
# switchable roles every top-level task is either the OS variable load
# (tagged always) or a block tagged safbox-<role>-<n> and gated by
# safbox_<role>_<n>, and group_vars lists every switch. The seal's top-level
# tasks are tagged safbox-seal-<n> and are deliberately not switchable.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$ROOT" <<'PY'
import re, sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
gv = yaml.safe_load((root / "ansible/group_vars/all/main.yml").read_text())
errors = []
def check_load(role, t):
    if "always" not in (t.get("tags") or []):
        errors.append(f"{role}: '{t['name']}' must be tagged always")
for role in ["platform", "base", "tools"]:
    tasks = yaml.safe_load((root / f"ansible/roles/{role}/tasks/main.yml").read_text())
    seen = []
    for t in tasks:
        if t.get("name") == "Load OS family variables":
            check_load(role, t); continue
        tags = t.get("tags") or []
        tag = next((x for x in tags if re.fullmatch(rf"safbox-{role}-\d+", x)), None)
        if "block" not in t or not tag:
            errors.append(f"{role}: top-level task '{t.get('name')}' is not a tagged safbox-{role}-<n> block"); continue
        n = tag.rsplit("-", 1)[1]
        switch = f"safbox_{role}_{n}"
        when = t.get("when"); when = when if isinstance(when, list) else [when]
        if not any(isinstance(w, str) and w.startswith(f"{switch} | default(true) | bool") for w in when):
            errors.append(f"{role}: block {tag} is not gated by '{switch} | default(true) | bool'")
        if switch not in gv:
            errors.append(f"group_vars: switch {switch} for {tag} is missing")
        if tag in seen: errors.append(f"{role}: tag {tag} used twice")
        seen.append(tag)
# Every OS-family name a role defines for the RHEL family is defined for the
# Debian family too (ADR-0001: Debian untested but present), so a Debian run
# fails on a wrong value rather than an undefined variable.
for vars_rh in sorted((root / "ansible/roles").glob("*/vars/RedHat.yml")):
    vars_deb = vars_rh.with_name("Debian.yml")
    rh_names = set(yaml.safe_load(vars_rh.read_text()) or {})
    deb_names = set(yaml.safe_load(vars_deb.read_text()) or {}) if vars_deb.exists() else set()
    for name in sorted(rh_names - deb_names):
        errors.append(f"{vars_rh.parts[-3]}: {name} is in vars/RedHat.yml but not vars/Debian.yml")
# Every tools group installs a tool the validation profile checks at its
# pinned version (ADR-0001 Phase 3 verification), in a control named after
# the group so a switched-off group maps to the control that skips.
tools_controls = (root / "verify/inspec-safbox/controls/tools.rb")
tools_controls = tools_controls.read_text() if tools_controls.exists() else ""
for switch in sorted(k for k in gv if re.fullmatch(r"safbox_tools_\d+", k)):
    n = switch.rsplit("_", 1)[1]
    if f"control 'safbox-tools-{n}'" not in tools_controls:
        errors.append(f"verify: no control safbox-tools-{n} checks the tool group {switch} installs")
seal = yaml.safe_load((root / "ansible/roles/seal/tasks/main.yml").read_text())
for t in seal:
    if t.get("name") == "Load OS family variables":
        check_load("seal", t); continue
    if "ansible.builtin.assert" in t:
        continue  # the seal-mode check, verified below
    if not any(re.fullmatch(r"safbox-seal-\d+", x) for x in (t.get("tags") or [])):
        errors.append(f"seal: top-level task '{t.get('name')}' has no safbox-seal-<n> tag")
# Seal modes (ADR-0001 "Validation stages"): full seals a release template;
# development scrubs identity but keeps the build user for inspection. The
# mode is validated before anything runs, and the destructive final group
# (build user, host keys, logs, post-conditions) runs only in full mode.
seal_defaults = yaml.safe_load((root / "ansible/roles/seal/defaults/main.yml").read_text())
if seal_defaults.get("seal_mode") != "full":
    errors.append("seal: defaults must set seal_mode: full")
mode_check = [t for t in seal if "ansible.builtin.assert" in t]
if not mode_check or "always" not in (mode_check[0].get("tags") or []) \
        or "seal_mode in ['full', 'development']" not in str(mode_check[0]["ansible.builtin.assert"]):
    errors.append("seal: an assert tagged always must reject a seal_mode other than full or development")
final = [t for t in seal if "safbox-seal-3" in (t.get("tags") or [])]
if not final or final[0].get("when") != "seal_mode == 'full'":
    errors.append("seal: group safbox-seal-3 must run only when seal_mode == 'full'")
for t in seal:
    if "safbox-seal-3" not in (t.get("tags") or []) and "full" in str(t.get("when", "")):
        errors.append(f"seal: '{t.get('name')}' is gated on full mode but is not group 3")
if "SAFBOX_SEAL_MODE={{ seal_mode }}" not in (root / "ansible/roles/seal/templates/build-info.j2").read_text():
    errors.append("seal: the build record must carry SAFBOX_SEAL_MODE")
hcl = (root / "packer/build.pkr.hcl").read_text()
if "--list-tasks" in hcl or 'provisioner "shell" {' in hcl.split('playbooks/safbox.yml')[1]:
    errors.append("packer: the seal must be one ansible run in every mode; no shell clean-up or --list-tasks after the playbook")
if 'seal_mode=${var.seal ? "full" : "development"}' not in hcl:
    errors.append("packer: the seal provisioner must pass seal_mode from var.seal")
if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print("PASS: task groups are tagged and switched; variable loads are tagged always; Debian vars cover RedHat; tools groups have controls; seal modes gated")
PY
