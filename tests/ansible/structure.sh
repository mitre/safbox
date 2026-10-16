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
import re, subprocess, sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
gv = yaml.safe_load((root / "ansible/group_vars/all/main.yml").read_text())
errors = []
def check_load(role, t):
    if "always" not in (t.get("tags") or []):
        errors.append(f"{role}: '{t['name']}' must be tagged always")
# The switchable roles, in playbook order. site_config (the site's trusted
# CA bundles) follows the OS contract and precedes every role that fetches
# over TLS. The services role holds every long-running service, one task
# group per service so a site can switch one off; hardening is last.
SWITCHABLE = ["platform", "site_config", "base", "tools", "services", "hardening"]
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
# The services role: every long-running service in one role, one task file
# per service, each its own task group in this order. A group's block
# imports its task file statically (import_tasks), so the group's tag and
# switch reach every task in it; include_tasks would pass neither to the
# included tasks, and --tags safbox-services-<n> would then run nothing.
SERVICES = ["heimdall", "vulcan", "proxy"]
services_dir = root / "ansible/roles/services"
if (services_dir / "tasks/main.yml").exists():
    groups = [t for t in yaml.safe_load((services_dir / "tasks/main.yml").read_text())
              if t.get("name") != "Load OS family variables"]
    for i, service in enumerate(SERVICES, 1):
        t = groups[i - 1] if len(groups) >= i else {}
        body = t.get("block") or []
        if f"safbox-services-{i}" not in (t.get("tags") or []) or len(body) != 1 \
                or body[0].get("ansible.builtin.import_tasks") != f"{service}.yml":
            errors.append(f"services: group safbox-services-{i} must be one block importing {service}.yml "
                          "(ansible.builtin.import_tasks)")
        if not (services_dir / f"tasks/{service}.yml").exists():
            errors.append(f"services: tasks/{service}.yml missing")
    if len(groups) != len(SERVICES):
        errors.append(f"services: expected {len(SERVICES)} task groups, found {len(groups)}")
    # One handler per name in the role: a single systemd reload, and each
    # service's restart under its own name.
    handlers = [h.get("name") for h in yaml.safe_load((services_dir / "handlers/main.yml").read_text()) or []]
    for name in sorted({h for h in handlers if handlers.count(h) > 1}):
        errors.append(f"services: handler '{name}' is defined more than once")
    if "Reload systemd units" not in handlers:
        errors.append("services: no 'Reload systemd units' handler")
    # The proxy fronts exactly the applications whose groups are on.
    services_proxy_apps = {a["name"]: a for a in yaml.safe_load((services_dir / "defaults/main.yml").read_text())["services_proxy_apps"]}
    for i, app in ((1, "heimdall"), (2, "vulcan")):
        want = f"{{{{ safbox_services_{i} | default(true) | bool }}}}"
        if (services_proxy_apps.get(app) or {}).get("enabled") != want:
            errors.append(f"services: services_proxy_apps {app} must be enabled by \"{want}\"")
# Validation controls renamed because their old IDs were task tags of an
# unrelated group (checked below); the migration note in docs/rebuild.md
# lists each pair for sites with their own thresholds.
RENAMED_CONTROLS = {
    "safbox-services-1": "safbox-system-1",  # guest agent, cloud-init, sshd
    "safbox-services-2": "safbox-system-2",  # chrony, firewalld, SSH allowed
    "safbox-services-3": "safbox-system-3",  # persistent journal
    "safbox-platform-1": "safbox-os-1",      # a supported operating system
    "safbox-platform-2": "safbox-os-2",      # distribution and microarchitecture recorded
    "safbox-seal-1": "safbox-sealed-1",      # build user, key and sudo rule gone
    "safbox-seal-2": "safbox-sealed-2",      # no installer residue
}
# The per-service roles are gone (folded into services): no role directory,
# and no file names their roles, switches or tags, except the ADRs (decision
# records, kept as written), the recorded scans (tests/verify/fixtures,
# regenerated only from real scans), this test, and the migration note in
# docs/rebuild.md that tells sites what to rename in ansible/local.yml.
# Validation control names (safbox-heimdall-1 and so on) are unchanged and
# allowed.
OLD = r"heimdall|vulcan|proxy"
PROSE = [rf"\b({OLD})`?\s+roles?\b", rf"\broles?\s+`?({OLD})\b"]
OLD_NAMES = re.compile("|".join([
    rf"safbox_({OLD})_\d+",                          # switches
    rf"(group|tags?)\W+safbox-({OLD})-\d",           # tags and task groups
    rf"roles/({OLD})\b", rf"role:\s*({OLD})\b",      # role paths and play entries
] + PROSE), re.IGNORECASE)
OLD_PROSE = re.compile("|".join(PROSE), re.IGNORECASE)
MIGRATION = "Migrating from the per-service roles"
for old in SERVICES:
    if (root / f"ansible/roles/{old}").exists():
        errors.append(f"roles: ansible/roles/{old} still exists (folded into services)")
