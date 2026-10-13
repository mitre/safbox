#!/usr/bin/env bash
# FIPS exercise of every tool the tools role installs (ADR-0001 Phase 3):
# on a FIPS-enforcing SAFBox, run each tool once doing TLS or hashing, and
# report PASS, FAIL or SKIP per tool. Run from the build runner against a
# build VM or a clone, as the login user (no sudo):
#
#   tests/fips/exercise-tools.sh <user@host[:port]> <private-key> [https-url]
#
# The URL is fetched over TLS by each tool (default below); the box needs
# outbound HTTPS to it. Extra ssh options, for example for a clone whose host
# key changed, go in SAFBOX_SSH_OPTS. Exits 0 when no tool failed, 1 when one
# did, 2 when the target is not enforcing FIPS (nothing was exercised).
#
# SAFBOX_EXPECTED_TOOLS lists the tools the image ships, as the validation
# profile's expected_tools input does (default all four: cinc-auditor,
# saf-cli, ansible, packer). A tool left out (its tools group switched off)
# is a SKIP; an expected tool that is missing is a FAIL. WARN lines say
# where a tool's cryptography is not the system OpenSSL FIPS provider: the
# tool worked under FIPS enforcement but its crypto bypasses it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TARGET=${1:?user@host[:port]}
KEY=${2:?private key}
URL=${3:-https://releases.hashicorp.com/}
EXPECTED=${SAFBOX_EXPECTED_TOOLS:-cinc-auditor,saf-cli,ansible,packer}
[[ "$EXPECTED" =~ ^[a-z-]+(,[a-z-]+)*$ ]] || { echo "exercise-tools.sh: SAFBOX_EXPECTED_TOOLS must be a comma-separated list" >&2; exit 3; }

host=$TARGET
port=22
if [[ "$TARGET" =~ ^(.+):([0-9]+)$ ]]; then
  host=${BASH_REMATCH[1]}
  port=${BASH_REMATCH[2]}
fi

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" -p "$port")
if [[ -n "${SAFBOX_SSH_OPTS:-}" ]]; then
  read -r -a extra <<<"$SAFBOX_SSH_OPTS"
  ssh_opts+=("${extra[@]}")
fi

rc=0
ssh "${ssh_opts[@]}" "$host" bash -s -- "$URL" "$EXPECTED" <"$ROOT/tests/fips/exercise-remote.sh" || rc=$?
case "$rc" in
  0) echo "exercise-tools.sh: no tool failed under FIPS enforcement on $host" ;;
  1) echo "exercise-tools.sh: at least one tool failed under FIPS enforcement on $host" >&2 ;;
  2) echo "exercise-tools.sh: $host is not enforcing FIPS; nothing was exercised" >&2 ;;
  *) echo "exercise-tools.sh: ssh or the remote script exited $rc" >&2 ;;
esac
exit "$rc"
