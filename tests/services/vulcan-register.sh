#!/usr/bin/env bash
# Vulcan on a deployed SAFBox, through the TLS proxy (ADR-0001 Phase 6
# verification: register the first user, confirm admin, create a project).
#
#   tests/services/vulcan-register.sh <host> [https-port]
#
# From this machine over HTTPS only, as a browser would: the proxy's TLS
# (protocol, refused legacy protocols and ChaCha20), the sign-in page and
# its scripts and stylesheets, registration of the first user through the
# sign-up form (with its CSRF token and session cookie), that user being
# admin, creating a project, and that Vulcan's own port and its database are
# not reachable from outside. Needs a Vulcan with no users yet: the first
# registered user is the one made admin. Creates an account and a project:
# run it against a fresh clone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/services/lib.sh
source "$ROOT/tests/services/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "SKIP: usage: $0 <host> [https-port]" >&2
  exit 2
fi
HOST=$1
PORT=${2:-9443}
require_tools
BASE="https://$HOST:$PORT"
JAR=$WORK/cookies

# The CSRF token Rails puts in every page's <meta name="csrf-token">.
csrf_of() { grep -oE '<meta name="csrf-token" content="[^"]+"' "$1" | sed -E 's/.*content="([^"]+)".*/\1/'; }

tls_checks "$HOST" "$PORT"
page_and_assets "$BASE/users/sign_in"

code=$(https -c "$JAR" -b "$JAR" -o "$WORK/signup.html" -w '%{http_code}' "$BASE/users/sign_up") || code=000
token=$(csrf_of "$WORK/signup.html" || true)
if [[ "$code" == 200 && -n "$token" ]]; then pass "GET /users/sign_up -> 200 with a CSRF token"; else fail "GET /users/sign_up -> $code"; fi

email=$(random_email)
password=$(random_password)
code=$(https -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code} %{redirect_url}' \
  --data-urlencode "authenticity_token=$token" --data-urlencode 'user[name]=SAFBox Test' \
  --data-urlencode "user[email]=$email" --data-urlencode "user[password]=$password" \
  --data-urlencode "user[password_confirmation]=$password" "$BASE/users") || code=000
# Devise redirects to the root after a successful sign-up and signs the user in.
if [[ "$code" == "302 $BASE/" ]]; then pass "register $email -> 302 to $BASE/"; else fail "register -> $code"; fi

code=$(https -c "$JAR" -b "$JAR" -o "$WORK/me.json" -w '%{http_code}' -H 'Accept: application/json' "$BASE/users/edit.json") || code=000
if [[ "$code" == 200 ]] && jq -e --arg e "$email" '.email == $e and .admin == true' "$WORK/me.json" >/dev/null; then
  pass "signed in as $email, admin (first registered user)"
else
  fail "current user is not $email as admin ($code $(head -c 200 "$WORK/me.json")); Vulcan must have no users before this test"
fi
code=$(https -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code}' -H 'Accept: application/json' "$BASE/users.json") || code=000
if [[ "$code" == 200 ]]; then pass "admin-only user list -> 200"; else fail "admin-only user list -> $code"; fi

https -c "$JAR" -b "$JAR" -o "$WORK/projects.html" "$BASE/projects" || true
token=$(csrf_of "$WORK/projects.html" || true)
name="SAFBox test $(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg n "$name" '{project: {name: $n, description: "Created by tests/services/vulcan-register.sh", visibility: "discoverable"}}' \
  > "$WORK/project.json"
code=$(https -c "$JAR" -b "$JAR" -o "$WORK/create.out" -w '%{http_code}' -H 'Accept: application/json' \
  -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" --data-binary @"$WORK/project.json" "$BASE/projects") || code=000
if [[ "$code" == 200 ]] && jq -e '.redirect_url | test("^/projects/[0-9]+$")' "$WORK/create.out" >/dev/null; then
  pass "create project '$name' -> $(jq -r .redirect_url "$WORK/create.out")"
else
  fail "create project -> $code $(head -c 300 "$WORK/create.out")"
fi
code=$(https -c "$JAR" -b "$JAR" -o "$WORK/projects.json" -w '%{http_code}' -H 'Accept: application/json' "$BASE/projects.json") || code=000
if [[ "$code" == 200 ]] && jq -e --arg n "$name" 'map(select(.name == $n)) | length == 1' "$WORK/projects.json" >/dev/null; then
  pass "project listed in /projects.json"
else
  fail "project not listed ($code)"
fi

not_reachable "$HOST" 3001 5432
finish "Vulcan on $BASE: TLS, UI assets, first user registered as admin, project created"
