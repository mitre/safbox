#!/usr/bin/env bash
# Runs on the SAFBox, fed over ssh by tests/fips/exercise-tools.sh; see there.
#   bash -s -- <https-url> <expected-tools> < exercise-remote.sh
# Exit 0 no tool failed, 1 a tool failed, 2 the host is not enforcing FIPS.
set -uo pipefail
export LC_ALL=C
URL=${1:?https url}
EXPECTED=",${2:?comma-separated expected tools},"
SAF=/usr/local/bin/saf
PACKER=/usr/local/bin/packer

passed=0 failed=0 skipped=0 warned=0
report() {
  local verdict=$1 tool=$2 detail=$3
  printf '%-5s %-13s %s\n' "$verdict" "$tool" "$detail"
  case "$verdict" in
    PASS) passed=$((passed + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
    SKIP) skipped=$((skipped + 1)) ;;
    WARN) warned=$((warned + 1)) ;;
  esac
}

# Only a FIPS-enforcing host can show FIPS breakage.
fips=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)
policy=$(update-crypto-policies --show 2>/dev/null || echo none)
if [[ "$fips" != 1 ]] || [[ "$policy" != FIPS* ]] \
  || ! openssl list -providers 2>/dev/null | grep -A3 -E '^\s+fips$' | grep -q 'status: active'; then
  echo "not FIPS-enforcing: fips_enabled=$fips crypto-policy=$policy (OpenSSL FIPS provider must be active)"
  exit 2
fi
echo "FIPS enforcement: fips_enabled=1, crypto policy $policy, OpenSSL FIPS provider active"
echo "TLS endpoint: $URL"

echo "Expected tools: ${EXPECTED:1:${#EXPECTED}-2}"

# Decide whether to exercise a tool, as the validation profile does: SKIP a
# tool that is not expected (its tools group is switched off), FAIL an
# expected tool that is missing, exercise the rest.
present() {
  local tool=$1 path=$2
  if [[ "$EXPECTED" != *",$tool,"* ]]; then
    report SKIP "$tool" "not in the expected tools (its tools group is switched off)"
    return 1
  fi
  if command -v "$path" >/dev/null 2>&1; then return 0; fi
  report FAIL "$tool" "expected but $path is missing"
  return 1
}

WORK=$(mktemp -d)
trap 'cd / && rm -rf "$WORK"' EXIT
LOG=$WORK/log

# Last lines of a failed step's output, on one line.
tail_log() { tail -n 5 "$LOG" | tr '\n' ' ' | cut -c1-400; }

# --- CINC Auditor: an InSpec http resource fetches the URL over TLS and the
# file resource hashes a file with SHA-256. The JSON results feed the SAF CLI.
CINC_JSON=$WORK/cinc.json
if present "cinc-auditor" cinc-auditor; then
  mkdir -p "$WORK/profile/controls"
  printf 'name: fips-exercise\nversion: 0.1.0\nsupports:\n  - platform: os\n' >"$WORK/profile/inspec.yml"
  cat >"$WORK/profile/controls/exercise.rb" <<'RUBY'
control 'fips-exercise-1' do
  impact 0.5
  title 'TLS and SHA-256 work under FIPS enforcement'
  describe http(ENV.fetch('EXERCISE_URL')) do
    its('status') { should cmp 200 }
  end
  describe file('/etc/os-release') do
    its('sha256sum') { should match(/\A\h{64}\z/) }
  end
end
RUBY
  if EXERCISE_URL=$URL cinc-auditor exec "$WORK/profile" --no-color --chef-license accept-silent \
    --reporter "json:$CINC_JSON" >"$LOG" 2>&1; then
    report PASS "cinc-auditor" "InSpec http resource GET over TLS returned 200; file sha256sum computed"
  else
    report FAIL "cinc-auditor" "$(tail_log)"
  fi
  ruby=$(dirname "$(readlink -f "$(command -v cinc-auditor)")")/../embedded/bin/ruby
  if [[ -x "$ruby" ]]; then
    mode=$("$ruby" -ropenssl -e 'print OpenSSL::OPENSSL_LIBRARY_VERSION, " fips_mode=", OpenSSL.fips_mode' 2>&1)
    [[ "$mode" == *fips_mode=true ]] || report WARN "cinc-auditor" "embedded Ruby uses its own ${mode}, not the system FIPS provider"
  fi
fi

