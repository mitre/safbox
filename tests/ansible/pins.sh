#!/usr/bin/env bash
# Pinned inputs (ADR-0001 Quality Standards): every tool the appliance layer
# downloads is pinned in ansible/group_vars/all/main.yml by version AND the
# sha256 of the artifact, over HTTPS, and nothing is "latest". A package
# installed from a registry (the SAF CLI from npm) is pinned at its root
# version; the package manager resolves its dependencies. The validation
# profile's expected-version
# inputs must default to the same pins, and every tools group switch must
# have its tool in the expected_tools input default. Container images are
# pinned by digest, and the profile's service_images, proxy_ports and
# loopback_ports inputs default to the group_vars values. Static; no target
# host is needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
"${PY[@]}" - "$ROOT" <<'PY'
import re, sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
gv = yaml.safe_load((root / "ansible/group_vars/all/main.yml").read_text())
errors = []

def walk(value, path):
    if isinstance(value, dict):
        for k, v in value.items():
            yield from walk(v, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from walk(v, f"{path}[{i}]")
    else:
        yield path, value

for path, value in walk(gv, "group_vars"):
    if isinstance(value, str) and re.search(r"(^|[^a-z])latest([^a-z]|$)", value, re.I):
        errors.append(f"{path}: 'latest' is not a pin")

tools = {k: v for k, v in gv.items() if k.startswith("safbox_tool_")}
if not tools:
    errors.append("group_vars: no safbox_tool_* pins found")
for name, pin in tools.items():
    entries = pin if isinstance(pin, list) else [pin]
    for i, entry in enumerate(entries):
        where = name if not isinstance(pin, list) else f"{name}[{i}]"
        if not isinstance(entry, dict) or not str(entry.get("version", "")).strip():
            errors.append(f"{where}: no version")
            continue
        # An exact release, never a range: a registry package pinned at its
        # root (the SAF CLI) is only reproducible at that root if the root is
        # exact.
        if not re.fullmatch(r"\d+(\.\d+)+(-[0-9A-Za-z.]+)?", str(entry["version"])):
            errors.append(f"{where}: version {entry['version']!r} is not an exact release")
        if "url" not in entry:
            continue
        # A url may start from another group_vars value: "{{ name }}/file".
        url = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: str(gv.get(m.group(1), m.group(0))), str(entry["url"]))
        version = str(entry["version"])
        if not url.startswith("https://"):
            errors.append(f"{where}: url is not HTTPS")
        if version not in url:
            errors.append(f"{where}: url does not name version {version}")
        if not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", ""))):
            errors.append(f"{where}: downloaded artifact has no sha256")

# The validation profile's expected versions are inputs whose defaults must
# equal the pins: safbox_tool_<name> -> input <name>_version, and a list pin
# (the collections) -> input <name> as a map of name to version.
profile = yaml.safe_load((root / "verify/el10-infrastructure/inspec.yml").read_text())
inputs = {i["name"]: i.get("value") for i in profile.get("inputs") or []}
for name, pin in tools.items():
    short = name[len("safbox_tool_"):]
    if isinstance(pin, list):
        input_name = short
        want = {str(e.get("name")): str(e.get("version")) for e in pin if isinstance(e, dict)}
        got = {str(k): str(v) for k, v in (inputs.get(input_name) or {}).items()} \
            if isinstance(inputs.get(input_name), dict) else inputs.get(input_name)
    else:
        input_name = f"{short}_version"
        want = str(pin.get("version")) if isinstance(pin, dict) else None
        got = None if inputs.get(input_name) is None else str(inputs.get(input_name))
    if input_name not in inputs:
        errors.append(f"verify: inspec.yml has no input {input_name} for the pin {name}")
    elif got != want:
        errors.append(f"verify: input {input_name} defaults to {got!r} but group_vars pins {name} at {want!r}")

# Every tools group switch has a control naming the tool it checks, and that
# tool is in the expected_tools default, so a default build checks them all.
tools_rb = root / "verify/el10-infrastructure/controls/tools.rb"
tools_rb = tools_rb.read_text() if tools_rb.exists() else ""
control_tool = {}
for n, body in re.findall(r"^control 'safbox-tools-(\d+)'(.*?)(?=^control |\Z)", tools_rb, re.S | re.M):
    found = re.search(r"tool_expected\.call\('([a-z-]+)'\)", body)
    if found:
        control_tool[n] = found.group(1)
expected_default = inputs.get("expected_tools")
if not isinstance(expected_default, list):
    errors.append("verify: inspec.yml has no expected_tools input listing the tools a default build ships")
    expected_default = []
for switch in sorted(k for k in gv if re.fullmatch(r"safbox_tools_\d+", k)):
    n = switch.rsplit("_", 1)[1]
    tool = control_tool.get(n)
    if not tool:
        errors.append(f"verify: control safbox-tools-{n} does not name its tool with tool_expected.call('<tool>')")
    elif tool not in expected_default:
        errors.append(f"verify: {switch} exists but its tool {tool!r} is not in the expected_tools default")

