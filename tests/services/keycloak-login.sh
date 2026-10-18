#!/usr/bin/env bash
# Keycloak single sign-on on a deployed SAFBox, through the TLS proxy:
# safuser signs in to Heimdall and to Vulcan through Keycloak.
#
#   KEYCLOAK_SAFUSER_PASSWORD=... tests/services/keycloak-login.sh <box-address> [domain]
#
# domain is the box's safbox_domain (default safbox.internal); requests for
# keycloak.<domain>, heimdall.<domain> and vulcan.<domain> go to
# box-address. safuser's Keycloak password is its own, generated at first
# boot: read it on the box with
# sudo grep '^SAFUSER_PASSWORD=' /etc/safbox/keycloak.env and pass it in
# KEYCLOAK_SAFUSER_PASSWORD.
#
# From this machine over HTTPS only, as a browser would: Keycloak's TLS and
# its discovery document, its administration paths refused to a client
# other than the box, then each application's OIDC sign-in followed to
# Keycloak's form, the credentials posted, and the redirects followed back
# to the application, which must name safuser@<domain> as a regular user
# (not an administrator). Last, a wrong password must leave the browser on
# Keycloak's form: Keycloak's brute-force protection locks an account for a
# minute after quick failures, so it runs once and after the sign-ins.
# Signs safuser in to both applications, which creates its account in each
# on the first run: run it against a clone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/services/lib.sh
source "$ROOT/tests/services/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "SKIP: usage: KEYCLOAK_SAFUSER_PASSWORD=... $0 <box-address> [domain]" >&2
  exit 2
fi
HOST=$1
DOMAIN=${2:-safbox.internal}
PASSWORD=${KEYCLOAK_SAFUSER_PASSWORD:?set KEYCLOAK_SAFUSER_PASSWORD to the Keycloak password of safuser on the box}
USER_EMAIL="safuser@$DOMAIN"
require_tools
KEYCLOAK="https://keycloak.$DOMAIN"
HEIMDALL="https://heimdall.$DOMAIN"
VULCAN="https://vulcan.$DOMAIN"

tls_checks "$HOST" "keycloak.$DOMAIN"

# One certificate names every name (first boot), so the one tls_checks saved
# verifies all three; each name goes to the box's address.
JAR=$WORK/cookies
web() {
  curl -sS --cacert "$WORK/cert.pem" -b "$JAR" -c "$JAR" \
    --resolve "keycloak.$DOMAIN:443:$HOST" --resolve "heimdall.$DOMAIN:443:$HOST" \
    --resolve "vulcan.$DOMAIN:443:$HOST" "$@"
}

code=$(web -o "$WORK/discovery.json" -w '%{http_code}' "$KEYCLOAK/realms/safbox/.well-known/openid-configuration") || code=000
if [[ "$code" == 200 ]] && jq -e --arg i "$KEYCLOAK/realms/safbox" '.issuer == $i' "$WORK/discovery.json" >/dev/null; then
  pass "discovery document names issuer $KEYCLOAK/realms/safbox"
else
  fail "discovery document -> $code $(head -c 200 "$WORK/discovery.json" 2>/dev/null)"
fi
for path in /admin/ /realms/master/.well-known/openid-configuration; do
  code=$(web -o /dev/null -w '%{http_code}' "$KEYCLOAK$path") || code=000
  if [[ "$code" == 403 ]]; then pass "GET $path from here -> 403"; else fail "GET $path from here -> $code (expected 403)"; fi
done

# sso APP SECRET-FILE: start APP's OIDC sign-in in a fresh session, post
# the credentials in SECRET-FILE to Keycloak's form, and follow the
# redirects back. Leaves the last page in $WORK/final.html and its URL in
# $WORK/final.url.
sso() {
  local app=$1 secret=$2 token action
  rm -f "$JAR"
  case "$app" in
    heimdall)
      web -L -o "$WORK/form.html" "$HEIMDALL/authn/oidc" || true ;;
    vulcan)
      web -o "$WORK/signin.html" "$VULCAN/users/sign_in" || true
      token=$(grep -oE '<meta name="csrf-token" content="[^"]+"' "$WORK/signin.html" | sed -E 's/.*content="([^"]+)".*/\1/' || true)
      web -L -o "$WORK/form.html" --data-urlencode "authenticity_token=$token" "$VULCAN/users/auth/oidc" || true ;;
  esac
  action=$(tr '\n' ' ' < "$WORK/form.html" | grep -oE '<form[^>]*kc-form-login[^>]*>' | grep -oE 'action="[^"]*"' \
    | sed -E 's/^action="//; s/"$//; s/&amp;/\&/g' || true)
  if [[ -z "$action" ]]; then
    printf '%s\n' none > "$WORK/final.url"
    return
  fi
  web -L -o "$WORK/final.html" -w '%{url_effective}' --data-urlencode "username=safuser" \
    --data-urlencode "password@$secret" --data-urlencode credentialId= "$action" > "$WORK/final.url" || true
}

printf '%s' "$PASSWORD" > "$WORK/password"
sso heimdall "$WORK/password"
id=$(awk '$6 == "userID" { print $7 }' "$JAR" 2>/dev/null || true)
tok=$(awk '$6 == "accessToken" { print $7 }' "$JAR" 2>/dev/null || true)
if [[ -n "$id" && -n "$tok" ]] && web -H "Authorization: Bearer $tok" -o "$WORK/who.json" "$HEIMDALL/users/$id" \
   && jq -e --arg e "$USER_EMAIL" '.email == $e and .role == "user"' "$WORK/who.json" >/dev/null; then
  pass "Heimdall: signed in through Keycloak as $USER_EMAIL, role user"
else
  fail "Heimdall: no sign-in as $USER_EMAIL, regular user (ended at $(cat "$WORK/final.url"); $(head -c 200 "$WORK/who.json" 2>/dev/null))"
fi

sso vulcan "$WORK/password"
code=$(web -o "$WORK/me.json" -w '%{http_code}' -H 'Accept: application/json' "$VULCAN/users/edit.json") || code=000
if [[ "$code" == 200 ]] && jq -e --arg e "$USER_EMAIL" '.email == $e and .admin == false' "$WORK/me.json" >/dev/null; then
  pass "Vulcan: signed in through Keycloak as $USER_EMAIL, not admin"
else
  fail "Vulcan: no sign-in as $USER_EMAIL, non-admin (ended at $(cat "$WORK/final.url"); $code $(head -c 200 "$WORK/me.json" 2>/dev/null))"
fi

random_password > "$WORK/wrong"
sso heimdall "$WORK/wrong"
if [[ "$(cat "$WORK/final.url")" == "$KEYCLOAK/"* ]] && ! awk '$6 == "accessToken"' "$JAR" | grep -q .; then
  pass "a wrong password stays on Keycloak's form"
else
  fail "a wrong password ended at $(cat "$WORK/final.url")"
fi

not_reachable "$HOST" 3002
finish "Keycloak on $KEYCLOAK: TLS, discovery, admin paths refused from here, safuser signs in to Heimdall and Vulcan, wrong password refused"
