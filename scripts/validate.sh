#!/usr/bin/env bash
# Validate a SAFBox from the outside: run a validation profile from this
# machine over SSH with CINC Auditor, then gate on a threshold with the SAF
# CLI. The build calls it against the build VM before the seal, and the
# clone test against a deployed clone as the release gate (ADR-0001
# §Validation stages), both with the verify/inspec-safbox wrapper.
#
#   scripts/validate.sh [--site-inputs FILE] [--site-threshold FILE] [--ssh-config FILE] \
#     <user@host[:port]> <private-key> <label> <profile> <threshold> <inputs-file>
#
#   <profile>      profile directory, normally verify/inspec-safbox
#   <threshold>    tracked SAF CLI threshold, verify/thresholds/<context>.yml
#   <inputs-file>  tracked inputs, verify/inputs/<context>.yml, passed to CINC
#                  Auditor with --input-file
#   --site-inputs FILE     a site's inputs, layered after the tracked file
#                          (its values win)
#   --site-threshold FILE  a site's threshold, used INSTEAD of the tracked
#                          one: a site that changes which controls apply
#                          (a tools group switched off) states the exact
#                          set it expects
#   --ssh-config FILE      the SSH client config CINC Auditor reads instead
#                          of its defaults (~/.ssh/config, /etc/ssh/ssh_config);
#                          /dev/null reads none. Unlike OpenSSH, its SSH
#                          library fails on a default file it cannot open.
#                          Absent, the defaults apply, so an operator's
#                          ProxyJump or bastion settings keep working
#
# Inputs only ever come from files, never --input on the command line, so a
# run is reproducible from what is tracked plus what the site names.
# Results land in .build/validate-<label>-<UTC timestamp>.json (HDF-readable).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage() {
  echo "usage: $0 [--site-inputs FILE] [--site-threshold FILE] [--ssh-config FILE] <user@host[:port]> <private-key> <label> <profile> <threshold> <inputs-file>" >&2
  exit 2
}

SITE_INPUTS=""
SITE_THRESHOLD=""
SSH_CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --site-inputs) [ -n "${2:-}" ] || usage; SITE_INPUTS=$2; shift 2 ;;
    --site-threshold) [ -n "${2:-}" ] || usage; SITE_THRESHOLD=$2; shift 2 ;;
    --ssh-config) [ -n "${2:-}" ] || usage; SSH_CONFIG=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "validate.sh: unknown option $1" >&2; usage ;;
    *) break ;;
  esac
done
[ $# -eq 6 ] || usage
TARGET=$1
KEY=$2
LABEL=$3

# Absolute paths: the SAF CLI runs from a scratch directory (below).
abs() { # file description
  [ -f "$1" ] || { echo "validate.sh: $2 $1 not found" >&2; exit 1; }
  printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
}
[ -d "$4" ] || { echo "validate.sh: profile $4 not found" >&2; exit 1; }
PROFILE=$(cd "$4" && pwd)
THRESHOLD=$(abs "$5" threshold)
INPUT_FILES=("$(abs "$6" "inputs file")")
if [ -n "$SITE_INPUTS" ]; then INPUT_FILES+=("$(abs "$SITE_INPUTS" "site inputs file")"); fi
if [ -n "$SITE_THRESHOLD" ]; then THRESHOLD=$(abs "$SITE_THRESHOLD" "site threshold"); fi
# /dev/null (no config) is passed as is: abs() accepts regular files only.
SSH_ARGS=()
if [ -n "$SSH_CONFIG" ]; then
  if [ "$SSH_CONFIG" = /dev/null ]; then SSH_ARGS=(--ssh-config-file /dev/null)
  else SSH_ARGS=(--ssh-config-file "$(abs "$SSH_CONFIG" "ssh config file")"); fi
fi

for tool in cinc-auditor saf; do
  command -v "$tool" >/dev/null || { echo "validate.sh: $tool not found on this machine" >&2; exit 1; }
done

OUT_DIR="$ROOT/.build"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
RESULTS="$OUT_DIR/validate-$LABEL-$(date -u +%Y%m%dT%H%M%SZ).json"

echo "validate.sh: $PROFILE against $TARGET"
echo "validate.sh: inputs ${INPUT_FILES[*]}"
echo "validate.sh: threshold $THRESHOLD"
# A lockfile left by an earlier scan pins the dependency paths and refs it
# resolved then, and CINC Auditor reads it even after inspec.yml changes (a
# renamed child, a new baseline commit), silently scanning stale content.
# Lockfiles are generated and git-ignored: drop any under verify/ and write
# none, so every scan resolves its dependencies from inspec.yml.
find "$ROOT/verify" -name inspec.lock -type f -delete
rc=0
cinc-auditor exec "$PROFILE" \
  -t "ssh://$TARGET" -i "$KEY" --sudo ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
  --input-file "${INPUT_FILES[@]}" --no-create-lockfile \
  --reporter cli "json:$RESULTS" --no-color --chef-license accept-silent || rc=$?
# 0 all passed, 100 a test failed, 101 a test was skipped; anything else is
# a tool or connection error and must not be mistaken for a verdict.
case "$rc" in
  0|100|101) ;;
  *) echo "validate.sh: cinc-auditor exited $rc (tool or connection error)" >&2; exit 1 ;;
esac

# saf validate threshold exits 0 on a missing input file, so a scan that
# wrote no results must fail here rather than pass the gate.
[[ -s "$RESULTS" ]] || { echo "validate.sh: cinc-auditor wrote no results to $RESULTS" >&2; exit 1; }

# The SAF CLI writes saf-cli.log to its working directory; keep it out of
# the caller's.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
(cd "$scratch" && saf validate threshold -i "$RESULTS" -T "$THRESHOLD")
echo "validate.sh: $LABEL meets $THRESHOLD ($RESULTS)"
