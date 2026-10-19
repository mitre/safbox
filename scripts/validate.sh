#!/usr/bin/env bash
# Validate a SAFBox from the outside: scan it over SSH with CINC Auditor using
# the profiles in verify/profiles/ (safbox, safbox-rhel10-stig-overlay), and
# check each result against its SAF CLI threshold in verify/thresholds/. In
# the release context, with --client-inputs, also run the safbox-client
# profile on this machine against the box's names at its address, as a
# browser here would.
#
#   scripts/validate.sh [--site-inputs FILE] [--ssh-config FILE] \
#     [--client-inputs FILE] <user@host[:port]> <private-key> <build|release> [label]
#
#   build    the build VM before the seal (verify/inputs/build.yml)
#   release  a deployed clone of a sealed template (the profiles' defaults)
#   --site-inputs FILE    a site's inputs, layered after the context's
#   --ssh-config FILE     the SSH client config CINC Auditor reads instead of
#                         ~/.ssh/config and /etc/ssh/ssh_config; /dev/null
#                         reads none
#   --client-inputs FILE  release only: the box's passwords for the
#                         safbox-client profile, a .yml or .yaml inputs
#                         file of mode 0600 (scripts/clone-and-ssh.sh writes
#                         one). That profile signs in, uploads the safbox
#                         profile's results to Heimdall, creates a Vulcan
#                         project and changes safuser's Keycloak password,
#                         so give it for a clone only, never an appliance in
#                         use.
#
# Results land in .build/validate-<label>-<profile>-<UTC time>.json, with
# -2, -3, ... before .json when another scan took that name first.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
usage() {
  echo "usage: $0 [--site-inputs FILE] [--ssh-config FILE] [--client-inputs FILE] <user@host[:port]> <private-key> <build|release> [label]" >&2
  exit 2
}

INPUT_ARGS=()
SITE_INPUTS=""
CLIENT_INPUTS=""
SSH_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --site-inputs) [ -n "${2:-}" ] || usage; SITE_INPUTS=$2; shift 2 ;;
    --ssh-config) [ -n "${2:-}" ] || usage; SSH_ARGS=(--ssh-config-file "$2"); shift 2 ;;
    --client-inputs) [ -n "${2:-}" ] || usage; CLIENT_INPUTS=$2; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 3 ] || [ $# -eq 4 ] || usage
TARGET=$1
KEY=$2
CONTEXT=$3
LABEL=${4:-$3}
case "$CONTEXT" in
  build) INPUT_ARGS=("$ROOT/verify/inputs/build.yml") ;;
  release) ;;
  *) usage ;;
esac
if [ -n "$SITE_INPUTS" ]; then INPUT_ARGS+=("$(realpath "$SITE_INPUTS")"); fi
if [ -n "$CLIENT_INPUTS" ]; then
  [ "$CONTEXT" = release ] || { echo "validate.sh: --client-inputs is for the release context only" >&2; exit 2; }
  # CINC Auditor reads an inputs file by its extension.
  case "$CLIENT_INPUTS" in
    *.yml | *.yaml) ;;
    *) echo "validate.sh: $CLIENT_INPUTS must be a YAML inputs file named .yml or .yaml" >&2; exit 2 ;;
  esac
  # The passwords stay readable by this user only.
  if [ -z "$(find "$CLIENT_INPUTS" -maxdepth 0 -type f -perm 0600 2>/dev/null)" ]; then
    echo "validate.sh: $CLIENT_INPUTS must be a file of mode 0600" >&2
    exit 2
  fi
  CLIENT_INPUTS=$(realpath "$CLIENT_INPUTS")
fi

for tool in cinc-auditor saf; do
  command -v "$tool" >/dev/null || { echo "validate.sh: $tool not found on this machine" >&2; exit 1; }
done
mkdir -p "$ROOT/.build"
chmod 700 "$ROOT/.build"

# A lockfile left by a manual scan pins the dependency refs it resolved then
# and is read even after inspec.yml changes. Remove any and write none. rm -f,
# so a concurrent scan removing the same file first is not an error.
find "$ROOT/verify" -name inspec.lock -type f -exec rm -f -- {} +

# The SAF CLI writes saf-cli.log to its working directory; keep it out of
# the caller's. The client profile keeps its files (the certificate the box
# served, cookie jars, passwords) in a 0700 directory in here.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# scan PROFILE THRESHOLD [INPUT-FILE...] -- EXEC-ARGS...: scan with the
# context's inputs, then the INPUT-FILEs, and leave the results file in
# $results.
scan() {
  local profile=$1 threshold=$2 n=1 rc=0 base inputs=()
  shift 2
  inputs=(${INPUT_ARGS[@]+"${INPUT_ARGS[@]}"})
  while [ "$1" != -- ]; do inputs+=("$1"); shift; done
  shift
  if [ ${#inputs[@]} -gt 0 ]; then inputs=(--input-file "${inputs[@]}"); fi
  base="$ROOT/.build/validate-$LABEL-$profile-$(date -u +%Y%m%dT%H%M%SZ)"
  results="$base.json"
  # Reserve the results file: noclobber makes the create fail if a scan
  # started in the same second already took the name.
  until (set -C; : > "$results") 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -le 100 ] || { echo "validate.sh: cannot create a results file" >&2; exit 1; }
    results="$base-$n.json"
  done
  echo "validate.sh: $profile against $TARGET ($CONTEXT)"
  cinc-auditor exec "$ROOT/verify/profiles/$profile" "$@" \
    ${inputs[@]+"${inputs[@]}"} --no-create-lockfile \
    --reporter cli "json:$results" --no-color --chef-license accept-silent || rc=$?
  # 0 passed, 100 a test failed, 101 a test skipped; anything else is a tool
  # or connection error, not a verdict.
  case "$rc" in 0|100|101) ;; *) echo "validate.sh: cinc-auditor exited $rc" >&2; exit 1 ;; esac
  # saf validate threshold passes a missing file, so an empty one fails here.
  [ -s "$results" ] || { echo "validate.sh: no results in $results" >&2; exit 1; }
  if (cd "$scratch" && saf validate threshold -i "$results" -T "$ROOT/verify/thresholds/$threshold"); then
    echo "validate.sh: $profile meets verify/thresholds/$threshold ($results)"
  else
    echo "validate.sh: $profile FAILS verify/thresholds/$threshold ($results)" >&2
    failed=1
  fi
}

failed=0
box=(-t "ssh://$TARGET" -i "$KEY" --sudo ${SSH_ARGS[@]+"${SSH_ARGS[@]}"})
scan safbox "safbox-$CONTEXT.yml" -- "${box[@]}"
safbox_results=$results
scan safbox-rhel10-stig-overlay "stig-$CONTEXT.yml" -- "${box[@]}"
if [ -n "$CLIENT_INPUTS" ]; then
  # From this machine, as a browser: the box's address is the target's host.
  address=${TARGET#*@}
  address=${address%:*}
  mkdir -m 700 "$scratch/client"
  scan safbox-client client-release.yml "$CLIENT_INPUTS" -- -t local:// \
    --input "address=$address" "work_dir=$scratch/client" "hdf_file=$safbox_results"
fi
exit "$failed"
