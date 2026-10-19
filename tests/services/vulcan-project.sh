#!/usr/bin/env bash
# Vulcan on a deployed SAFBox, through the TLS proxy: the
# administrator signs in and creates a project.
#
#   VULCAN_ADMIN_PASSWORD=... tests/services/vulcan-project.sh <box-address> [name]
#
# name is Vulcan's name on the box (default vulcan.safbox.internal);
# requests for it go to box-address. Vulcan's only local account is its
# administrator, admin@<domain> (the domain is the name without
# "vulcan."), whose password first boot generates: read it on the box with
# sudo grep '^VULCAN_ADMIN_PASSWORD=' /etc/safbox/vulcan.env and pass it in
# VULCAN_ADMIN_PASSWORD.
#
# From this machine over HTTPS only, as a browser would: the proxy's TLS
# (protocol, refused legacy protocols and ChaCha20), the sign-in page and
# its scripts and stylesheets, what a sign-up does (reported only: Vulcan
# 2.4.1 accepts one with registration off, a known upstream defect), the
# administrator signing in through the sign-in form (with its CSRF token
# and session cookie) as admin, creating a project, and that Vulcan's own
# port and its database are not reachable from outside. Creates a project:
# run it against a clone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/services/lib.sh
source "$ROOT/tests/services/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "SKIP: usage: VULCAN_ADMIN_PASSWORD=... $0 <box-address> [name]" >&2
  exit 2
fi
HOST=$1
NAME=${2:-vulcan.safbox.internal}
ADMIN_EMAIL="admin@${NAME#vulcan.}"
ADMIN_PASSWORD=${VULCAN_ADMIN_PASSWORD:?set VULCAN_ADMIN_PASSWORD to the Vulcan administrator password on the box}
require_tools
BASE="https://$NAME"
JAR=$WORK/cookies

# The CSRF token Rails puts in every page's <meta name="csrf-token">.
csrf_of() { grep -oE '<meta name="csrf-token" content="[^"]+"' "$1" | sed -E 's/.*content="([^"]+)".*/\1/'; }

tls_checks "$HOST" "$NAME"
page_and_assets "$BASE/users/sign_in"
token=$(csrf_of "$WORK/page.html" || true)

# Registration is off (VULCAN_ENABLE_USER_REGISTRATION=false), but Vulcan
# 2.4.1 only hides the sign-up link: its registrations controller checks
# local login alone, so a sign-up posted as the browser would (the CSRF
# token of a page fetched in the same session) still makes a regular
# account and signs it in. That is a known upstream defect, accepted and
# left visible: the result is reported, not counted as a failure. Vulcan
# serves its sign-in page at /users/sign_up, so that page alone proves
# nothing; the session after the post shows whether an account was made.
https -c "$JAR" -b "$JAR" -o "$WORK/signup.html" "$BASE/users/sign_up" || true
token=$(csrf_of "$WORK/signup.html" || true)
password=$(random_password)
email=$(random_email)
code=$(https -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code} %{redirect_url}' \
  --data-urlencode "authenticity_token=$token" --data-urlencode 'user[name]=SAFBox Test' \
  --data-urlencode "user[email]=$email" --data-urlencode "user[password]=$password" \
  --data-urlencode "user[password_confirmation]=$password" "$BASE/users") || code=000
me=$(https -c "$JAR" -b "$JAR" -o "$WORK/signup-me.json" -w '%{http_code}' -H 'Accept: application/json' "$BASE/users/edit.json") || me=000
if [[ "$me" == 200 ]] && jq -e --arg e "$email" '.email == $e' "$WORK/signup-me.json" >/dev/null 2>&1; then
  echo "note - KNOWN UPSTREAM DEFECT: Vulcan 2.4.1 accepts POST /users with registration disabled" \
    "-> $code, signed in as the new regular account $email (not counted as a failure)"
else
  echo "note - registration not accepted -> $code, no session for $email" \
    "(the known Vulcan 2.4.1 defect did not show: check whether the image changed)"
fi
# A fresh session for the administrator's sign-in below.
rm -f "$JAR"

https -c "$JAR" -b "$JAR" -o "$WORK/signin.html" "$BASE/users/sign_in" || true
token=$(csrf_of "$WORK/signin.html" || true)
code=$(https -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code} %{redirect_url}' \
  --data-urlencode "authenticity_token=$token" --data-urlencode "user[email]=$ADMIN_EMAIL" \
  --data-urlencode "user[password]=$ADMIN_PASSWORD" "$BASE/users/sign_in") || code=000
# Devise redirects to the root after a successful sign-in.
if [[ "$code" == "302 $BASE/" ]]; then pass "sign in as $ADMIN_EMAIL -> 302 to $BASE/"; else fail "sign in as $ADMIN_EMAIL -> $code"; fi

code=$(https -c "$JAR" -b "$JAR" -o "$WORK/me.json" -w '%{http_code}' -H 'Accept: application/json' "$BASE/users/edit.json") || code=000
if [[ "$code" == 200 ]] && jq -e --arg e "$ADMIN_EMAIL" '.email == $e and .admin == true' "$WORK/me.json" >/dev/null; then
  pass "signed in as $ADMIN_EMAIL, admin"
else
  fail "current user is not $ADMIN_EMAIL as admin ($code $(head -c 200 "$WORK/me.json"))"
fi
code=$(https -c "$JAR" -b "$JAR" -o "$WORK/users.json" -w '%{http_code}' -H 'Accept: application/json' "$BASE/users.json") || code=000
if [[ "$code" == 200 ]]; then pass "admin-only user list -> 200"; else fail "admin-only user list -> $code"; fi

https -c "$JAR" -b "$JAR" -o "$WORK/projects.html" "$BASE/projects" || true
token=$(csrf_of "$WORK/projects.html" || true)
name="SAFBox test $(date -u +%Y%m%dT%H%M%SZ)"
jq -n --arg n "$name" '{project: {name: $n, description: "Created by tests/services/vulcan-project.sh", visibility: "discoverable"}}' \
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
finish "Vulcan on $BASE: TLS, UI assets, sign-up reported, administrator signed in, project created"
