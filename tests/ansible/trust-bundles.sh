#!/usr/bin/env bash
# Site CA bundles (the site_config role, task group safbox-site-config-1)
# on a live SAFBox, through the deploy-time path the rebuild guide gives:
# playbooks/safbox.yml with --tags safbox-site-config-1. No certificate is
# committed: the fixtures are throwaway CAs generated here, in every source
# and format the role takes:
#   org       a local PEM file with a root and an intermediate (path, pem)
#   single    a local DER file with one root, on P-256 (path, der)
#   archive   a zip, fetched by URL, holding a DER PKCS#7 bundle of a root
#             and an intermediate (url, pkcs7-der, member)
#   sha1      a root signed with SHA-1
#   weak      a root with an RSA 1024 key, below the crypto policy's level
#   offcurve  a root on brainpoolP256r1, a curve FIPS mode does not allow
#   empty     a PKCS#7 bundle that holds no certificate
# and checks, on the box:
#   0. the repository default (no override) trusts the DoD bundle: its
#      roots, from the profile's trust_bundle_anchors input, are trusted;
#   1. the three good bundles install one anchor file per certificate and
#      every certificate is in the extracted trust bundle;
#   2. a second run changes nothing;
#   3. a wrong sha256 fails the run and trusts nothing new: by URL in
#      get_url's own checksum check, by path in the role's;
#   4. a root the system crypto policy rejects (sha1, weak, offcurve) fails the
#      run, names the certificate, and trusts nothing new;
#   5. a malformed entry (unknown format, url and path both or neither, a
#      relative path, a member with .. or a leading /, an unknown key, two
#      bundles with one name) is refused before anything is fetched, and a
#      bundle with no certificate fails the run;
#   6. dropping bundles from the list removes their certificates, and an
#      empty list leaves no SAFBox anchor and no DoD root; a second empty run
#      changes nothing.
# The box is left at the repository default on exit, pass or fail (which
# downloads the DoD bundle again). The box must be in FIPS mode (every
# SAFBox is). Requires:
#   SAFBOX_HOST  address of a SAFBox (build VM or deployed clone)
#   SAFBOX_USER  SSH user with passwordless sudo
#   SAFBOX_KEY   path to that user's SSH private key
# and on this machine ansible-playbook, openssl, python3, ssh and scp.
#
#   tests/ansible/trust-bundles.sh [ansible-playbook args...]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

if [[ -z "${SAFBOX_HOST:-}" || -z "${SAFBOX_USER:-}" || -z "${SAFBOX_KEY:-}" ]]; then
  cat >&2 <<'MSG'
SKIP: the trust bundle test needs a live target.
Set SAFBOX_HOST, SAFBOX_USER and SAFBOX_KEY (path to the SSH private key)
to a SAFBox the appliance layer was applied to, then rerun.
MSG
  exit 2
fi
[[ -r "$SAFBOX_KEY" ]] || { echo "FAIL: SAFBOX_KEY=$SAFBOX_KEY is not readable" >&2; exit 2; }
SAFBOX_KEY=$(cd "$(dirname "$SAFBOX_KEY")" && pwd)/$(basename "$SAFBOX_KEY")
for tool in ansible-playbook openssl python3 ssh scp; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not installed" >&2; exit 1; }
done

