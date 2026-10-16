#!/usr/bin/env bash
# The landing page of a deployed SAFBox and both applications behind the TLS
# proxy (ADR-0001 Phase 8: an HTTPS landing page on 443 with service status
# and links; Heimdall and Vulcan reachable behind TLS on their ports).
#
#   tests/services/landing.sh <host> [application...]
#
# From this machine over HTTPS only, as a browser would: the proxy's TLS on
# 443 (protocol, refused legacy protocols and ChaCha20), the page and its
# stylesheet, the security headers, one row per application with its
# status Running and a link to it on the host this test asked for, every
# link followed to the application's page, and no plain HTTP or loopback
# port reachable from outside. The applications default to heimdall and
# vulcan; name the ones a reduced build ships (tests/services/landing.sh
# <host> heimdall). Creates nothing on the box.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/services/lib.sh
source "$ROOT/tests/services/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "SKIP: usage: $0 <host> [application...]" >&2
  exit 2
fi
HOST=$1
shift
APPS=("$@")
if [[ ${#APPS[@]} -eq 0 ]]; then APPS=(heimdall vulcan); fi
require_tools
BASE="https://$HOST"

# app_info APP: the application's label, HTTPS port and the page its link
# must lead to (the repository defaults, ansible/group_vars/all/main.yml).
app_info() {
  case "$1" in
    heimdall) label=Heimdall port=8443 page=/ ;;
    vulcan) label=Vulcan port=9443 page=/users/sign_in ;;
    *) die "unknown application $1 (heimdall or vulcan)" ;;
  esac
}
label="" port="" page=""

tls_checks "$HOST" 443
page_and_assets "$BASE/"
cp "$WORK/page.html" "$WORK/landing.html"

code=$(https -D "$WORK/headers" -o /dev/null -w '%{http_code}' "$BASE/") || code=000
want_headers=(
  "content-security-policy: default-src 'none'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  "x-content-type-options: nosniff"
  "x-frame-options: deny"
  "referrer-policy: no-referrer"
  "cache-control: no-store"
)
for header in "${want_headers[@]}"; do
  if tr -d '\r' < "$WORK/headers" | tr '[:upper:]' '[:lower:]' | grep -qxF "$header"; then
    pass "header $header"
  else
    fail "GET / -> $code without header '$header'"
  fi
done
if tr -d '\r' < "$WORK/headers" | grep -qi '^strict-transport-security:'; then
  fail "the page sends Strict-Transport-Security, which locks browsers out of a self-signed certificate"
else
  pass "no Strict-Transport-Security on a self-signed certificate"
fi

# row_of NAME: the page's table row for one service, on one line.
row_of() {
  tr -d '\n' < "$WORK/landing.html" | grep -oE "<tr id=\"service-$1\">([^<]|<[^/]|</[^t]|</t[^r])*</tr>" || true
}
for app in "${APPS[@]}"; do
  app_info "$app"
  row=$(row_of "$app")
  url="https://$HOST:$port/"
  if grep -qF "<th scope=\"row\">$label</th>" <<<"$row" && grep -qF '<span class="state state-running">Running</span>' <<<"$row"; then
    pass "$label is listed as Running"
  else
    fail "$label row: ${row:-missing}"
  fi
  if grep -qF "href=\"$url\"" <<<"$row"; then
    pass "$label links to $url"
  else
    fail "$label does not link to $url"
  fi
  code=$(https -o /dev/null -w '%{http_code}' "${url%/}$page") || code=000
  if [[ "$code" == 200 ]]; then pass "GET ${url%/}$page -> 200"; else fail "GET ${url%/}$page -> $code"; fi
done
for app in heimdall vulcan; do
  if [[ " ${APPS[*]} " != *" $app "* ]] && [[ -n "$(row_of "$app")" ]]; then
    app_info "$app"
    fail "$label is listed but this build should not ship it"
  fi
done
row=$(row_of proxy)
if grep -qF '<span class="state state-running">Running</span>' <<<"$row"; then
  pass "the TLS proxy and landing page are listed as Running"
else
  fail "proxy row: ${row:-missing}"
fi

code=$(https -o /dev/null -w '%{http_code}' "$BASE/status/proxy") || code=000
if [[ "$code" == 404 ]]; then pass "the status files are not served on their own"; else fail "GET /status/proxy -> $code"; fi

not_reachable "$HOST" 80 3000 3001 5432
finish "landing page on $BASE lists and links ${APPS[*]}, each reachable behind TLS"
