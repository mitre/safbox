# frozen_string_literal: true

# Vulcan and its PostgreSQL as Quadlet units (ADR-0001 Phase 6; the services
# role, task group safbox-services-2). Like Heimdall, the units are installed
# and enabled at build and start only once first boot has written their
# secrets: the build-time gate checks the units and the absence of secrets,
# the release gate (a deployed clone) the running pod.
#
# Secret values never reach the results: env files are checked by counting
# matching lines, never by printing their content.

service_expected = ->(service) { input('expected_services').map(&:to_s).include?(service) }
deployed = input('firstboot_completed_expected')
# name@digest, the reference each Quadlet unit runs. InSpec gives the nested
# keys of a Hash input from inspec.yml as symbols (an inputs file may give
# strings), so normalise them.
image_ref = lambda do |key|
  image = input('service_images')[key].transform_keys(&:to_s)
  "#{image['name']}@#{image['digest']}"
end
loopback_port = input('loopback_ports')['vulcan']
quadlet_dir = '/etc/containers/systemd'
trust_store = '/etc/pki/ca-trust/extracted'
env_file = '/etc/safbox/vulcan.env'
db_env_file = '/etc/safbox/vulcan-db.env'
# Secret name to the number of random bytes upstream's
# setup-docker-secrets.sh draws (openssl rand -hex <bytes>).
secrets = { 'POSTGRES_PASSWORD' => 33, 'SECRET_KEY_BASE' => 64, 'CIPHER_PASSWORD' => 64, 'CIPHER_SALT' => 32 }
# Non-secret settings the appliance sets on purpose (ADR-0001 Phase 6: local
# login, first user admin; the proxy terminates TLS).
settings = {
  'VULCAN_ENABLE_LOCAL_LOGIN' => 'true',
  'VULCAN_ENABLE_USER_REGISTRATION' => 'true',
  'VULCAN_FIRST_USER_ADMIN' => 'true',
  'RAILS_FORCE_SSL' => 'true',
}

