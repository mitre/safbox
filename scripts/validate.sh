#!/usr/bin/env bash
# Validate a SAFBox from the outside: run the inspec-safbox profile from this
# machine over SSH with CINC Auditor, then gate on verify/threshold.yml with
# the SAF CLI. Used by the build (against the build VM, before the seal) and
# by the clone test (against a deployed clone, as the release gate).
#
#   scripts/validate.sh <user@host[:port]> <private-key> <label> [input=value ...]
#
# Results land in .build/validate-<label>-<UTC timestamp>.json (HDF-readable).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:?user@host[:port]}
KEY=${2:?private key}
LABEL=${3:?label}
shift 3

for tool in cinc-auditor saf; do
  command -v "$tool" >/dev/null || { echo "validate.sh: $tool not found on this machine" >&2; exit 1; }
done

OUT_DIR="$ROOT/.build"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
RESULTS="$OUT_DIR/validate-$LABEL-$(date -u +%Y%m%dT%H%M%SZ).json"

inputs=()
if [ $# -gt 0 ]; then inputs=(--input "$@"); fi

rc=0
cinc-auditor exec "$ROOT/verify/inspec-safbox" \
  -t "ssh://$TARGET" -i "$KEY" --sudo \
  "${inputs[@]}" \
  --reporter cli "json:$RESULTS" --no-color --chef-license accept-silent || rc=$?
# 0 all passed, 100 a test failed, 101 a test was skipped; anything else is
# a tool or connection error and must not be mistaken for a verdict.
case "$rc" in
  0|100|101) ;;
  *) echo "validate.sh: cinc-auditor exited $rc (tool or connection error)" >&2; exit 1 ;;
esac

saf validate threshold -i "$RESULTS" -T "$ROOT/verify/threshold.yml"
echo "validate.sh: $LABEL meets verify/threshold.yml ($RESULTS)"
