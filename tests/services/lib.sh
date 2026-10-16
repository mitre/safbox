# shellcheck shell=bash
# Helpers for the service tests in tests/services/. Source, do not execute.
#
# The service tests are clients of a deployed SAFBox over HTTPS, the way a
# browser is: they run on this machine and reach the box only through the
# TLS proxy's ports, never over SSH (checks that need a shell on the box
# are InSpec controls in verify/profiles/safbox). Each test creates
# accounts and data on the box it runs against, so point them at a clone,
# never at an appliance in use.
#
# Needs curl, jq, and OpenSSL 3 (not LibreSSL) as `openssl` or $OPENSSL.

SERVICES_OPENSSL=${OPENSSL:-openssl}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*"; fails=$((fails + 1)); }
die() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }

require_tools() {
  local tool
  for tool in curl jq "$SERVICES_OPENSSL"; do
    command -v "$tool" >/dev/null || die "$tool not installed"
  done
  "$SERVICES_OPENSSL" version | grep -q '^OpenSSL 3' \
    || die "$SERVICES_OPENSSL is $("$SERVICES_OPENSSL" version); set OPENSSL to an OpenSSL 3 binary"
}

# A random 24-character password meeting both applications' default
# complexity rules: at least 15 characters, two each of upper case, lower
# case, digits and symbols (Vulcan), and never four characters of one class
# in a row (Heimdall). Characters cycle through the four classes, each drawn
# from openssl rand.
random_password() {
  local classes=(ABCDEFGHJKLMNPQRSTUVWXYZ abcdefghijkmnopqrstuvwxyz 23456789 '!@#%^*-_=+') out='' i byte set
  for i in $(seq 0 23); do
    set=${classes[i % 4]}
    byte=$(( 16#$("$SERVICES_OPENSSL" rand -hex 1) ))
    out+=${set:byte % ${#set}:1}
  done
  printf '%s' "$out"
}
random_email() { printf 'safbox-test-%s@example.invalid' "$("$SERVICES_OPENSSL" rand -hex 4)"; }

# tls_checks HOST PORT: the proxy's TLS on PORT. Saves the certificate it
# serves to $WORK/cert.pem, which later requests use as their only trust
# anchor, so they prove the certificate names HOST (trust on first use: the
# certificate is self-signed per install). The FIPS policy's limits are
# probed from this side, with a client that would accept more: TLS 1.0 and
# 1.1 and a ChaCha20-only TLS 1.2 offer must all be refused.
tls_checks() {
  local host=$1 port=$2 out
  out=$("$SERVICES_OPENSSL" s_client -connect "$host:$port" -servername "$host" -brief </dev/null 2>&1) || true
  if grep -q '^Protocol version: TLSv1.3$' <<<"$out"; then
    pass "port $port negotiates $(grep -m1 '^Protocol version:' <<<"$out" | cut -d' ' -f3), $(grep -m1 '^Ciphersuite:' <<<"$out" | cut -d' ' -f2)"
  else
    fail "port $port did not negotiate TLS 1.3: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  fi
  "$SERVICES_OPENSSL" s_client -connect "$host:$port" -servername "$host" -showcerts </dev/null 2>/dev/null \
    | "$SERVICES_OPENSSL" x509 -outform PEM > "$WORK/cert.pem" 2>/dev/null || true
  if [[ -s "$WORK/cert.pem" ]]; then
    pass "port $port serves certificate $("$SERVICES_OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -ext subjectAltName 2>/dev/null | tr '\n' ' ')"
  else
    fail "port $port served no certificate"
  fi
  refused "$host" "$port" "TLS 1.0" -tls1 -cipher 'ALL:@SECLEVEL=0'
  refused "$host" "$port" "TLS 1.1" -tls1_1 -cipher 'ALL:@SECLEVEL=0'
  refused "$host" "$port" "ChaCha20-Poly1305 (not FIPS-approved)" -tls1_2 \
    -cipher 'ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-CHACHA20-POLY1305'
}

# refused HOST PORT LABEL S_CLIENT-ARGS...: the server must reject the offer
# with a TLS alert. A refused connection, or a client that will not make the
# offer at all, proves nothing and fails.
refused() {
  local host=$1 port=$2 label=$3 out rc=0
  shift 3
  out=$("$SERVICES_OPENSSL" s_client -connect "$host:$port" "$@" </dev/null 2>&1) || rc=$?
  if (( rc == 0 )) && grep -qE '^(New|Reused), ' <<<"$out"; then
    fail "port $port accepts $label"
  elif grep -qE 'alert (protocol version|handshake failure|insufficient security)|wrong version number' <<<"$out"; then
    pass "port $port refuses $label ($(grep -oE 'alert [a-z ]+|wrong version number' <<<"$out" | head -1))"
  else
    fail "port $port: no server verdict on $label: $(grep -m1 -iE 'error' <<<"$out" | cut -c1-160)"
  fi
}

# https CURL-ARGS...: curl over HTTPS trusting only the certificate
# tls_checks saved.
https() { curl -sS --cacert "$WORK/cert.pem" "$@"; }

# page_and_assets URL: fetch an HTML page and every script and stylesheet it
# references from the same origin, each of which must answer 200.
page_and_assets() {
  local url=$1 origin code asset n=0
  origin=$(sed -E 's#^(https://[^/]+).*#\1#' <<<"$url")
  code=$(https -o "$WORK/page.html" -w '%{http_code}' "$url") || code=000
  if [[ "$code" != 200 ]]; then fail "GET $url -> $code"; return; fi
  pass "GET $url -> 200"
  while IFS= read -r asset; do
    [[ -n "$asset" ]] || continue
    case "$asset" in
      http://*|https://*|//*) continue ;;  # another origin: not served by the box
      /*) ;;
      *) asset="/$asset" ;;
    esac
    n=$((n + 1))
    code=$(https -o /dev/null -w '%{http_code}' "$origin$asset") || code=000
    if [[ "$code" == 200 ]]; then pass "GET $asset -> 200"; else fail "GET $asset -> $code"; fi
  done < <(grep -oE '<(script|link)[^>]+(src|href)="[^"]+\.(js|css)[^"]*"' "$WORK/page.html" \
             | sed -E 's/.*(src|href)="([^"]+)".*/\2/' | sort -u)
  if (( n > 0 )); then pass "$n script and stylesheet assets load"; else fail "no script or stylesheet assets found on $url"; fi
}

# not_reachable HOST PORT...: plain TCP to each port must fail from here
# (the applications and databases listen on the box's loopback only).
not_reachable() {
  local host=$1 port rc
  shift
  for port in "$@"; do
    rc=0
    curl -sS -o /dev/null --connect-timeout 5 "http://$host:$port/" 2>/dev/null || rc=$?
    case "$rc" in
      7|28) pass "port $port is not reachable from outside" ;;
      *) fail "port $port answered from outside (curl exit $rc)" ;;
    esac
  done
}

finish() {
  if (( fails > 0 )); then echo "FAIL: $fails check(s) failed"; exit 1; fi
  echo "PASS: $1"
}