control 'safbox-vulcan-1' do
  impact 1.0
  title 'Vulcan Quadlet units are installed and enabled'
  desc "ADR-0001 Phase 6: Vulcan and its PostgreSQL run as a systemd-managed podman pod from the upstream image and the service shape of Vulcan's docker-compose.yml, with pinned images, memory limits, a restart policy, a named volume for data and the host's CA trust store mounted read-only. Local login and registration are on and the first registered user is admin. The units wait for first boot: each needs the env file the first-boot hook writes."
  only_if('Vulcan is not in expected_services (safbox_services_2 switched off)') do
    service_expected.call('vulcan')
  end

  %w[vulcan.network vulcan.pod vulcan-db.volume vulcan-db.container vulcan.container].each do |unit|
    describe file("#{quadlet_dir}/#{unit}") do
      it { should exist }
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0644' }
    end
  end

  { 'vulcan' => image_ref.call('vulcan'), 'vulcan-db' => image_ref.call('vulcan_db') }.each do |name, image|
    describe file("#{quadlet_dir}/#{name}.container") do
      its('content') { should match(/^Image=#{Regexp.escape(image)}$/) }
      its('content') { should match(/^Pod=vulcan\.pod$/) }
      its('content') { should match(/^Memory=\d+[kmg]?$/i) }
      its('content') { should match(/^NoNewPrivileges=true$/) }
    end
    # Pulled at build, so a clone starts offline.
    describe command("podman image exists #{image}") do
      its('exit_status') { should eq 0 }
    end
    describe command("systemctl show -p Restart --value #{name}.service") do
      its('stdout.strip') { should eq 'always' }
    end
  end

  describe file("#{quadlet_dir}/vulcan.pod") do
    its('content') { should match(/^PublishPort=127\.0\.0\.1:#{loopback_port}:3000$/) }
    its('content') { should match(/^Network=vulcan\.network$/) }
    its('content') { should match(%r{^ConditionPathExists=#{Regexp.escape(env_file)}$}) }
  end

  describe file("#{quadlet_dir}/vulcan-db.container") do
    its('content') { should match(/^Volume=vulcan-db\.volume:/) }
    its('content') { should match(%r{^EnvironmentFile=#{Regexp.escape(db_env_file)}$}) }
  end

  # The host's extracted trust store, read-only, where the image's own
  # OpenSSL, Node.js and Ruby read it, so the application trusts exactly
  # what the host trusts (the site CA bundles of the site_config role).
  describe file("#{quadlet_dir}/vulcan.container") do
    its('content') { should match(%r{^EnvironmentFile=#{Regexp.escape(env_file)}$}) }
    its('content') { should match(/^DropCapability=all$/) }
    its('content') { should match(%r{^Volume=#{Regexp.escape(trust_store)}:#{Regexp.escape(trust_store)}:ro$}) }
    settings.each do |key, value|
      its('content') { should match(/^Environment=#{key}=#{value}$/) }
    end
  end

  %w[vulcan-pod vulcan-db vulcan].each do |unit|
    describe command("systemctl show -p WantedBy --value #{unit}.service") do
      its('stdout.split') { should include 'multi-user.target' }
    end
  end

  describe file('/etc/safbox/firstboot.d/30-vulcan.sh') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end
end

control 'safbox-vulcan-2' do
  impact 1.0
  title "Vulcan's secrets are generated on first boot, never at build"
  desc "ADR-0001 §Decision: the first-boot hook generates POSTGRES_PASSWORD, SECRET_KEY_BASE, CIPHER_PASSWORD and CIPHER_SALT with the strength of upstream's setup-docker-secrets.sh into #{env_file} (root, 0600), and the database password into #{db_env_file} for the PostgreSQL container. Before first boot (the build VM) neither file exists; the seal also asserts that the template holds no env file."
  only_if('Vulcan is not in expected_services (safbox_services_2 switched off)') do
    service_expected.call('vulcan')
  end

  if deployed
    [env_file, db_env_file].each do |path|
      describe file(path) do
        it { should exist }
        its('owner') { should eq 'root' }
        its('group') { should eq 'root' }
        its('mode') { should cmp '0600' }
      end
    end
    secrets.each do |key, bytes|
      describe "#{env_file} lines setting #{key} to #{bytes} random bytes in hex" do
        subject { command("grep -cE '^#{key}=[0-9a-f]{#{bytes * 2}}$' #{env_file}").stdout.strip }
        it { should eq '1' }
      end
    end
    describe "#{db_env_file} POSTGRES_PASSWORD equal to #{env_file} POSTGRES_PASSWORD" do
      subject do
        command(%(sh -c 'a=$(sed -n "s/^POSTGRES_PASSWORD=//p" #{env_file}); b=$(sed -n "s/^POSTGRES_PASSWORD=//p" #{db_env_file}); [ -n "$a" ] && [ "$a" = "$b" ]')).exit_status
      end
      it { should eq 0 }
    end
  else
    [env_file, db_env_file].each do |path|
      describe file(path) do
        it { should_not exist }
      end
    end
  end
end

control 'safbox-vulcan-3' do
  impact 1.0
  title 'Vulcan runs, reachable only on the loopback address, with FIPS-mode crypto'
  desc "ADR-0001 Quality Standards (security by design): services bind to the proxy, not to all interfaces. The pod publishes Vulcan's port on 127.0.0.1 only, for the TLS proxy; PostgreSQL is published nowhere. Vulcan's Ruby links the image's OpenSSL (Red Hat UBI 9), which runs its FIPS provider under the host's FIPS enforcement. The container has the host's CA trust store mounted read-only and reads it, so it trusts the CAs the host trusts, a site's own included."
  only_if('Vulcan is not in expected_services, or this is not a deployed clone') do
    service_expected.call('vulcan') && input('firstboot_completed_expected')
  end

  %w[vulcan-pod vulcan-db vulcan].each do |unit|
    describe command("systemctl is-active #{unit}.service") do
      its('stdout.strip') { should eq 'active' }
    end
  end

  bindings = command("podman pod inspect vulcan --format '{{json .InfraConfig.PortBindings}}'").stdout
  describe 'Ports the vulcan pod publishes on the host' do
    subject { (JSON.parse(bindings.empty? ? '{}' : bindings) || {}).transform_values { |b| b.map { |x| "#{x['HostIp']}:#{x['HostPort']}" } } }
    it { should eq('3000/tcp' => ["127.0.0.1:#{loopback_port}"]) }
  end

  [loopback_port, 5432].each do |p|
    describe port(p) do
      its('addresses') { should_not include '0.0.0.0' }
      its('addresses') { should_not include '::' }
    end
  end

  # RAILS_FORCE_SSL redirects plain HTTP; the proxy says the client used HTTPS.
  describe command("curl -sS -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' http://127.0.0.1:#{loopback_port}/up") do
    its('stdout') { should eq '200' }
  end

  describe command(%q(podman exec vulcan ruby -ropenssl -e 'print OpenSSL.fips_mode')) do
    its('stdout.strip') { should eq 'true' }
  end

  # The running container has the host's trust store mounted read-only and
  # can read it (SELinux lets containers read the host's certificates,
  # container_read_certs), so the bundle it sees is byte for byte the
  # host's. The image carries a bundle of its own at the same path, so the
  # mount is checked as well as the content.
  describe 'Host paths mounted into the vulcan container' do
    subject { command("podman inspect vulcan --format '{{range .Mounts}}{{.Source}}:{{.Destination}}:{{.RW}} {{end}}'").stdout.split }
    it { should include "#{trust_store}:#{trust_store}:false" }
  end

  describe 'TLS trust bundle inside the vulcan container' do
    subject { command("podman exec vulcan sha256sum #{trust_store}/pem/tls-ca-bundle.pem").stdout.split.first }
    it { should match(/\A[0-9a-f]{64}\z/) }
    it { should eq command("sha256sum #{trust_store}/pem/tls-ca-bundle.pem").stdout.split.first }
  end

  describe command('runuser -u nobody -- /usr/local/bin/safbox status') do
    its('stdout') { should match(/^Vulcan:\s+active$/) }
  end
end

control 'safbox-vulcan-4' do
  impact 0.3
  title "Vulcan's PostgreSQL container carries an OpenSSL FIPS provider"
  desc 'The upstream postgres image (Alpine) carries an OpenSSL with no FIPS provider, so PostgreSQL (SCRAM-SHA-256 password authentication, pgcrypto) does not use FIPS-validated crypto although the host enforces FIPS. Recorded as a low-severity finding; it is never waived.'
  tag finding: "Vulcan's PostgreSQL image has no OpenSSL FIPS provider"
  only_if('Vulcan is not in expected_services, or this is not a deployed clone') do
    service_expected.call('vulcan') && input('firstboot_completed_expected')
  end

  describe 'OpenSSL FIPS provider modules in the vulcan-db container' do
    subject { command(%q(podman exec vulcan-db find / -xdev -name fips.so -path '*ossl-modules*')).stdout.strip }
    it { should_not be_empty }
  end
end
