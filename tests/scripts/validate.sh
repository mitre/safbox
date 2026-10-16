#!/usr/bin/env bash
# scripts/validate.sh hands CINC Auditor the SSH client config an operator
# names with --ssh-config, and nothing new when none is named (ADR-0001
# Verification Strategy: the outside-in gates run from the build runner),
# and never writes its results over another scan's results file.
# Stub cinc-auditor and saf record their arguments; no target is contacted.
#
#   tests/scripts/validate.sh [path to validate.sh]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VALIDATE=${1:-$ROOT/scripts/validate.sh}
# Absolute, because case (d) runs it from another directory.
VALIDATE=$(cd "$(dirname "$VALIDATE")" && pwd)/$(basename "$VALIDATE")

tmp=$(mktemp -d)
# validate.sh writes its results under .build/; remove the ones this test
# causes, by their label.
LABEL="selftest-$$"
trap 'rm -rf "$tmp"; rm -f "$ROOT/.build/validate-$LABEL-"*.json' EXIT
mkdir -p "$tmp/bin" "$tmp/profile" "$tmp/work"
# cinc-auditor: record argv one per line, write a results file where the
# json reporter was pointed, exit 0 (all passed).
cat > "$tmp/bin/cinc-auditor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
for a in "$@"; do case "$a" in json:*) echo '{}' > "${a#json:}" ;; esac; done
EOF
cat > "$tmp/bin/saf" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/cinc-auditor" "$tmp/bin/saf"
printf -- '---\n' > "$tmp/threshold.yml"
printf -- '---\n' > "$tmp/inputs.yml"
printf '# empty\n' > "$tmp/work/ssh_config"
export STUB_ARGV="$tmp/argv"

