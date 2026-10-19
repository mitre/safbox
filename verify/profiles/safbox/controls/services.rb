# frozen_string_literal: true

# Heimdall and Vulcan each run as a podman pod (the application and its
# PostgreSQL) on the loopback address, behind one nginx TLS proxy. The units
# are installed at build and start once first boot has written their
# secrets, so the build VM has units and no secrets, and a deployed clone
# has both and runs them. Secret files are checked by owner and mode only,
# never by content, so no secret reaches the results.
#
# Quadlet units are systemd unit files: parse_config_file with
# multiple_values reads each [Section] and keeps every value of a key that
# repeats (Environment=), so each key is a list.

services = input('expected_services')
deployed = input('deployed')
domain = input('domain')
quadlet = '/etc/containers/systemd'
trust_store = '/etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro'
pinned = /@sha256:\h{64}$/
# Every database runs the CentOS Stream build of the sclorg PostgreSQL image,
# whose OpenSSL has a FIPS provider: safbox-heimdall-5, safbox-vulcan-4 and
# safbox-keycloak-6 check it in the running containers.
postgresql = %r{^quay\.io/sclorg/postgresql-\d+-c9s@sha256:\h{64}$}
# The names the proxy serves besides the domain, one per application.
served_apps = %w[heimdall vulcan keycloak]

