#!/usr/bin/env bats
# The safbox command's services rows (ansible/roles/template_os/files/safbox)
# against stub systemctl and curl written per test: each service's unit
# state, and Keycloak's readiness, asked of the realm on the port the
# keycloak pod publishes on the loopback address. The other rows read the
# machine running the tests and are not checked here.
#
#   tests/bats/run.sh tests/scripts/safbox-status.bats
#   SAFBOX_SH=/path/safbox tests/bats/run.sh ...    another copy
bats_require_minimum_version 1.14.0
load ../bats/common

setup() {
  SAFBOX_SH=${SAFBOX_SH:-$ROOT/ansible/roles/template_os/files/safbox}
  BIN=$BATS_TEST_TMPDIR/bin STUB=$BATS_TEST_TMPDIR/stub
  mkdir -p "$BIN" "$STUB"
  # systemctl: the units listed in $STUB/units ("unit state") exist, in
  # that state; `cat keycloak-pod.service` prints the publish option the
  # generated unit carries.
  cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
unit=${*: -1}
state=$(sed -n "s/^${unit} //p" "$STUB_DIR/units")
case "$1" in
  cat)
    [ -n "$state" ] || exit 1
    if [ "$unit" = keycloak-pod.service ]; then
      echo "ExecStart=/usr/bin/podman pod create --infra-name keycloak-infra --publish 127.0.0.1:3002:8080 --name keycloak"
    fi ;;
  show) echo "$state" ;;
esac
EOF
  # curl: records each URL; answers when $STUB/curl.ok exists.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >> "$STUB_DIR/curl.calls"
[ -e "$STUB_DIR/curl.ok" ]
EOF
  chmod +x "$BIN/systemctl" "$BIN/curl"
  : > "$STUB/units"
}

units() { printf '%s\n' "$@" > "$STUB/units"; }
status() { PATH="$BIN:$PATH" STUB_DIR="$STUB" run -0 "$SAFBOX_SH" status; }

@test "Keycloak's unit state is listed with Heimdall's and Vulcan's" {
  units 'heimdall.service active' 'vulcan.service active' 'keycloak.service activating' \
    'keycloak-pod.service active' 'safbox-proxy.service active'
  status
  assert_line --regexp '^Heimdall: +active$'
  assert_line --regexp '^Vulcan: +active$'
  assert_line --regexp '^Keycloak: +activating$'
  assert_line --regexp '^TLS proxy: +active$'
}

@test "a running Keycloak whose realm answers is ready" {
  units 'keycloak.service active' 'keycloak-pod.service active'
  touch "$STUB/curl.ok"
  status
  assert_line --regexp '^Keycloak: +active$'
  assert_line --regexp '^Keycloak readiness: +ready \(realm safbox answers on 127\.0\.0\.1:3002\)$'
  assert_equal "$(cat "$STUB/curl.calls")" 'http://127.0.0.1:3002/realms/safbox/.well-known/openid-configuration'
}

@test "a running Keycloak whose realm does not answer is not ready" {
  units 'keycloak.service active' 'keycloak-pod.service active'
  status
  assert_line --regexp '^Keycloak readiness: +not ready \(realm safbox does not answer on 127\.0\.0\.1:3002\)$'
}

@test "a Keycloak that is not running is not asked" {
  units 'keycloak.service inactive' 'keycloak-pod.service inactive'
  status
  assert_line --regexp '^Keycloak: +inactive$'
  assert_line --regexp '^Keycloak readiness: +not checked \(Keycloak is inactive\)$'
  assert_file_not_exists "$STUB/curl.calls"
}

@test "a switched-off Keycloak is not installed and has no readiness row" {
  units 'heimdall.service active'
  status
  assert_line --regexp '^Keycloak: +not installed$'
  refute_line --partial 'Keycloak readiness'
  assert_file_not_exists "$STUB/curl.calls"
}