failures=0
fail() { echo "FAIL: $*" >&2; failures=1; }
# expect <description> <got> <want>
expect() {
  if [ "$2" = "$3" ]; then echo "ok: $1"
  else fail "$1: got '$2', want '$3'"; fi
}
# scan <options...>: validate.sh with fixed positional arguments after them.
scan() {
  rm -f "$STUB_ARGV"
  PATH="$tmp/bin:$PATH" "$VALIDATE" "$@" packer@192.0.2.10:22 "$tmp/key" "$LABEL" \
    "$tmp/profile" "$tmp/threshold.yml" "$tmp/inputs.yml" >"$tmp/out" 2>"$tmp/err"
}
# run <options...>: scan with none of this test's earlier results files
# present, so each case's results file gets the plain timestamped name.
run() {
  rm -f "$ROOT/.build/validate-$LABEL-"*.json
  scan "$@"
}
# The cinc-auditor argv validate.sh must produce: the default command line,
# with "--ssh-config-file FILE" after --sudo when FILE is given. The results
# file name carries a timestamp, so it is normalised in the recorded argv.
want_argv() {
  printf '%s\n' exec "$tmp/profile" -t ssh://packer@192.0.2.10:22 -i "$tmp/key" --sudo
  if [ $# -gt 0 ]; then printf '%s\n' --ssh-config-file "$1"; fi
  printf '%s\n' --input-file "$tmp/inputs.yml" --no-create-lockfile --reporter cli \
    "json:$ROOT/.build/validate-$LABEL-TIMESTAMP.json" --no-color --chef-license accept-silent
}
got_argv() {
  sed -E "s#^(json:.*/validate-$LABEL-)[0-9]{8}T[0-9]{6}Z(\.json)\$#\1TIMESTAMP\2#" "$STUB_ARGV"
}
# expect_argv <description> [ssh config FILE]
expect_argv() {
  local desc=$1; shift
  local want got
  want=$(want_argv "$@"); got=$(got_argv)
  if [ "$got" = "$want" ]; then echo "ok: $desc"
  else
    fail "$desc: cinc-auditor command line differs:"
    diff <(echo "$want") <(echo "$got") | sed 's/^/  /' >&2 || true
  fi
}
USAGE="usage: $VALIDATE [--site-inputs FILE] [--site-threshold FILE] [--ssh-config FILE] <user@host[:port]> <private-key> <label> <profile> <threshold> <inputs-file>"

# The value following --ssh-config-file in the recorded argv, or "absent".
ssh_config_arg() {
  awk 'f {print; exit} $0 == "--ssh-config-file" {f=1} END {if (!f) print "absent"}' "$STUB_ARGV"
}

# (a) No --ssh-config: exactly the default command line, no --ssh-config-file.
if run; then
  expect "default passes no --ssh-config-file" "$(ssh_config_arg)" absent
  expect_argv "default cinc-auditor command line unchanged"
else
  fail "default run exited non-zero: $(cat "$tmp/err")"
fi

# (b) --ssh-config /dev/null: the default command line plus the flag, once,
# before --input-file (CINC Auditor parses --ssh-config-file as a list that
# runs to the next option).
if run --ssh-config /dev/null; then
  expect_argv "--ssh-config /dev/null passed through exactly" /dev/null
else
  fail "/dev/null run exited non-zero: $(cat "$tmp/err")"
fi

# usage_error <description> <validate.sh arguments...>: exit 2, stderr is
# exactly the usage line (not an "unknown option" path), cinc-auditor never ran.
usage_error() {
  local desc=$1; shift
  rm -f "$STUB_ARGV"
  local rc=0
  PATH="$tmp/bin:$PATH" "$VALIDATE" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$STUB_ARGV" ] && [ "$(cat "$tmp/err")" = "$USAGE" ]; then
    echo "ok: $desc"
  else
    fail "$desc: exit $rc, cinc-auditor ran: $([ -e "$STUB_ARGV" ] && echo yes || echo no), stderr: $(cat "$tmp/err")"
  fi
}
# (c) No value: the option last, and an empty value followed by a full,
# otherwise valid command line (without the value check an empty value
# would mean "no --ssh-config" and the scan would run).
usage_error "--ssh-config without a value is a usage error" --ssh-config
usage_error "--ssh-config with an empty value is a usage error" --ssh-config "" \
  packer@192.0.2.10:22 "$tmp/key" "$LABEL" "$tmp/profile" "$tmp/threshold.yml" "$tmp/inputs.yml"

# (c) Missing file: named, exit 1, CINC Auditor never runs.
rc=0; run --ssh-config "$tmp/nope" || rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$STUB_ARGV" ] \
  && [ "$(cat "$tmp/err")" = "validate.sh: ssh config file $tmp/nope not found" ]; then
  echo "ok: a missing --ssh-config file is refused"
else
  fail "missing file: exit $rc, stderr: $(cat "$tmp/err")"
fi

# (d) A relative path reaches CINC Auditor as an absolute one.
if (cd "$tmp/work" && run --ssh-config ssh_config); then
  expect_argv "a relative --ssh-config is made absolute" "$tmp/work/ssh_config"
else
  fail "relative run exited non-zero: $(cat "$tmp/err")"
fi

# (e) A path with spaces stays one argument.
printf '# empty\n' > "$tmp/work/ssh config with spaces"
if run --ssh-config "$tmp/work/ssh config with spaces"; then
  expect_argv "a --ssh-config path with spaces stays one argument" "$tmp/work/ssh config with spaces"
else
  fail "spaces run exited non-zero: $(cat "$tmp/err")"
fi

# (f) Another scan with the same label already wrote this second's results
# file (two concurrent builds reaching their gates): this scan writes its own
# file and leaves the other's alone. The names for this second and the next
# two are taken, so the scan's second falls inside them.
rm -f "$ROOT/.build/validate-$LABEL-"*.json
mkdir -p "$ROOT/.build"
now=$(date -u +%s)
taken=()
for i in 0 1 2; do
  stamp=$(date -u -d "@$((now + i))" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -r "$((now + i))" +%Y%m%dT%H%M%SZ)
  f="$ROOT/.build/validate-$LABEL-$stamp.json"
  echo other-scan > "$f"; taken+=("$f")
done
if scan; then
  results=$(sed -n 's/^json://p' "$STUB_ARGV")
  if [[ "$results" =~ /validate-$LABEL-[0-9]{8}T[0-9]{6}Z-2\.json$ ]]; then
    echo "ok: a taken results name gets -2"
  else
    fail "results file with a taken name: got '$results'"
  fi
  kept=yes
  for f in "${taken[@]}"; do [ "$(cat "$f")" = other-scan ] || kept=no; done
  expect "the other scan's results file is untouched" "$kept" yes
else
  fail "taken-name run exited non-zero: $(cat "$tmp/err")"
fi

[ "$failures" -eq 0 ] || exit 1
echo "PASS: validate.sh passes --ssh-config through and nothing by default, and never reuses a results file"