tracked = subprocess.run(["git", "-C", str(root), "ls-files", "-co", "--exclude-standard"],
                         check=True, capture_output=True, text=True).stdout.splitlines()
for rel in tracked:
    if rel.startswith(("docs/adrs/", "tests/verify/fixtures/")) or rel == "tests/ansible/structure.sh":
        continue
    path = root / rel
    try:
        text = path.read_text()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue
    if rel == "docs/rebuild.md":
        note = re.search(rf"^(#+) {MIGRATION}\n.*?(?=^#|\Z)", text, re.MULTILINE | re.DOTALL)
        if not note:
            errors.append(f"docs/rebuild.md: no '{MIGRATION}' section")
        else:
            for old, i in (("heimdall", 1), ("vulcan", 2), ("proxy", 3)):
                if f"safbox_{old}_1" not in note.group(0) or f"safbox_services_{i}" not in note.group(0):
                    errors.append(f"docs/rebuild.md: the migration note must rename safbox_{old}_1 to safbox_services_{i}")
            for old_id, new_id in RENAMED_CONTROLS.items():
                if not re.search(rf"`{old_id}`.*`{new_id}`", note.group(0)):
                    errors.append(f"docs/rebuild.md: the migration note must rename control {old_id} to {new_id}")
            text = text.replace(note.group(0), "")
    for n, line in enumerate(text.splitlines(), 1):
        if OLD_NAMES.search(line):
            errors.append(f"{rel}:{n}: names a per-service role, switch or tag: {line.strip()}")
    # Prose wrapped across comment lines ("the heimdall\n# role").
    joined = re.sub(r"[ \t]*\n[ \t]*(#+|//)?[ \t]*", " ", text)
    for m in OLD_PROSE.finditer(joined):
        if m.group(0) not in text:  # one-line matches are reported above
            errors.append(f"{rel}: names a per-service role across lines: {m.group(0)!r}")
# Every tag on a task of the project's roles is safbox-<role>-<n>, the role
# being the one the task lives in (its directory name, _ as -), or always
# (the OS variable loads). Nested blocks and imported task files included.
def tagged(tasks):
    for t in tasks or []:
        if not isinstance(t, dict):
            continue
        yield t
        for key in ("block", "rescue", "always"):
            yield from tagged(t.get(key))
for role_dir in sorted(p for p in (root / "ansible/roles").iterdir() if p.is_dir()):
    want = re.compile(rf"safbox-{role_dir.name.replace('_', '-')}-\d+")
    for f in sorted(role_dir.glob("tasks/*.yml")) + sorted(role_dir.glob("handlers/*.yml")):
        for t in tagged(yaml.safe_load(f.read_text())):
            tags = t.get("tags") or []
            for tag in [tags] if isinstance(tags, str) else tags:
                if tag != "always" and not want.fullmatch(str(tag)):
                    errors.append(f"{f.relative_to(root)}: task '{t.get('name')}' has tag '{tag}'; "
                                  f"tags in this role are {want.pattern} (or always)")
all_tags = {str(tag)
            for f in (root / "ansible/roles").glob("*/tasks/*.yml")
            for t in tagged(yaml.safe_load(f.read_text()))
            for tag in ([t["tags"]] if isinstance(t.get("tags"), str) else t.get("tags") or [])}
