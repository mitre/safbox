#!/usr/bin/env bash
# Static checks for the validation profiles (ADR-0001 §Validation stages:
# one root wrapper over per-family children).
#
#   verify/inspec-safbox         root wrapper: depends on every child by path,
#                                includes each one's controls, declares no
#                                platform support of its own and no controls
#   verify/el10-infrastructure   SAFBox infrastructure controls for the RHEL 10
#                                family, impact 1.0 (critical) except documented
#                                findings, which are low and tagged finding; its
#                                supports clause is the only platform gate, so
#                                no control branches on the OS family
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

# The supports clause is el10-infrastructure's only platform gate: no control
# reads the OS family or carries another family's commands, unit or
# architecture names. A later OS family brings its own child profile. The
# check runs on Ruby's own tokens (Ripper, in CINC Auditor's Ruby), so
# comments and string contents are never mistaken for code:
#   - an `os` identifier must be followed by . and an allowed member (arch);
#     any other member (family, families, family_hierarchy, name, release,
#     params, to_h, a predicate such as redhat?), os[...] and a bare os (an
#     alias) are rejected. ALLOWED lists the exact lines that use family,
#     name or release as a recorded value, and fails when one goes stale.
#   - any `platform` identifier is rejected (platform.family, platform[...]).
#   - dpkg, apt, apt-get, aptitude, debian, ubuntu, amd64 and arm64 are
#     rejected in identifiers and in code strings, with _ counting as a
#     separator (/etc/debian_version, debian_units); the prose of desc and
#     title statements and comments are not code.
#   - ssh and chrony as the unit argument of service() or systemd_service().
"$RUBY" -rripper - "$INFRA/controls" <<'RUBY'
dir = ARGV[0]
ALLOWED = {
  ['os.rb', 13, 'family'] => 'describe os.family do',
  ['os.rb', 22, 'release'] => 'describe os.release.to_s do',
  ['os.rb', 33, 'name'] => 'subject { os.name }',
}
SAFE_MEMBERS = %w[arch].freeze
FOREIGN_WORD = /(?<![a-z0-9])(dpkg|apt|apt-get|aptitude|debian|ubuntu|amd64|arm64)(?![a-z0-9])/i
SKIP = %i[on_sp on_ignored_sp on_comment on_embdoc_beg on_embdoc on_embdoc_end on_ignored_nl].freeze
errors = []
used = {}
Dir.glob(File.join(dir, '*.rb')).sort.each do |path|
  name = File.basename(path)
  src = File.read(path)
  lines = src.lines
  toks = Ripper.lex(src).reject { |t| SKIP.include?(t[1]) }
  report = ->(line, what) { errors << "controls/#{name}:#{line} has #{what}: #{lines[line - 1].to_s.strip}" }
  # String contents of a desc or title statement (and of its heredoc, whose
  # body Ripper yields after the statement's newline) are prose. Only
  # string contents are exempt: identifiers there, including those
  # interpolated into the prose, are still checked.
  prose = false
  pending_heredoc = false
  heredoc = false
  statement_start = true
  toks.each_with_index do |(pos, type, text), i|
    line = pos[0]
    heredoc = false if type == :on_heredoc_end
    if %i[on_nl on_semicolon].include?(type)
      heredoc = true if pending_heredoc && type == :on_nl
      pending_heredoc = false
      prose = false
      statement_start = true
      next
    end
    prose = true if statement_start && type == :on_ident && %w[desc title].include?(text)
    pending_heredoc = true if prose && type == :on_heredoc_beg
    statement_start = %i[on_kw on_lbrace].include?(type) && %w[do {].include?(text)
    nxt = toks[i + 1] || [[0, 0], :none, '']
    after = toks[i + 2] || [[0, 0], :none, '']
    case type
    when :on_ident, :on_const
      if text == 'os'
        if %i[on_period].include?(nxt[1]) || (nxt[1] == :on_op && %w[&. ::].include?(nxt[2]))
          member = after[2]
          unless SAFE_MEMBERS.include?(member)
            key = [name, line, member]
            if ALLOWED[key] && lines[line - 1].strip == ALLOWED[key]
              used[key] = true
            else
              report.call(line, "os.#{member}, which reads the OS family")
            end
          end
        else
          report.call(line, 'os used other than as os.<member> (os[...] or an alias)')
        end
      elsif text == 'platform'
        report.call(line, 'the platform resource, which reads the OS family')
      elsif text.match?(FOREIGN_WORD)
        report.call(line, "a Debian-family name (#{text})")
      elsif %w[service systemd_service].include?(text)
        j = i + 1
        j += 1 if toks[j] && toks[j][1] == :on_lparen
        if toks[j] && toks[j][1] == :on_tstring_beg && toks[j + 1] && toks[j + 1][1] == :on_tstring_content &&
           %w[ssh chrony].include?(toks[j + 1][2])
          report.call(line, "a Debian-family unit name (#{toks[j + 1][2]})")
        end
      end
    when :on_tstring_content
      next if prose || heredoc

      report.call(line, "a Debian-family name in a code string (#{text.strip[0, 40]})") if text.match?(FOREIGN_WORD)
    end
  end
end
ALLOWED.each_key do |key|
  errors << "allowlist entry controls/#{key[0]}:#{key[1]} (os.#{key[2]}) no longer matches the source" unless used[key]
end
unless errors.empty?
  errors.each { |e| warn "FAIL: el10-infrastructure: #{e}; the supports clause is the only platform gate" }
  exit 1
end
RUBY

# Every control declared in el10-infrastructure is loaded, and the loaded
# profile is handed to the metadata checks below.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cinc-auditor json "$INFRA" --chef-license accept-silent 2>/dev/null >"$work/infra.json" \
  || { echo "FAIL: cinc-auditor json cannot load el10-infrastructure" >&2; exit 1; }
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
# A documented finding (a known weakness kept visible as a failing control,
# never hidden or waived) is low severity, 0.1 to below 0.4, and says so
# with a finding tag naming the weakness.
for c in controls:
    finding = (c.get("tags") or {}).get("finding")
    if finding:
        if not 0.1 <= (c.get("impact") or 0) < 0.4:
            errors.append(f"el10-infrastructure: finding {c['id']} has impact {c.get('impact')}; a finding is low (0.1 to 0.39)")
        if not isinstance(finding, str) or not finding.strip():
            errors.append(f"el10-infrastructure: finding {c['id']} must name the weakness in its finding tag")
    elif c.get("impact") != 1.0:
        errors.append(f"el10-infrastructure: {c['id']} has impact {c.get('impact')}; every infrastructure control "
                      "is 1.0 unless it is a documented finding (tag finding)")
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
print(f"PASS: el10-infrastructure loads all {len(ids)} declared controls (impact 1.0 or tagged low findings) "
      "for redhat 10.* with no OS family branch; "
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