# --- SAF CLI: convert CINC Auditor's results to a checklist and back; the
# checklist-to-HDF mapper hashes each profile with SHA-256 (node crypto).
if present "saf-cli" "$SAF"; then
  # The SAF CLI writes saf-cli.log to its working directory; run it in the
  # scratch directory so nothing is left in the login user's home.
  cd "$WORK" || exit 3
  if [[ ! -s "$CINC_JSON" ]]; then
    report SKIP "saf-cli" "no CINC Auditor results to convert"
  elif "$SAF" convert hdf2ckl -i "$CINC_JSON" -o "$WORK/exercise.ckl" >"$LOG" 2>&1 \
    && "$SAF" convert ckl2hdf -i "$WORK/exercise.ckl" -o "$WORK/roundtrip.json" >>"$LOG" 2>&1 \
    && digest=$(node -e 'const h=require(process.argv[1]); process.stdout.write(h.profiles[0].sha256 || "")' \
      "$WORK/roundtrip.json" 2>>"$LOG") && [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    report PASS "saf-cli" "hdf2ckl then ckl2hdf; profile sha256 ${digest:0:16}... computed by node crypto"
  else
    report FAIL "saf-cli" "$(tail_log)"
  fi
  fips_node=$(node -p 'require("crypto").getFips()' 2>&1)
  [[ "$fips_node" == 1 ]] || report WARN "saf-cli" "Node.js reports crypto.getFips()=${fips_node}"
  [[ ! -e "$HOME/saf-cli.log" ]] || report FAIL "saf-cli" "left $HOME/saf-cli.log behind"
fi

# --- Ansible: the uri module fetches the URL over TLS and stat hashes a file
# with SHA-256 (Python ssl and hashlib on the system OpenSSL).
if present "ansible" ansible; then
  export ANSIBLE_HOME=$WORK/ansible ANSIBLE_LOCAL_TEMP=$WORK/ansible/tmp ANSIBLE_REMOTE_TEMP=$WORK/ansible/tmp \
    ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False ANSIBLE_NOCOLOR=1
  # ansible-core refuses to run without a UTF-8 locale.
  if LC_ALL=C.UTF-8 ansible localhost -c local -m ansible.builtin.uri -a "url=$URL" >"$LOG" 2>&1 \
    && LC_ALL=C.UTF-8 ansible localhost -c local -m ansible.builtin.stat \
      -a "path=/etc/os-release checksum_algorithm=sha256" >>"$LOG" 2>&1; then
    report PASS "ansible" "uri module GET over TLS succeeded; stat sha256 checksum computed"
  else
    report FAIL "ansible" "$(tail_log)"
  fi
  read -r -a python <<<"$(head -n 1 "$(command -v ansible)" | sed 's/^#![[:space:]]*//')"
  fips_py=$("${python[@]}" -c 'import _hashlib; print(_hashlib.get_fips_mode())' 2>&1)
  [[ "$fips_py" == 1 ]] || report WARN "ansible" "Python hashlib reports get_fips_mode()=${fips_py}"
fi

# --- Packer: the http data source fetches the URL over TLS and the HCL
# sha256() function hashes the body, run with Go's FIPS 140-3 mode on.
if present "packer" "$PACKER"; then
  cat >"$WORK/exercise.pkr.hcl" <<'HCL'
variable "url" {
  type = string
}

data "http" "exercise" {
  url = var.url
}

locals {
  digest = sha256(data.http.exercise.body)
}

source "null" "exercise" {
  communicator = "none"
}

build {
  sources = ["source.null.exercise"]

  post-processor "shell-local" {
    inline = ["echo exercise-digest=${local.digest}"]
  }
}
HCL
  export CHECKPOINT_DISABLE=1 PACKER_CONFIG_DIR=$WORK/packer PACKER_PLUGIN_PATH=$WORK/packer/plugins \
    PACKER_CACHE_DIR=$WORK/packer/cache
  if GODEBUG=fips140=on "$PACKER" build -color=false -var "url=$URL" "$WORK/exercise.pkr.hcl" >"$LOG" 2>&1 \
    && digest=$(sed -n 's/.*exercise-digest=\([0-9a-f]\{64\}\).*/\1/p' "$LOG" | head -n 1) \
    && [[ -n "$digest" ]]; then
    # The http data source fails the build on any non-2xx response.
    report PASS "packer" "http data source GET over TLS succeeded; sha256 ${digest:0:16}... (GODEBUG=fips140=on)"
  else
    report FAIL "packer" "$(tail_log)"
  fi
  # GODEBUG=fips140=on is requested but not verified: Packer exposes no way
  # to report crypto/fips140.Enabled(), and a binary built with a Go older
  # than 1.24 ignores the setting silently (the pinned 1.16.1 is built with
  # go1.26). Packer's FIPS posture is tracked separately; this exercise only
  # shows TLS and hashing work on a FIPS-enforcing host.
  report WARN "packer" "Go binary: its crypto is Go's own module (fips140=on requested, not verifiable), not the system OpenSSL provider"
fi

echo "FIPS exercise: $passed passed, $failed failed, $skipped skipped, $warned warnings"
[[ "$failed" -eq 0 ]] || exit 1
exit 0