# Container images (ADR-0001 Pinned inputs): every safbox_image_<key> pin
# names a fully qualified image, an exact tag recorded for review, and the
# sha256 digest roles must use. The service images (every pin but the
# platform smoke test's) are a profile input, service_images, keyed the same
# way, whose defaults carry the same name and digest.
SMOKE_TEST_IMAGES = {"safbox_image_pause"}
images = {k: v for k, v in gv.items() if k.startswith("safbox_image_")}
for name, pin in images.items():
    if not isinstance(pin, dict):
        errors.append(f"{name}: must be a mapping of name, tag and digest"); continue
    if not re.fullmatch(r"[a-z0-9.-]+\.[a-z]+(:\d+)?/[a-z0-9._/-]+", str(pin.get("name", ""))):
        errors.append(f"{name}: name {pin.get('name')!r} is not a fully qualified image name")
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]*", str(pin.get("tag", ""))):
        errors.append(f"{name}: no tag recorded")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(pin.get("digest", ""))):
        errors.append(f"{name}: digest {pin.get('digest')!r} is not sha256:<64 hex>")
service_images = inputs.get("service_images")
if not isinstance(service_images, dict):
    errors.append("verify: inspec.yml has no service_images input (image key to name and digest)")
    service_images = {}
want_keys = {k[len("safbox_image_"):] for k in images if k not in SMOKE_TEST_IMAGES}
if set(service_images) != want_keys:
    errors.append(f"verify: service_images keys {sorted(service_images)} differ from the service image pins {sorted(want_keys)}")
for key in sorted(want_keys & set(service_images)):
    pin = images[f"safbox_image_{key}"]
    want = {"name": pin.get("name"), "digest": pin.get("digest")}
    if service_images[key] != want:
        errors.append(f"verify: input service_images.{key} is {service_images[key]!r} but group_vars pins {want!r}")

# Service ports: the proxy's HTTPS port and the application's loopback port
# per service are group_vars settings the profile checks through inputs of
# the same shape (proxy_ports, loopback_ports: service name to port).
for input_name, suffix in (("proxy_ports", "https_port"), ("loopback_ports", "loopback_port")):
    want = {k[len("safbox_"):-len(suffix) - 1]: v for k, v in gv.items()
            if k.startswith("safbox_") and k.endswith(f"_{suffix}")}
    got = inputs.get(input_name)
    if not want:
        errors.append(f"group_vars: no safbox_<service>_{suffix} settings")
    if got != want:
        errors.append(f"verify: input {input_name} defaults to {got!r} but group_vars sets {want!r}")

# The Ansible Lockdown STIG role the hardening role applies (ADR-0001
# §Decision: base release and benchmark) is pinned in group_vars at an
# exact release, the commit that release tag names, and the STIG release
# the role targets. The build runner installs it from ansible/requirements.yml
# by that commit, which a moved tag cannot change; the two must agree. The
# validation profile's lockdown_version input defaults to the same release.
lockdown = gv.get("safbox_hardening_lockdown")
requirements = yaml.safe_load((root / "ansible/requirements.yml").read_text()) or {}
if not isinstance(lockdown, dict):
    errors.append("group_vars: no safbox_hardening_lockdown pin")
else:
    if not re.fullmatch(r"\d+(\.\d+)+", str(lockdown.get("version", ""))):
        errors.append(f"safbox_hardening_lockdown: version {lockdown.get('version')!r} is not an exact release")
    if not re.fullmatch(r"[0-9a-f]{40}", str(lockdown.get("commit", ""))):
        errors.append("safbox_hardening_lockdown: commit must be the full SHA the release tag names")
    if not str(lockdown.get("src", "")).startswith("https://"):
        errors.append("safbox_hardening_lockdown: src is not HTTPS")
    if not re.fullmatch(r"v\d+r\d+", str(lockdown.get("benchmark", ""))):
        errors.append("safbox_hardening_lockdown: benchmark must name the STIG release (v<version>r<release>)")
    roles = [r for r in requirements.get("roles") or [] if isinstance(r, dict)]
    entry = next((r for r in roles if r.get("name") == lockdown.get("name")), None)
    if not entry:
        errors.append(f"requirements.yml: no role {lockdown.get('name')!r} for the safbox_hardening_lockdown pin")
    else:
        for key, want in (("src", lockdown.get("src")), ("scm", "git"), ("version", lockdown.get("commit"))):
            if str(entry.get(key)) != str(want):
                errors.append(f"requirements.yml: role {entry['name']} {key} is {entry.get(key)!r}, "
                              f"group_vars pins {want!r}")
    if inputs.get("lockdown_version") is None:
        errors.append("verify: inspec.yml has no input lockdown_version for the safbox_hardening_lockdown pin")
    elif str(inputs.get("lockdown_version")) != str(lockdown.get("version")):
        errors.append(f"verify: input lockdown_version defaults to {inputs.get('lockdown_version')!r} "
                      f"but group_vars pins {lockdown.get('version')!r}")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr); sys.exit(1)
print(f"PASS: {len(tools)} tool pins carry versions, downloads carry sha256; {len(images)} images pinned by digest; "
      "the Lockdown role is pinned by release and commit in group_vars and requirements.yml; "
      "profile inputs match the pins and service ports")
PY