control 'safbox-heimdall-1' do
  impact 1.0
  title 'The Heimdall Quadlet units are installed'
  desc 'Heimdall and its database run from images pinned by digest, the database from the CentOS Stream PostgreSQL image, with memory limits, no new privileges and the host CA trust store mounted read-only. The pod publishes 127.0.0.1:3000 only and waits for first boot to write its secrets; the unit is ready only once Heimdall answers its healthcheck. Registration is off: the only local account is the administrator, admin@<domain>, made on the first start with the password first boot wrote. With Keycloak on, everyone else signs in through it.'
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  describe parse_config_file("#{quadlet}/heimdall.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3000:3000'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/heimdall.env'] }
    # Inside a pod 127.0.0.1 is the pod: Keycloak's name must reach the proxy on the host.
    if services.include?('keycloak')
      its('Pod.AddHost') { should eq ["keycloak.#{domain}:host-gateway"] }
    else
      its('Pod.AddHost') { should be_nil }
    end
  end
  describe parse_config_file("#{quadlet}/heimdall.container", multiple_values: true) do
    # Ready only once it answers, so the end of boot waits for it.
    its('Container.HealthCmd') { should eq ['curl -fsS -o /dev/null http://localhost:3000/'] }
    its('Container.Notify') { should eq ['healthy'] }
    its('Container.Image') { should all match(pinned) }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Volume') { should include trust_store }
    its('Container.Environment') { should include "EXTERNAL_URL=https://heimdall.#{domain}" }
    its('Container.Environment') { should include 'REGISTRATION_DISABLED=true' }
    its('Container.Environment') { should include "ADMIN_EMAIL=admin@#{domain}" }
    if services.include?('keycloak')
      its('Container.Environment') { should include "OIDC_ISSUER=https://keycloak.#{domain}/realms/safbox" }
      its('Container.Environment') { should include 'OIDC_USES_PKCE_S256=true' }
      its('Container.EnvironmentFile') { should include '/etc/safbox/heimdall-oidc.env' }
    else
      its('Container.Environment') { should_not include(a_string_starting_with('OIDC_')) }
    end
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/heimdall-db.container", multiple_values: true) do
    its('Container.Image') { should all match(postgresql) }
    its('Container.Memory') { should_not be_empty }
  end
end

control 'safbox-heimdall-2' do
  impact 1.0
  title "Heimdall's secrets exist only after first boot, readable by root only"
  desc "First boot writes the database password, JWT secret, API key secret and administrator password, and Heimdall's Keycloak client secret in a file of its own. The template and the build VM hold none."
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  %w[/etc/safbox/heimdall.env /etc/safbox/heimdall-db.env /etc/safbox/heimdall-oidc.env].each do |path|
    describe file(path) do
      if deployed
        its('owner') { should eq 'root' }
        its('mode') { should cmp '0600' }
        its('size') { should be > 0 }
      else
        it { should_not exist }
      end
    end
  end
end

control 'safbox-heimdall-3' do
  impact 1.0
  title 'Heimdall is up on the loopback address only, with FIPS-mode crypto'
  desc 'Heimdall and its database run, Heimdall answers on 127.0.0.1:3000 for the proxy and nowhere else, and Node.js inside the container runs in FIPS mode.'
  only_if('Heimdall is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('heimdall') && deployed }

  %w[heimdall heimdall-db].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe port(3000) do
    its('addresses') { should eq ['127.0.0.1'] }
  end
  describe http('http://127.0.0.1:3000/') do
    its('status') { should eq 200 }
  end
  describe command(%q(podman exec heimdall node -p "require('crypto').getFips()")) do
    its('stdout.strip') { should eq '1' }
  end
end

control 'safbox-heimdall-5' do
  impact 1.0
  title "Heimdall's PostgreSQL runs its crypto in FIPS mode"
  desc "PostgreSQL computes its password hashes (SCRAM-SHA-256) and digest functions with the OpenSSL in its container. That OpenSSL has its FIPS provider active under the host's FIPS crypto policy, so PostgreSQL refuses MD5; it stores passwords as SCRAM-SHA-256 only, and accepts no password method other than SCRAM-SHA-256 over TCP and no unauthenticated connection: only its own administrator signs in, over the container's local socket (peer). The provider is the CentOS Stream build of OpenSSL's FIPS provider, which runs in FIPS mode but carries no CMVP certificate."
  only_if('Heimdall is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('heimdall') && deployed }

  # As the database's own administrator, over the container's local socket.
  psql = 'podman exec -u postgres heimdall-db psql -X -A -t -c'
  describe command('podman exec heimdall-db openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec heimdall-db cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
  describe command(%(#{psql} "SELECT md5('safbox')")) do
    its('exit_status') { should_not eq 0 }
    its('stderr') { should match(/could not compute MD5 hash/) }
  end
  describe command(%(#{psql} "SELECT encode(sha256('abc'), 'hex')")) do
    its('stdout.strip') { should eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
  end
  describe command(%(#{psql} "SHOW password_encryption")) do
    its('stdout.strip') { should eq 'scram-sha-256' }
  end
  describe command(%(#{psql} "SELECT DISTINCT type || ' ' || auth_method FROM pg_hba_file_rules ORDER BY 1")) do
    its('stdout') { should eq "host scram-sha-256\nlocal peer\n" }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword NOT LIKE 'SCRAM-SHA-256%'")) do
    its('exit_status') { should eq 0 }
    its('stdout') { should eq '' }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'SCRAM-SHA-256%'")) do
    its('stdout') { should eq "heimdall\n" }
  end
end

control 'safbox-vulcan-1' do
  impact 1.0
  title 'The Vulcan Quadlet units are installed'
  desc 'Vulcan and its database run from images pinned by digest, the database from the CentOS Stream PostgreSQL image, with memory limits, no new privileges and the host CA trust store mounted read-only. The pod publishes 127.0.0.1:3001 only and waits for first boot to write its secrets; the unit is ready only once Vulcan answers its healthcheck. Local login is on and registration is set off (VULCAN_ENABLE_USER_REGISTRATION=false). The administrator, admin@<domain>, is made on the first start with the password first boot wrote, and no user becomes admin by being first. With Keycloak on, everyone else signs in through it. Known upstream defect, accepted: Vulcan 2.4.1 only hides the sign-up link, so anyone who can reach it can still register a regular local account; this control checks the setting, not that registration is refused.'
  only_if('Vulcan is switched off', impact: 0.0) { services.include?('vulcan') }

  describe parse_config_file("#{quadlet}/vulcan.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3001:3000'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/vulcan.env'] }
    # Inside a pod 127.0.0.1 is the pod: Keycloak's name must reach the proxy on the host.
    if services.include?('keycloak')
      its('Pod.AddHost') { should eq ["keycloak.#{domain}:host-gateway"] }
    else
      its('Pod.AddHost') { should be_nil }
    end
  end
  describe parse_config_file("#{quadlet}/vulcan.container", multiple_values: true) do
    # Ready only once it answers, so the end of boot waits for it.
    its('Container.HealthCmd') { should eq ['curl -f http://localhost:3000/up || exit 1'] }
    its('Container.Notify') { should eq ['healthy'] }
    its('Container.Image') { should all match(pinned) }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Volume') { should include trust_store }
    its('Container.Environment') { should include 'VULCAN_ENABLE_LOCAL_LOGIN=true' }
    its('Container.Environment') { should include 'VULCAN_ENABLE_USER_REGISTRATION=false' }
    its('Container.Environment') { should include 'VULCAN_FIRST_USER_ADMIN=false' }
    its('Container.Environment') { should include "VULCAN_ADMIN_EMAIL=admin@#{domain}" }
    if services.include?('keycloak')
      its('Container.Environment') { should include 'VULCAN_ENABLE_OIDC=true' }
      its('Container.Environment') { should include "VULCAN_OIDC_ISSUER_URL=https://keycloak.#{domain}/realms/safbox" }
      its('Container.EnvironmentFile') { should include '/etc/safbox/vulcan-oidc.env' }
    else
      its('Container.Environment') { should_not include 'VULCAN_ENABLE_OIDC=true' }
    end
    its('Container.Environment') { should include 'RAILS_FORCE_SSL=true' }
    its('Container.Environment') { should include "VULCAN_APP_URL=https://vulcan.#{domain}" }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/vulcan-db.container", multiple_values: true) do
    its('Container.Image') { should all match(postgresql) }
    its('Container.Memory') { should_not be_empty }
  end
end

control 'safbox-vulcan-2' do
  impact 1.0
  title "Vulcan's secrets exist only after first boot, readable by root only"
  desc "First boot writes the database password, Rails secret key base, cipher password and salt and administrator password, and Vulcan's Keycloak client secret in a file of its own. The template and the build VM hold none."
  only_if('Vulcan is switched off', impact: 0.0) { services.include?('vulcan') }

  %w[/etc/safbox/vulcan.env /etc/safbox/vulcan-db.env /etc/safbox/vulcan-oidc.env].each do |path|
    describe file(path) do
      if deployed
        its('owner') { should eq 'root' }
        its('mode') { should cmp '0600' }
        its('size') { should be > 0 }
      else
        it { should_not exist }
      end
    end
  end
end

control 'safbox-vulcan-3' do
  impact 1.0
  title 'Vulcan is up on the loopback address only, with FIPS-mode crypto'
  desc "Vulcan and its database run, Vulcan answers on 127.0.0.1:3001 for the proxy and nowhere else, and Ruby's OpenSSL inside the container runs in FIPS mode."
  only_if('Vulcan is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('vulcan') && deployed }

  %w[vulcan vulcan-db].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe port(3001) do
    its('addresses') { should eq ['127.0.0.1'] }
  end
  # Vulcan redirects plain HTTP unless the proxy says the client used HTTPS.
  describe http('http://127.0.0.1:3001/up', headers: { 'X-Forwarded-Proto' => 'https' }) do
    its('status') { should eq 200 }
  end
  describe command(%q(podman exec vulcan ruby -ropenssl -e 'print OpenSSL.fips_mode')) do
    its('stdout') { should eq 'true' }
  end
end

control 'safbox-vulcan-4' do
  impact 1.0
  title "Vulcan's PostgreSQL runs its crypto in FIPS mode"
  desc "PostgreSQL computes its password hashes (SCRAM-SHA-256) and digest functions with the OpenSSL in its container. That OpenSSL has its FIPS provider active under the host's FIPS crypto policy, so PostgreSQL refuses MD5; it stores passwords as SCRAM-SHA-256 only, and accepts no password method other than SCRAM-SHA-256 over TCP and no unauthenticated connection: only its own administrator signs in, over the container's local socket (peer). The provider is the CentOS Stream build of OpenSSL's FIPS provider, which runs in FIPS mode but carries no CMVP certificate."
  only_if('Vulcan is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('vulcan') && deployed }

  # As the database's own administrator, over the container's local socket.
  psql = 'podman exec -u postgres vulcan-db psql -X -A -t -c'
  describe command('podman exec vulcan-db openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec vulcan-db cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
  describe command(%(#{psql} "SELECT md5('safbox')")) do
    its('exit_status') { should_not eq 0 }
    its('stderr') { should match(/could not compute MD5 hash/) }
  end
  describe command(%(#{psql} "SELECT encode(sha256('abc'), 'hex')")) do
    its('stdout.strip') { should eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
  end
  describe command(%(#{psql} "SHOW password_encryption")) do
    its('stdout.strip') { should eq 'scram-sha-256' }
  end
  describe command(%(#{psql} "SELECT DISTINCT type || ' ' || auth_method FROM pg_hba_file_rules ORDER BY 1")) do
    its('stdout') { should eq "host scram-sha-256\nlocal peer\n" }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword NOT LIKE 'SCRAM-SHA-256%'")) do
    its('exit_status') { should eq 0 }
    its('stdout') { should eq '' }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'SCRAM-SHA-256%'")) do
    its('stdout') { should eq "vulcan\n" }
  end
end

control 'safbox-keycloak-1' do
  impact 1.0
  title "Keycloak's FIPS image is built on the template from pinned inputs"
  desc "Keycloak runs in FIPS strict mode from an image the build makes from Keycloak's image, pinned by digest, and the four Bouncy Castle FIPS jars Keycloak's FIPS guide asks for, pinned by sha256. The build keeps its Containerfile and the jars' sums in /etc/safbox-keycloak; the jars in the image must have those sums, and the image must have been built with the FIPS strict options."
  only_if('Keycloak is switched off', impact: 0.0) { services.include?('keycloak') }

  # The one tag the build made; the pin itself lives in group_vars.
  images = command(%q(podman images --noheading --format "{{.Repository}}:{{.Tag}}" --filter reference=localhost/safbox-keycloak-fips)).stdout.lines.map(&:strip).reject(&:empty?)
  conf = '/etc/safbox-keycloak'
  describe file("#{conf}/Containerfile") do
    its('content') { should match(%r{^FROM quay\.io/keycloak/keycloak@sha256:\h{64}( AS builder)?$}) }
    its('content') { should_not match(/^FROM (?!quay\.io\/keycloak\/keycloak@sha256:\h{64})/) }
  end
  describe "The derived Keycloak image" do
    subject { images }
    its('length') { should eq 1 }
  end
  image = images.first.to_s
  # Each jar is read out of a created, never started, container. --sudo
  # prefixes sudo to the command's first word only, so each pipeline runs
  # in one root shell (sh -c) to reach root's images.
  file("#{conf}/providers.sha256").content.to_s.lines.map(&:split).each do |sum, jar|
    describe command(%(sh -c 'c=$(podman create #{image}) && podman cp "$c:/opt/keycloak/providers/#{jar}" - | tar -xO | sha256sum; podman rm -f "$c" >/dev/null')) do
      its('stdout') { should start_with sum }
    end
  end
  # kc.sh build records the build options it persists in
  # META-INF/keycloak-persisted.properties inside generated-bytecode.jar.
  # The FIPS mode is compiled into the generated code instead, so strict
  # mode is checked in the build command here and at run time by its
  # Approved Mode log line (safbox-keycloak-4).
  describe file("#{conf}/Containerfile") do
    its('content') { should match(/^RUN \S*kc\.sh build .*--features=fips .*--fips-mode=strict/) }
  end
  describe command(%(sh -c 'm=$(podman image mount #{image}) && unzip -p "$m/opt/keycloak/lib/quarkus/generated-bytecode.jar" META-INF/keycloak-persisted.properties; podman image unmount #{image} >/dev/null')) do
    its('stdout') { should match(/^kc\.features=fips$/) }
    its('stdout') { should match(/^kc\.db=postgres$/) }
    its('stdout') { should match(/^kc\.health-enabled=true$/) }
  end
end

control 'safbox-keycloak-2' do
  impact 1.0
  title 'The Keycloak Quadlet units are installed'
  desc "Keycloak runs from the image built on the template and its database from the CentOS Stream PostgreSQL image, pinned by digest, with memory limits and no new privileges. The pod publishes Keycloak's HTTP port on 127.0.0.1 only, for the proxy, and waits for first boot to write its secrets; the unit is ready only once Keycloak reports itself ready. Keycloak runs a single node (local cache), imports the safbox realm on its first start, and believes forwarded headers only from its network's gateway, where the proxy's connections arrive."
  only_if('Keycloak is switched off', impact: 0.0) { services.include?('keycloak') }

  network = parse_config_file("#{quadlet}/keycloak.network", multiple_values: true)
  describe network do
    its('Network.Subnet') { should_not be_empty }
    its('Network.Gateway') { should_not be_empty }
  end
  describe parse_config_file("#{quadlet}/keycloak.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3002:8080'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/keycloak.env'] }
  end
  describe parse_config_file("#{quadlet}/keycloak.container", multiple_values: true) do
    # Ready only once /health/ready answers, so the end of boot waits for it.
    its('Container.HealthCmd') { should eq [%q({ printf 'HEAD /health/ready HTTP/1.0\r\n\r\n' >&0; grep -q 'HTTP/1.0 200'; } 0<>/dev/tcp/localhost/9000)] }
    its('Container.Notify') { should eq ['healthy'] }
    its('Container.Image') { should all match(%r{^localhost/safbox-keycloak-fips:}) }
    its('Container.Exec') { should eq ['start --optimized --import-realm'] }
    its('Container.Environment') { should include 'KC_CACHE=local' }
    its('Container.Environment') { should include "KC_HOSTNAME=https://keycloak.#{domain}" }
    its('Container.Environment') { should include 'KC_PROXY_HEADERS=xforwarded' }
    its('Container.Environment') { should include "KC_PROXY_TRUSTED_ADDRESSES=#{network.params.dig('Network', 'Gateway')&.first}" }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/keycloak-db.container", multiple_values: true) do
    its('Container.Image') { should all match(postgresql) }
    its('Container.Memory') { should_not be_empty }
  end
  describe json('/etc/safbox-keycloak/safbox-realm.json') do
    its('realm') { should eq 'safbox' }
    its('registrationAllowed') { should eq false }
    its('bruteForceProtected') { should eq true }
    its('passwordPolicy') { should match(/hashAlgorithm\(pbkdf2-sha512\)/) }
  end
end

control 'safbox-keycloak-3' do
  impact 1.0
  title "Keycloak's secrets exist only after first boot, readable by root only"
  desc "First boot writes Keycloak's database password and its bootstrap administrator's password. The template and the build VM hold none, and the realm file holds placeholders only."
  only_if('Keycloak is switched off', impact: 0.0) { services.include?('keycloak') }

  %w[/etc/safbox/keycloak.env /etc/safbox/keycloak-db.env].each do |path|
    describe file(path) do
      if deployed
        its('owner') { should eq 'root' }
        its('mode') { should cmp '0600' }
        its('size') { should be > 0 }
      else
        it { should_not exist }
      end
    end
  end
  describe file('/etc/safbox-keycloak/safbox-realm.json') do
    its('content') { should_not match(/"(secret|value)": "(?!\$\{)/) }
  end
end

control 'safbox-keycloak-4' do
  impact 1.0
  title 'Keycloak is up on the loopback address only, in FIPS strict mode'
  desc "Keycloak and its database run; Keycloak answers on 127.0.0.1:3002 for the proxy and nowhere else, serves the safbox realm, and logged at this boot's start that Bouncy Castle FIPS runs in Approved Mode with the JVM in FIPS mode (strict mode is built into the image: safbox-keycloak-1)."
  only_if('Keycloak is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('keycloak') && deployed }

  %w[keycloak keycloak-db].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe port(3002) do
    its('addresses') { should eq ['127.0.0.1'] }
  end
  describe http('http://127.0.0.1:3002/realms/safbox/.well-known/openid-configuration') do
    its('status') { should eq 200 }
  end
  describe command('journalctl -b -u keycloak.service --no-pager -o cat') do
    its('stdout') { should match(/FIPS1402Provider created: KC\(BCFIPS version [\d.]+ Approved Mode, FIPS-JVM: enabled\)/) }
  end
end

control 'safbox-keycloak-5' do
  impact 1.0
  title "Keycloak's administration paths answer to the box itself only"
  desc "Keycloak's reverse-proxy guide advises against exposing /admin/ and the master realm. The proxy serves them to requests from the box's own address and refuses every other client; the safbox realm, which the applications and browsers use, is served to all. Refusal from another machine is tested from outside (tests/services/keycloak-login.sh)."
  only_if('Keycloak or the proxy is switched off', impact: 0.0) { services.include?('keycloak') && services.include?('proxy') }

  conf = file('/etc/safbox-proxy/nginx.conf').content.to_s
  %w[/admin/ /realms/master/].each do |path|
    describe "nginx's location for #{path}" do
      subject { conf[/location \^~ #{Regexp.escape(path)} \{[^}]*\}/m] }
      it { should match(/allow 127\.0\.0\.1;/) }
      it { should match(/deny all;/) }
    end
  end
  if deployed
    describe http("https://keycloak.#{domain}/realms/master/.well-known/openid-configuration") do
      its('status') { should eq 200 }
    end
  end
end

control 'safbox-keycloak-6' do
  impact 1.0
  title "Keycloak's PostgreSQL runs its crypto in FIPS mode"
  desc "PostgreSQL computes its password hashes (SCRAM-SHA-256) and digest functions with the OpenSSL in its container. That OpenSSL has its FIPS provider active under the host's FIPS crypto policy, so PostgreSQL refuses MD5; it stores passwords as SCRAM-SHA-256 only, and accepts no password method other than SCRAM-SHA-256 over TCP and no unauthenticated connection: only its own administrator signs in, over the container's local socket (peer). The provider is the CentOS Stream build of OpenSSL's FIPS provider, which runs in FIPS mode but carries no CMVP certificate."
  only_if('Keycloak is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('keycloak') && deployed }

  # As the database's own administrator, over the container's local socket.
  psql = 'podman exec -u postgres keycloak-db psql -X -A -t -c'
  describe command('podman exec keycloak-db openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec keycloak-db cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
  describe command(%(#{psql} "SELECT md5('safbox')")) do
    its('exit_status') { should_not eq 0 }
    its('stderr') { should match(/could not compute MD5 hash/) }
  end
  describe command(%(#{psql} "SELECT encode(sha256('abc'), 'hex')")) do
    its('stdout.strip') { should eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
  end
  describe command(%(#{psql} "SHOW password_encryption")) do
    its('stdout.strip') { should eq 'scram-sha-256' }
  end
  describe command(%(#{psql} "SELECT DISTINCT type || ' ' || auth_method FROM pg_hba_file_rules ORDER BY 1")) do
    its('stdout') { should eq "host scram-sha-256\nlocal peer\n" }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword NOT LIKE 'SCRAM-SHA-256%'")) do
    its('exit_status') { should eq 0 }
    its('stdout') { should eq '' }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'SCRAM-SHA-256%'")) do
    its('stdout') { should eq "keycloak\n" }
  end
end

control 'safbox-proxy-1' do
  impact 1.0
  title 'The TLS proxy unit and its nginx configuration are installed'
  desc "An nginx container from a Red Hat UBI 9 image pinned by digest terminates TLS on port 443, with ciphers from the system crypto policy and TLS 1.2 or later. Each application has its own name under #{domain}; port 80 only redirects to HTTPS, and nothing listens on any other port."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe parse_config_file("#{quadlet}/safbox-proxy.container", multiple_values: true) do
    its('Container.Image') { should all match(%r{^registry\.access\.redhat\.com/ubi9/nginx-\d+@sha256:\h{64}$}) }
    its('Container.Network') { should eq ['host'] }
    its('Container.ReadOnly') { should eq ['true'] }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/tls/safbox.key'] }
  end
  describe file('/etc/safbox-proxy/nginx.conf') do
    its('content') { should match(/^\s*ssl_ciphers PROFILE=SYSTEM;$/) }
    its('content') { should match(/^\s*ssl_protocols TLSv1\.2 TLSv1\.3;$/) }
    its('content') { should match(/^\s*listen 80 default_server;$/) }
    its('content') { should match(/^\s*listen 443 ssl default_server;$/) }
    its('content') { should_not match(/^\s*listen\s+(?!(80|443)[\s;])/) }
    served_apps.each do |app|
      if services.include?(app)
        its('content') { should match(/^\s*server_name #{Regexp.escape("#{app}.#{domain}")};$/) }
      else
        its('content') { should_not match(/^\s*server_name #{Regexp.escape("#{app}.#{domain}")};$/) }
      end
    end
  end
end

control 'safbox-proxy-2' do
  impact 1.0
  title 'Each name serves its page over HTTPS, with a certificate the box trusts'
  desc "#{domain} and the bare address serve the SAFBox documentation site as the start page, and its status.json lists each shipped application, up, at its own name, and was written after each of them and the proxy last started, with its refresh timer running; each application answers at that name on port 443. The names verify; the bare address does not, as the certificate names only the box's names. First boot adds the local CA that signs the proxy's certificate to the system trust store, so clients on the box verify it."
  only_if('The proxy is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('proxy') && deployed }

  apps = served_apps.select { |app| services.include?(app) }
  # The certificate names only the box's names, so the bare address is
  # fetched without verifying it.
  { "https://#{domain}/" => true, 'https://127.0.0.1/' => false }.each do |url, verify|
    describe http(url, ssl_verify: verify) do
      its('status') { should eq 200 }
      its('body') { should match(%r{<title>SAFBox}) }
    end
  end
  status = json(content: http("https://#{domain}/status.json").body)
  apps.each do |app|
    describe "#{app} in the start page's status.json" do
      subject { status['services'].to_a.find { |s| s['url'].to_s.start_with?("https://#{app}.#{domain}/") } }
      it { should_not be_nil }
      its(['state']) { should eq 'up' }
    end
  end
  # The status is current: each listed unit's start pulls in a rewrite
  # ordered after it, and the timer rewrites it every minute.
  written = file('/etc/safbox-proxy/html/status.json').mtime.to_i
  (apps.map { |app| "#{app}.service" } + ['safbox-proxy.service']).each do |unit|
    started = command("systemctl show --timestamp=unix -P ActiveEnterTimestamp #{unit}").stdout[/\A@(\d+)/, 1]
    describe "The start page's status.json, written at @#{written}, after #{unit} last became active (@#{started})" do
      subject { !started.nil? && written >= started.to_i }
      it { should eq true }
    end
  end
  describe service('safbox-site-status.timer') do
    it { should be_enabled }
    it { should be_running }
  end
  {
    'heimdall' => ['/', %r{<title>Heimdall</title>}],
    'vulcan' => ['/users/sign_in', /Vulcan/],
    'keycloak' => ['/realms/safbox/.well-known/openid-configuration', %r{"issuer":"https://keycloak\.#{Regexp.escape(domain)}/realms/safbox"}],
  }.each do |app, (path, page)|
    next unless apps.include?(app)

    describe http("https://#{app}.#{domain}#{path}") do
      its('status') { should eq 200 }
      its('body') { should match(page) }
    end
  end
end

control 'safbox-proxy-3' do
  impact 1.0
  title 'The box resolves its names to itself, and its first-boot certificate names them'
  desc "/etc/hosts maps #{domain} and each shipped application's name to 127.0.0.1, and a switched-off application's name is not mapped. First boot writes a certificate for exactly those names, signed by a local CA of the box's own that may sign only server certificates for names under #{domain}, and no IP address. Both keys are readable by root only, and the CA's key is kept outside the directory the proxy container mounts. The template and the build VM hold no certificate. A site may replace the certificate and its key with its own and retire the local CA; the exact names and the CA's limits are then not checked."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  apps = served_apps.select { |app| services.include?(app) }
  describe host(domain) do
    its('ipv4_address') { should eq ['127.0.0.1'] }
  end
  served_apps.each do |app|
    describe host("#{app}.#{domain}") do
      if apps.include?(app)
        its('ipv4_address') { should eq ['127.0.0.1'] }
      else
        it { should_not be_resolvable }
      end
    end
  end
  if deployed
    describe file('/etc/safbox/tls/safbox.key') do
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0600' }
    end
    # The proxy container mounts /etc/safbox/tls; the CA's key stays out of it.
    describe file('/etc/safbox/tls/ca.key') do
      it { should_not exist }
    end
    describe x509_certificate('/etc/safbox/tls/safbox.crt') do
      its('validity_in_days') { should be > 0 }
    end
    # A site that installs its own certificate retires the local CA (its key
    # and certificate); the checks below are for the local CA and the
    # certificate it signed on first boot.
    if file('/etc/safbox/ca/ca.key').exist?
      describe file('/etc/safbox/ca') do
        its('mode') { should cmp '0700' }
      end
      describe file('/etc/safbox/ca/ca.key') do
        its('owner') { should eq 'root' }
        its('mode') { should cmp '0600' }
      end
      local_ca = x509_certificate('/etc/safbox/ca/ca.crt')
      describe local_ca do
        its('extensions.nameConstraints') do
          should eq ['critical', 'Permitted:', "DNS:#{domain}", "DNS:.#{domain}",
                     'Excluded:', 'IP:0.0.0.0/0.0.0.0', 'IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0']
        end
        its('extensions.extendedKeyUsage') { should eq ['TLS Web Server Authentication'] }
      end
      served = x509_certificate('/etc/safbox/tls/safbox.crt')
      if served.issuer_dn == local_ca.subject_dn
        describe served do
          its('subject_alt_names') { should match_array(([domain] + apps.map { |app| "#{app}.#{domain}" }).map { |name| "DNS:#{name}" }) }
        end
      end
    end
  else
    %w[/etc/safbox/tls/safbox.key /etc/safbox/ca].each do |path|
      describe file(path) do
        it { should_not exist }
      end
    end
  end
end

control 'safbox-proxy-4' do
  impact 1.0
  title 'The firewall opens HTTP and HTTPS and no other port'
  desc 'Apart from the services firewalld allows by name (ssh and the like), only http (80, which redirects) and https (443) are open, and the proxy listens on those two ports and no others.'
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe firewalld do
    it { should have_service_enabled_in_zone('http') }
    it { should have_service_enabled_in_zone('https') }
  end
  describe command('firewall-cmd --list-ports') do
    its('stdout.split') { should be_empty }
  end
  [8443, 9443].each do |number|
    describe port(number) do
      it { should_not be_listening }
    end
  end
  if deployed
    [80, 443].each do |number|
      describe port(number) do
        it { should be_listening }
      end
    end
  end
end

control 'safbox-proxy-5' do
  impact 1.0
  title "The proxy's TLS uses the OpenSSL FIPS provider under the FIPS crypto policy"
  desc 'nginx uses the OpenSSL in its image, which loads its FIPS provider on a FIPS host, and podman gives the container the host FIPS policy.'
  only_if('The proxy is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('proxy') && deployed }

  describe command('podman exec safbox-proxy openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec safbox-proxy cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
end

control 'safbox-proxy-6' do
  impact 1.0
  title 'Plain HTTP is redirected to HTTPS with the same name and path'
  desc 'Port 80 answers every request with a permanent redirect to https:// on the same host and path, and a plain HTTP request sent to port 443 is redirected the same way instead of being refused with 400.'
  only_if('The proxy is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('proxy') && deployed }

  [domain, '127.0.0.1'].each do |name|
    ["http://#{name}/safbox/check?probe=1", "http://#{name}:443/safbox/check?probe=1"].each do |url|
      describe http(url) do
        its('status') { should eq 301 }
        its('headers.Location') { should eq "https://#{name}/safbox/check?probe=1" }
      end
    end
  end
end
