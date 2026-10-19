#!/usr/bin/env bash
# Heimdall on a deployed SAFBox, through the TLS proxy: log in and
# upload an HDF file via the API.
#
#   HEIMDALL_ADMIN_PASSWORD=... tests/services/heimdall-upload.sh <box-address> [name]
#
# name is Heimdall's name on the box (default heimdall.safbox.internal);
# requests for it go to box-address. Heimdall's only local account is its
# administrator, admin@<domain> (the domain is the name without
# "heimdall."), whose password first boot generates: read it on the box
# with sudo grep '^ADMIN_PASSWORD=' /etc/safbox/heimdall.env and pass it in
# HEIMDALL_ADMIN_PASSWORD.
#
# From this machine over HTTPS only, as a browser would: the proxy's TLS
# (protocol, refused legacy protocols and ChaCha20), the UI page and its
# scripts and stylesheets, the API (registration refused, the administrator
# logs in, uploads an HDF file and reads the evaluation back), and that
# Heimdall's own port and its database are not reachable from outside.
# Creates an evaluation on the box: run it against a clone. The HDF
# uploaded is SAFBOX_HDF, for example a results file scripts/validate.sh
# wrote in .build/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/services/lib.sh
source "$ROOT/tests/services/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "SKIP: usage: HEIMDALL_ADMIN_PASSWORD=... $0 <box-address> [name]" >&2
  exit 2
fi
HOST=$1
NAME=${2:-heimdall.safbox.internal}
ADMIN_EMAIL="admin@${NAME#heimdall.}"
ADMIN_PASSWORD=${HEIMDALL_ADMIN_PASSWORD:?set HEIMDALL_ADMIN_PASSWORD to the Heimdall administrator password on the box}
HDF=${SAFBOX_HDF:?set SAFBOX_HDF to an HDF results file, such as one scripts/validate.sh wrote in .build/}
[[ -r "$HDF" ]] || die "HDF file $HDF not readable"
require_tools
BASE="https://$NAME"

tls_checks "$HOST" "$NAME"
page_and_assets "$BASE/"

code=$(https -o "$WORK/server.json" -w '%{http_code}' "$BASE/server") || code=000
if [[ "$code" == 200 ]] && jq -e '.registrationEnabled == false and .localLoginEnabled == true' "$WORK/server.json" >/dev/null; then
  pass "GET /server: local login enabled, registration disabled"
else
  fail "GET /server -> $code $(head -c 200 "$WORK/server.json" 2>/dev/null)"
fi

password=$(random_password)
jq -n --arg e "$(random_email)" --arg p "$password" \
  '{email: $e, password: $p, passwordConfirmation: $p, firstName: "SAFBox", lastName: "Test", role: "user", creationMethod: "local"}' \
  > "$WORK/user.json"
code=$(https -o "$WORK/register.out" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary @"$WORK/user.json" "$BASE/users") || code=000
if [[ "$code" == 4* ]]; then pass "registration refused -> $code"; else fail "registration -> $code (expected refused) $(head -c 300 "$WORK/register.out")"; fi

# The administrator's first session lasts ten minutes and Heimdall's UI
# asks for a new password; the API serves it meanwhile.
jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email: $e, password: $p}' > "$WORK/login.json"
code=$(https -o "$WORK/login.out" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary @"$WORK/login.json" "$BASE/authn/login") || code=000
token=$(jq -r '.accessToken // empty' "$WORK/login.out" 2>/dev/null || true)
if [[ "$code" == 201 && -n "$token" ]]; then pass "log in as $ADMIN_EMAIL -> 201 with an access token"; else fail "log in as $ADMIN_EMAIL -> $code"; fi
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
finish "Heimdall on $BASE: TLS, UI assets, registration refused, administrator log in and HDF upload"
