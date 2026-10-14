#!/usr/bin/env bash
# Heimdall on a deployed SAFBox, through the TLS proxy (ADR-0001 Phase 5
# verification: register, log in, upload an HDF file via the API).
#
#   tests/services/heimdall-upload.sh <host> [https-port]
#
# From this machine over HTTPS only, as a browser would: the proxy's TLS
# (protocol, refused legacy protocols and ChaCha20), the UI page and its
# scripts and stylesheets, the API (register a user, log in, upload an HDF
# file, read the evaluation back), and that Heimdall's own port and its
# database are not reachable from outside. Creates an account and an
# evaluation on the box: run it against a clone. The HDF uploaded is
# SAFBOX_HDF, by default a recorded scan of a SAFBox clone from this
# repository's fixtures.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/services/lib.sh
source "$ROOT/tests/services/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "SKIP: usage: $0 <host> [https-port]" >&2
  exit 2
fi
HOST=$1
PORT=${2:-8443}
HDF=${SAFBOX_HDF:-$ROOT/tests/verify/fixtures/release-infrastructure.json}
[[ -r "$HDF" ]] || die "HDF file $HDF not readable"
require_tools
BASE="https://$HOST:$PORT"

tls_checks "$HOST" "$PORT"
page_and_assets "$BASE/"

code=$(https -o "$WORK/server.json" -w '%{http_code}' "$BASE/server") || code=000
if [[ "$code" == 200 ]] && jq -e '.registrationEnabled == true and .localLoginEnabled == true' "$WORK/server.json" >/dev/null; then
  pass "GET /server: local login and registration enabled"
else
  fail "GET /server -> $code $(head -c 200 "$WORK/server.json" 2>/dev/null)"
fi

email=$(random_email)
password=$(random_password)
jq -n --arg e "$email" --arg p "$password" \
  '{email: $e, password: $p, passwordConfirmation: $p, firstName: "SAFBox", lastName: "Test", role: "user", creationMethod: "local"}' \
  > "$WORK/user.json"
code=$(https -o "$WORK/register.out" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary @"$WORK/user.json" "$BASE/users") || code=000
if [[ "$code" == 201 ]]; then pass "register $email -> 201"; else fail "register -> $code $(head -c 300 "$WORK/register.out")"; fi

jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}' > "$WORK/login.json"
code=$(https -o "$WORK/login.out" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary @"$WORK/login.json" "$BASE/authn/login") || code=000
token=$(jq -r '.accessToken // empty' "$WORK/login.out" 2>/dev/null || true)
if [[ "$code" == 201 && -n "$token" ]]; then pass "log in -> 201 with an access token"; else fail "log in -> $code"; fi
printf 'Authorization: Bearer %s\n' "$token" > "$WORK/auth.header"

filename="safbox-test-$(basename "$HDF")"
code=$(https -o "$WORK/upload.out" -w '%{http_code}' -H @"$WORK/auth.header" \
  -F "data=@$HDF" -F "filename=$filename" -F public=false "$BASE/evaluations") || code=000
id=$(jq -r '.id // empty' "$WORK/upload.out" 2>/dev/null || true)
if [[ "$code" == 201 && -n "$id" ]]; then
  pass "upload $(basename "$HDF") ($(wc -c <"$HDF" | tr -d ' ') bytes) -> 201, evaluation $id"
else
  fail "upload -> $code $(head -c 300 "$WORK/upload.out")"
fi

code=$(https -o "$WORK/evaluation.json" -w '%{http_code}' -H @"$WORK/auth.header" "$BASE/evaluations/$id") || code=000
if [[ "$code" == 200 ]] && jq -e --arg f "$filename" '.filename == $f and (.data.profiles | length) > 0' "$WORK/evaluation.json" >/dev/null; then
  pass "read evaluation $id back with $(jq '.data.profiles | length' "$WORK/evaluation.json") profile(s)"
else
  fail "GET /evaluations/$id -> $code"
fi

not_reachable "$HOST" 3000 5432
finish "Heimdall on $BASE: TLS, UI assets, register, log in and HDF upload"
