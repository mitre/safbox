#!/usr/bin/env bash
# Task-group structure (ADR-0001 "Role layout and task groups"): in the
# switchable roles every top-level task is either the OS variable load
# (tagged always) or a block tagged safbox-<role>-<n> and gated by
# safbox_<role>_<n>, and group_vars lists every switch. A role name with an
# underscore (site_config) keeps it in the switch and uses a hyphen in the
# tag (safbox_site_config_1, safbox-site-config-1). The seal's top-level
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
# The switchable roles, in playbook order. site_config (the site's trusted
# CA bundles) follows the OS contract and precedes every role that fetches
# over TLS. Each service (Heimdall, Vulcan, the TLS proxy) is its own role
# so a site can switch one off; hardening is last.
SWITCHABLE = ["platform", "site_config", "base", "tools", "heimdall", "vulcan", "proxy", "hardening"]
playbook = yaml.safe_load((root / "ansible/playbooks/safbox.yml").read_text())
in_play = [r["role"] if isinstance(r, dict) else r for r in playbook[0].get("roles") or []]
if [r for r in in_play if r in SWITCHABLE] != SWITCHABLE:
    errors.append(f"playbook: safbox.yml must apply {SWITCHABLE} in that order (has {in_play})")
for role in SWITCHABLE:
    tasks_file = root / f"ansible/roles/{role}/tasks/main.yml"
    if not tasks_file.exists():
        errors.append(f"{role}: role missing ({tasks_file.relative_to(root)})"); continue
    tasks = yaml.safe_load(tasks_file.read_text())
    seen = []
    for t in tasks:
        if t.get("name") == "Load OS family variables":
            check_load(role, t); continue
        tags = t.get("tags") or []
        tag_role = role.replace("_", "-")
        tag = next((x for x in tags if re.fullmatch(rf"safbox-{tag_role}-\d+", x)), None)
        if "block" not in t or not tag:
            errors.append(f"{role}: top-level task '{t.get('name')}' is not a tagged safbox-{tag_role}-<n> block"); continue
        n = tag.rsplit("-", 1)[1]
        switch = f"safbox_{role}_{n}"
        when = t.get("when"); when = when if isinstance(when, list) else [when]
        if not any(isinstance(w, str) and w.startswith(f"{switch} | default(true) | bool") for w in when):
            errors.append(f"{role}: block {tag} is not gated by '{switch} | default(true) | bool'")
        if switch not in gv:
            errors.append(f"group_vars: switch {switch} for {tag} is missing")
        if tag in seen: errors.append(f"{role}: tag {tag} used twice")
        seen.append(tag)
# OS-family variables (ADR-0001 "Role layout and task groups"): a name
# common to every family lives once in vars/main.yml, and vars/<family>.yml
# holds only what that family changes (the role's include_vars outranks
# vars/main.yml). Every name the RHEL family defines is defined for the
# Debian family too, in its own file or in vars/main.yml (Debian untested
# but present), so a Debian run fails on a wrong value rather than an
# undefined variable. A name with the same value in every family file, or
# repeating vars/main.yml's value, belongs in vars/main.yml alone.
OS_FAMILIES = {"RedHat", "Debian"}
for role_dir in sorted(p for p in (root / "ansible/roles").iterdir() if (p / "vars").is_dir()):
    role = role_dir.name
    main = role_dir / "vars/main.yml"
    common = (yaml.safe_load(main.read_text()) or {}) if main.exists() else {}
    # Only files named after an OS family are family files; any other file
    # in vars/ is data the role loads by name (the hardening role's
    # deviations.yml and not_applied.yml).
    families = {f.stem: yaml.safe_load(f.read_text()) or {}
                for f in sorted((role_dir / "vars").glob("*.yml")) if f.stem in OS_FAMILIES}
    tasks = yaml.safe_load((role_dir / "tasks/main.yml").read_text()) or []
    loads = any(t.get("name") == "Load OS family variables" for t in tasks)
    if loads != bool(families):
        errors.append(f"{role}: a 'Load OS family variables' task and vars/<family>.yml files must exist together")
    if not families:
        continue
    if set(families) != {"RedHat", "Debian"}:
        errors.append(f"{role}: vars/ must hold RedHat.yml and Debian.yml (found {sorted(families)})")
        continue
    for name in sorted(set(families["RedHat"]) - set(families["Debian"]) - set(common)):
        errors.append(f"{role}: {name} is in vars/RedHat.yml but not vars/Debian.yml or vars/main.yml")
    for name in sorted(set(families["RedHat"]) & set(families["Debian"])):
        if families["RedHat"][name] == families["Debian"][name]:
            errors.append(f"{role}: {name} is the same in every family file; move it to vars/main.yml")
    for fam, values in families.items():
        for name in sorted(set(values) & set(common)):
            if values[name] == common[name]:
                errors.append(f"{role}: vars/{fam}.yml repeats vars/main.yml's value for {name}")