# A validation control ID is never a task tag of an unrelated group: a site
# that switches group safbox-<role>-<n> off drops the control of that name,
# so the two names must mean the same thing. Only these share a name, by
# design: each control checks exactly what its task group does.
SHARED_WITH_TAG = {
    "safbox-hardening-1",  # hardening group 1 applies the STIG; the control checks its record
    "safbox-tools-1", "safbox-tools-2", "safbox-tools-3", "safbox-tools-4",  # each checks its group's tool
}
control_ids = {m.group(1) for p in (root / "verify").glob("*/controls/*.rb")
               for m in re.finditer(r"^\s*control\s+'([^']+)'", p.read_text(), re.MULTILINE)}
for cid in sorted(control_ids & all_tags - SHARED_WITH_TAG):
    errors.append(f"verify: control {cid} has the name of a task tag of an unrelated group; rename it")
for cid in sorted(SHARED_WITH_TAG - (control_ids & all_tags)):
    errors.append(f"structure.sh: {cid} is allowed to share a tag's name but is no longer both a control and a tag")
for old_id, new_id in RENAMED_CONTROLS.items():
    if new_id not in control_ids:
        errors.append(f"verify: no control {new_id} (formerly {old_id})")
    if new_id in all_tags:
        errors.append(f"verify: control {new_id} is now a task tag too")
# No threshold or inputs file names a control by a task tag's name either.
for p in sorted((root / "verify").rglob("*.yml")):
    for n, line in enumerate(p.read_text().splitlines(), 1):
        m = re.match(r"\s*-\s*(safbox-[a-z-]+-\d+)\s*$", line)
        if m and m.group(1) in all_tags - SHARED_WITH_TAG:
            errors.append(f"{p.relative_to(root)}:{n}: {m.group(1)} is a task tag, not a control name")
for f in sorted((root / "ansible/playbooks").glob("*.yml")):
    for play in yaml.safe_load(f.read_text()) or []:
        for item in [play] + list(tagged(play.get("tasks"))) + [r for r in play.get("roles") or [] if isinstance(r, dict)]:
            if item.get("tags"):
                errors.append(f"{f.relative_to(root)}: tags belong on the roles' task groups, not the playbook ({item.get('tags')})")
# The services role's variables carry its name (ansible-lint
# var-naming[no-role-prefix]): services_heimdall_*, services_vulcan_*,
# services_proxy_*. No file of the appliance layer uses one of the old
# unprefixed names (the defaults and registered results of the former
# heimdall, vulcan and proxy roles), which would now be undefined, or a
# site override that no longer applies. Names, not a pattern: nginx's own
# proxy_* directives and Vulcan's upstream names (vulcan_production) stay.
OLD_VARS = {
    "heimdall": ["image", "db_image", "loopback_port", "env_file", "db_env_file", "firstboot_hook",
                 "jwt_expire_time", "memory", "db_memory", "secrets"],
    "vulcan": ["image", "db_image", "loopback_port", "env_file", "db_env_file", "firstboot_hook",
               "settings", "memory", "db_memory", "secrets"],
    "proxy": ["image", "apps", "conf_dir", "tls_dir", "cert", "key", "firstboot_hook", "memory", "tls"],
}
UNPREFIXED = re.compile(r"(?<![\w.-])(" + "|".join(
    f"{svc}_{name}" for svc, names in OLD_VARS.items() for name in names) + r")\b")
for f in sorted((root / "ansible").rglob("*")):
    rel = f.relative_to(root)
    if not f.is_file() or rel.parts[1] in ("galaxy_roles", "collections") or f.suffix not in (".yml", ".j2", ".cfg", ".ini"):
        continue
    for n, line in enumerate(f.read_text().splitlines(), 1):
        for m in UNPREFIXED.finditer(line):
            errors.append(f"{rel}:{n}: unprefixed role variable {m.group(0)} (now services_{m.group(0)})")
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
for role in ("platform", "services"):
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
print("PASS: task groups are tagged and switched; variable loads are tagged always; OS vars cover both families without duplicates; tools groups have controls; seal modes gated; every task tag is safbox-<role>-<n>; services role folded with no old names left")
PY