work=$(mktemp -d)
fx=$work/fixtures
mkdir -p "$fx"
SSH_OPTS=(-i "$SAFBOX_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)
# One shell command line on the box, handed to its shell on stdin.
on_box() { ssh "${SSH_OPTS[@]}" "$SAFBOX_USER@$SAFBOX_HOST" bash -s <<<"$1"; }
# The archive is served to the box from its own disk by a file:// URL, the
# same get_url path a https:// URL takes.
REMOTE_ZIP=/var/tmp/safbox-trust-test.zip
ANCHORS=/etc/pki/ca-trust/source/anchors
EXTRACTED=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

cd "$ROOT/ansible"
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1

run_role() { # vars-file log [ansible-playbook args]
  local vars=$1 log=$2; shift 2
  ansible-playbook playbooks/safbox.yml -i "${SAFBOX_HOST}," -u "$SAFBOX_USER" --private-key "$SAFBOX_KEY" \
    --tags safbox-site-config-1 -e "@$vars" "$@" >"$log" 2>&1
}

run_default() { # log [ansible-playbook args]: the repository default list
  local log=$1; shift
  ansible-playbook playbooks/safbox.yml -i "${SAFBOX_HOST}," -u "$SAFBOX_USER" --private-key "$SAFBOX_KEY" \
    --tags safbox-site-config-1 "$@" >"$log" 2>&1
}

cleanup() {
  run_default "$work/cleanup.log" ${EXTRA[@]+"${EXTRA[@]}"} \
    || { echo "WARN: restoring the repository default failed:" >&2; tail -20 "$work/cleanup.log" >&2; }
  on_box "sudo rm -f $REMOTE_ZIP" || true
  rm -rf "$work"
}
EXTRA=("$@")
trap cleanup EXIT

[[ "$(on_box "cat /proc/sys/crypto/fips_enabled")" == 1 ]] || { echo "FAIL: $SAFBOX_HOST is not in FIPS mode" >&2; exit 1; }

# --- fixtures ----------------------------------------------------------------
ca() { # name digest key-algorithm-options... : a self-signed CA certificate
  local name=$1 digest=$2; shift 2
  openssl req -x509 -new "$@" -nodes -keyout "$fx/$name.key" -out "$fx/$name.pem" -days 30 "-$digest" \
    -subj "/O=SAFBox test/CN=SAFBox test $name" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
}
intermediate() { # name issuer
  local name=$1 issuer=$2
  openssl req -new -newkey rsa:3072 -nodes -keyout "$fx/$name.key" -out "$fx/$name.csr" \
    -subj "/O=SAFBox test/CN=SAFBox test $name" 2>/dev/null
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$fx/$name.ext"
  openssl x509 -req -in "$fx/$name.csr" -CA "$fx/$issuer.pem" -CAkey "$fx/$issuer.key" -CAcreateserial \
    -out "$fx/$name.pem" -days 30 -sha256 -extfile "$fx/$name.ext" 2>/dev/null
}
ca org-root sha256 -newkey rsa:3072
intermediate org-issuing org-root
cat "$fx/org-root.pem" "$fx/org-issuing.pem" >"$fx/org.pem"
ca single-root sha256 -newkey ec -pkeyopt ec_paramgen_curve:P-256
openssl x509 -in "$fx/single-root.pem" -outform DER -out "$fx/single.der"
ca archive-root sha256 -newkey rsa:4096
intermediate archive-issuing archive-root
mkdir -p "$fx/pkg"
openssl crl2pkcs7 -nocrl -certfile "$fx/archive-root.pem" -certfile "$fx/archive-issuing.pem" \
  -outform DER -out "$fx/pkg/archive.der.p7b"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z: z.write(sys.argv[2], "pkg/archive.der.p7b")' "$fx/archive.zip" "$fx/pkg/archive.der.p7b"
ca weak-root sha256 -newkey rsa:1024
ca offcurve-root sha256 -newkey ec -pkeyopt ec_paramgen_curve:brainpoolP256r1
# An OpenSSL that refuses to make SHA-1 signatures by default (the RHEL
# family's and Fedora's, through rh-allow-sha1-signatures) is allowed to for
# this one fixture.
printf 'openssl_conf = init\n[init]\nalg_section = evp\n[evp]\nrh-allow-sha1-signatures = yes\n' >"$fx/sha1.cnf"
ca sha1-root sha1 -newkey rsa:3072 || OPENSSL_CONF=$fx/sha1.cnf ca sha1-root sha1 -newkey rsa:3072 \
  || { echo "FAIL: this machine's OpenSSL cannot make the SHA-1 fixture" >&2; exit 1; }
openssl crl2pkcs7 -nocrl -outform DER -out "$fx/empty.p7b"
scp -q "${SSH_OPTS[@]}" "$fx/archive.zip" "$SAFBOX_USER@$SAFBOX_HOST:safbox-trust-test.zip"
on_box "sudo install -o root -g root -m 0644 safbox-trust-test.zip $REMOTE_ZIP && rm -f safbox-trust-test.zip"

sha() { sha256sum "$1" | cut -d' ' -f1; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f'; }
entry_org() { printf '{"name": "org", "path": "%s", "format": "pem", "sha256": "%s"}' "$fx/org.pem" "${1:-$(sha "$fx/org.pem")}"; }
entry_single() { printf '{"name": "single", "path": "%s", "format": "der", "sha256": "%s"}' "$fx/single.der" "$(sha "$fx/single.der")"; }
entry_archive() {
  printf '{"name": "archive", "url": "file://%s", "format": "pkcs7-der", "member": "pkg/archive.der.p7b", "sha256": "%s"}' \
    "$REMOTE_ZIP" "${1:-$(sha "$fx/archive.zip")}"
}
entry_pem() { printf '{"name": "%s", "path": "%s", "format": "pem", "sha256": "%s"}' "$1" "$fx/$1-root.pem" "$(sha "$fx/$1-root.pem")"; }
bundles() { # json entries... -> vars file path
  local out=$work/vars-$RANDOM.json IFS=,
  printf '{"safbox_trust_bundles": [%s]}\n' "$*" >"$out"
  echo "$out"
}

# What the box trusts: SHA-256 fingerprints of the extracted bundle, and the
# SAFBox anchor files with owner, group and mode.
trusted() {
  on_box "cat $EXTRACTED" | python3 -I -c 'import base64, hashlib, re, sys
for b in re.findall(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", sys.stdin.read(), re.S):
    print(hashlib.sha256(base64.b64decode(b)).hexdigest())'
}
anchors() { on_box "sudo find $ANCHORS -maxdepth 1 -name 'safbox-*' -printf '%f %u %g %m\n'" | sort; }
expect_trusted() { # label cert...
  local label=$1 list cert; shift
  list=$(trusted)
  for cert in "$@"; do
    if grep -qx "$(fp "$fx/$cert.pem")" <<<"$list"; then pass "$label: $cert trusted"; else fail "$label: $cert not trusted"; fi
  done
}
expect_untrusted() { # label cert...
  local label=$1 list cert; shift
  list=$(trusted)
  for cert in "$@"; do
    if grep -qx "$(fp "$fx/$cert.pem")" <<<"$list"; then fail "$label: $cert is trusted"; else pass "$label: $cert not trusted"; fi
  done
}
expect_anchor_bundles() { # label expected-count bundle...
  local label=$1 count=$2 got names; shift 2
  got=$(anchors)
  names=$(awk '{ f = $1; sub(/^safbox-/, "", f); sub(/-[0-9a-f]{16}\.pem$/, "", f); print f }' <<<"$got" | sort -u | xargs)
  if [[ "$names" == "$*" ]]; then pass "$label: anchor files belong to [$*]"; else fail "$label: anchor files belong to [$names], expected [$*]"; fi
  if [[ $(grep -c . <<<"$got") -eq "$count" ]]; then pass "$label: $count anchor files"; else fail "$label: $(grep -c . <<<"$got") anchor files, expected $count"; fi
  if [[ -z "$got" ]] || ! grep -vqE '^safbox-[a-z0-9-]+-[0-9a-f]{16}\.pem root root 644$' <<<"$got"; then
    pass "$label: anchor files are safbox-<bundle>-<id>.pem, root:root 0644"
  else
    fail "$label: anchor files not safbox-<bundle>-<id>.pem, root:root 0644:"$'\n'"$got"
  fi
}
expect_run() { # label ok|fail vars-file [pattern that the output must contain]
  local label=$1 want=$2 vars=$3 pattern=${4:-} log=$work/run-$RANDOM.log rc=0
  run_role "$vars" "$log" ${EXTRA[@]+"${EXTRA[@]}"} || rc=$?
  LAST_LOG=$log
  if [[ "$want" == ok && $rc -ne 0 ]]; then fail "$label: the run failed (rc $rc):"; tail -30 "$log" >&2; return; fi
  if [[ "$want" == fail && $rc -eq 0 ]]; then fail "$label: the run succeeded but must fail"; return; fi
  pass "$label: the run $([[ $want == ok ]] && echo succeeded || echo failed) as it must"
  if [[ -n "$pattern" ]]; then
    if grep -qE "$pattern" "$log"; then pass "$label: output names /$pattern/"; else fail "$label: output lacks /$pattern/:"; tail -30 "$log" >&2; fi
  fi
}
# A malformed list: the run fails with the entry check's message, before the
# role downloads or copies anything.
expect_refused() { # label vars-file pattern
  expect_run "$1" fail "$2" "$3"
  if grep -qE 'TASK \[site_config : (Download|Copy) each bundle' "$LAST_LOG"; then
    fail "$1: the role went on to fetch a bundle"
  else
    pass "$1: refused before any bundle was fetched"
  fi
}
expect_unchanged() { # label
  local recap
  recap=$(sed -n '/^PLAY RECAP/,$p' "$LAST_LOG" | grep -E 'ok=[0-9]+')
  if grep -qE 'changed=0 ' <<<"$recap"; then pass "$1: changed=0"; else fail "$1: $recap"; fi
}

GOOD=("$(entry_org)" "$(entry_single)" "$(entry_archive)")
GOOD_CERTS=(org-root org-issuing single-root archive-root archive-issuing)

echo "== 0. the repository default trusts the DoD bundle"
read -r -a PY <<<"$(head -1 "$(command -v ansible-playbook)" | sed 's/^#!//')"
mapfile -t DOD_ROOTS < <("${PY[@]}" -c 'import sys, yaml
inputs = {i["name"]: i.get("value") for i in yaml.safe_load(open(sys.argv[1]))["inputs"]}
for label, fp in inputs["trust_bundle_anchors"]["dod"].items():
    print(fp.replace(":", "").lower(), label)' "$ROOT/verify/el10-infrastructure/inspec.yml")
rc=0
run_default "$work/default.log" ${EXTRA[@]+"${EXTRA[@]}"} || rc=$?
LAST_LOG=$work/default.log
if [[ $rc -eq 0 ]]; then pass "default: the run succeeded"; else fail "default: the run failed (rc $rc)"; tail -30 "$LAST_LOG" >&2; fi
names=$(anchors | awk '{ f = $1; sub(/^safbox-/, "", f); sub(/-[0-9a-f]{16}\.pem$/, "", f); print f }' | sort -u | xargs)
if [[ "$names" == dod ]]; then pass "default: anchor files belong to [dod]"; else fail "default: anchor files belong to [$names], expected [dod]"; fi
list=$(trusted)
[[ ${#DOD_ROOTS[@]} -gt 0 ]] || fail "default: no dod roots in trust_bundle_anchors"
for root in "${DOD_ROOTS[@]}"; do
  if grep -qx "${root%% *}" <<<"$list"; then pass "default: ${root#* } trusted"; else fail "default: ${root#* } not trusted"; fi
done

echo "== 1. install three bundles (PEM path, DER path, PKCS#7 in a zip by URL)"
expect_run install ok "$(bundles "${GOOD[@]}")"
expect_anchor_bundles install 5 archive org single
expect_trusted install "${GOOD_CERTS[@]}"

echo "== 2. the same list again"
expect_run "second run" ok "$(bundles "${GOOD[@]}")"
expect_unchanged "second run"

echo "== 3. a wrong sha256 trusts nothing new"
bad=$(printf '0%.0s' {1..64})
expect_run "wrong sha256 by URL" fail "$(bundles "$(entry_org)" "$(entry_single)" "$(entry_archive "$bad")")" \
  'The checksum for .* did not match 0{64}; it was [0-9a-f]{64}'
expect_run "wrong sha256 by path" fail "$(bundles "$(entry_org "$bad")" "$(entry_single)" "$(entry_archive)")" \
  'Trust bundle org: the sha256 of .* does not match the configured 0{64}'
expect_anchor_bundles "after wrong sha256" 5 archive org single

echo "== 4. roots the crypto policy rejects are reported and not trusted"
for bad_root in sha1 weak offcurve; do
  expect_run "$bad_root root" fail "$(bundles "${GOOD[@]}" "$(entry_pem "$bad_root")")" \
    "rejected by the system crypto policy.*SAFBox test $bad_root-root"
  expect_untrusted "$bad_root root" "$bad_root-root"
done
expect_anchor_bundles "after rejected roots" 5 archive org single

echo "== 5. malformed entries are refused before anything is fetched"
org_sha=$(sha "$fx/org.pem")
zip_sha=$(sha "$fx/archive.zip")
malformed() { # label json-entry
  expect_refused "$1" "$(bundles "$2")" "Trust bundle entry bad is malformed"
}
malformed "unknown format" \
  "$(printf '{"name": "bad", "url": "file:///var/tmp/safbox-trust-absent.zip", "format": "p12", "sha256": "%s"}' "$zip_sha")"
malformed "url and path" \
  "$(printf '{"name": "bad", "url": "file://%s", "path": "%s", "format": "pem", "sha256": "%s"}' "$REMOTE_ZIP" "$fx/org.pem" "$org_sha")"
malformed "neither url nor path" "$(printf '{"name": "bad", "format": "pem", "sha256": "%s"}' "$org_sha")"
malformed "relative path" "$(printf '{"name": "bad", "path": "org.pem", "format": "pem", "sha256": "%s"}' "$org_sha")"
malformed "member with .." \
  "$(printf '{"name": "bad", "url": "file://%s", "member": "pkg/../../etc/passwd", "format": "pkcs7-der", "sha256": "%s"}' "$REMOTE_ZIP" "$zip_sha")"
malformed "absolute member" \
  "$(printf '{"name": "bad", "url": "file://%s", "member": "/pkg/archive.der.p7b", "format": "pkcs7-der", "sha256": "%s"}' "$REMOTE_ZIP" "$zip_sha")"
malformed "unknown key" \
  "$(printf '{"name": "bad", "path": "%s", "format": "pem", "sha256": "%s", "trust": "all"}' "$fx/org.pem" "$org_sha")"
expect_refused "two bundles with one name" "$(bundles "$(entry_org)" "$(entry_org)")" "Trust bundle names must be unique"
expect_run "bundle with no certificate" fail \
  "$(bundles "$(printf '{"name": "empty", "path": "%s", "format": "pkcs7-der", "sha256": "%s"}' "$fx/empty.p7b" "$(sha "$fx/empty.p7b")")")" \
  'Trust bundle empty holds no certificate in format pkcs7-der'
expect_anchor_bundles "after refused entries" 5 archive org single

echo "== 6. removal"
expect_run "keep one bundle" ok "$(bundles "$(entry_single)")"
expect_anchor_bundles "keep one bundle" 1 single
expect_trusted "keep one bundle" single-root
expect_untrusted "keep one bundle" org-root org-issuing archive-root archive-issuing
expect_run "empty list" ok "$(bundles)"
expect_anchor_bundles "empty list" 0
expect_untrusted "empty list" "${GOOD_CERTS[@]}"
list=$(trusted)
for root in "${DOD_ROOTS[@]}"; do
  if grep -qx "${root%% *}" <<<"$list"; then fail "empty list: ${root#* } is trusted"; else pass "empty list: ${root#* } not trusted"; fi
done
expect_run "empty list again" ok "$(bundles)"
expect_unchanged "empty list again"

if [[ $fails -ne 0 ]]; then
  echo "FAIL: $fails trust bundle check(s) failed" >&2
  exit 1
fi
echo "PASS: site CA bundles install, stay unchanged on a second run, refuse bad checksums and policy-rejected roots, and remove cleanly"