# Every tools group installs a tool the validation profile checks at its
# pinned version (ADR-0001 Phase 3 verification), in a control named after
# the group so a switched-off group maps to the control that skips.
tools_controls = (root / "verify/el10-infrastructure/controls/tools.rb")
tools_controls = tools_controls.read_text() if tools_controls.exists() else ""
for switch in sorted(k for k in gv if re.fullmatch(r"safbox_tools_\d+", k)):
    n = switch.rsplit("_", 1)[1]
    if f"control 'safbox-tools-{n}'" not in tools_controls:
        errors.append(f"verify: no control safbox-tools-{n} checks the tool group {switch} installs")
# One firewalld zone (safbox_firewall_zone): hardening moves the interface
# into Lockdown's zone and makes it the default, so Lockdown's zone variable
# and every firewalld task of the project's roles (platform group 3, the
# proxy ports) must name that same zone, or ports open in a zone the
# interface is no longer in.
ZONE = "{{ safbox_firewall_zone }}"
if "safbox_firewall_zone" not in gv:
    errors.append("group_vars: safbox_firewall_zone is not defined")
if gv.get("rhel10stig_custom_firewall_zone") != ZONE:
    errors.append(f"group_vars: rhel10stig_custom_firewall_zone must be \"{ZONE}\"")
def firewalld_tasks(tasks):
    for t in tasks or []:
        if not isinstance(t, dict):
            continue
        if "ansible.posix.firewalld" in t:
            yield t
        for key in ("block", "rescue", "always"):
            yield from firewalld_tasks(t.get(key))
seen_firewalld = set()
for tasks_file in sorted((root / "ansible/roles").glob("*/tasks/*.yml")):
    role = tasks_file.parts[-3]
    for t in firewalld_tasks(yaml.safe_load(tasks_file.read_text())):
        seen_firewalld.add(role)
        if (t["ansible.posix.firewalld"] or {}).get("zone") != ZONE:
            errors.append(f"{role}: firewalld task '{t.get('name')}' must set zone: \"{ZONE}\"")
for role in ("platform", "proxy"):
    if role not in seen_firewalld:
        errors.append(f"{role}: no ansible.posix.firewalld task found to check")
# Hardening is the last role of the appliance play, after every role that
# installs or configures something and before validation and the seal
# (ADR-0001 §Decision: hardened with documented deviations).
play = yaml.safe_load((root / "ansible/playbooks/safbox.yml").read_text())
play_roles = [r["role"] if isinstance(r, dict) else r for r in play[0].get("roles") or []]
if not play_roles or play_roles[-1] != "hardening":
    errors.append(f"playbook: hardening must be the last role of the appliance play (roles: {play_roles})")
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
print("PASS: task groups are tagged and switched; variable loads are tagged always; OS vars cover both families without duplicates; tools groups have controls; seal modes gated")
PY
