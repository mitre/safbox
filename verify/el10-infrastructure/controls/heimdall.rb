# frozen_string_literal: true

# Heimdall and its PostgreSQL as Quadlet units (ADR-0001 Phase 5; the heimdall
# role, task group safbox-heimdall-1). The units are installed and enabled
# at build but start only once first boot has written their secrets, so the
# build-time gate checks the units and the absence of secrets, and the
# release gate (a deployed clone) checks the running pod.
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
loopback_port = input('loopback_ports')['heimdall']
quadlet_dir = '/etc/containers/systemd'
env_file = '/etc/safbox/heimdall.env'
db_env_file = '/etc/safbox/heimdall-db.env'
# Secret name to the number of random bytes upstream's setup-docker-env.sh
# draws (openssl rand -hex <bytes>), so the hex value is twice as long.
secrets = { 'DATABASE_PASSWORD' => 33, 'JWT_SECRET' => 64, 'API_KEY_SECRET' => 33 }

control 'safbox-heimdall-1' do
  impact 1.0
  title 'Heimdall Quadlet units are installed and enabled'
  desc 'ADR-0001 Phase 5: Heimdall and its PostgreSQL run as a systemd-managed podman pod built from the upstream images and the service shape of Heimdall\'s docker-compose.yml, with pinned images, memory limits, a restart policy and a named volume for data. The units wait for first boot: each needs the env file the first-boot hook writes.'
  only_if('Heimdall is not in expected_services (safbox_heimdall_1 switched off)') do
    service_expected.call('heimdall')
  end

  %w[heimdall.network heimdall.pod heimdall-db.volume heimdall-db.container heimdall.container].each do |unit|
    describe file("#{quadlet_dir}/#{unit}") do
      it { should exist }
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0644' }
    end
  end

  { 'heimdall' => image_ref.call('heimdall'), 'heimdall-db' => image_ref.call('heimdall_db') }.each do |name, image|
    describe file("#{quadlet_dir}/#{name}.container") do
      its('content') { should match(/^Image=#{Regexp.escape(image)}$/) }
      its('content') { should match(/^Pod=heimdall\.pod$/) }
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

  describe file("#{quadlet_dir}/heimdall.pod") do
    its('content') { should match(/^PublishPort=127\.0\.0\.1:#{loopback_port}:3000$/) }
    its('content') { should match(/^Network=heimdall\.network$/) }
    its('content') { should match(%r{^ConditionPathExists=#{Regexp.escape(env_file)}$}) }
  end

  describe file("#{quadlet_dir}/heimdall-db.container") do
    its('content') { should match(/^Volume=heimdall-db\.volume:/) }
    its('content') { should match(%r{^EnvironmentFile=#{Regexp.escape(db_env_file)}$}) }
  end

  describe file("#{quadlet_dir}/heimdall.container") do
    its('content') { should match(%r{^EnvironmentFile=#{Regexp.escape(env_file)}$}) }
    its('content') { should match(/^DropCapability=all$/) }
  end

  %w[heimdall-pod heimdall-db heimdall].each do |unit|
    describe command("systemctl show -p WantedBy --value #{unit}.service") do
      its('stdout.split') { should include 'multi-user.target' }
    end
  end

  describe file('/etc/safbox/firstboot.d/20-heimdall.sh') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end
end

control 'safbox-heimdall-2' do
  impact 1.0
  title "Heimdall's secrets are generated on first boot, never at build"
  desc "ADR-0001 §Decision: the first-boot hook generates DATABASE_PASSWORD, JWT_SECRET and API_KEY_SECRET with the strength of upstream's setup-docker-env.sh into #{env_file} (root, 0600), and the database password into #{db_env_file} for the PostgreSQL container. Before first boot (the build VM) neither file exists; the seal also asserts that the template holds no env file."
  only_if('Heimdall is not in expected_services (safbox_heimdall_1 switched off)') do
    service_expected.call('heimdall')
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
    describe "#{db_env_file} POSTGRES_PASSWORD equal to #{env_file} DATABASE_PASSWORD" do
      subject do
        command(%(sh -c 'a=$(sed -n "s/^DATABASE_PASSWORD=//p" #{env_file}); b=$(sed -n "s/^POSTGRES_PASSWORD=//p" #{db_env_file}); [ -n "$a" ] && [ "$a" = "$b" ]')).exit_status
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

control 'safbox-heimdall-3' do
  impact 1.0
  title 'Heimdall runs, reachable only on the loopback address, with FIPS-mode crypto'
  desc "ADR-0001 Quality Standards (security by design): services bind to the proxy, not to all interfaces. The pod publishes Heimdall's port on 127.0.0.1 only, for the TLS proxy; PostgreSQL is published nowhere. Heimdall's own OpenSSL (Red Hat UBI 9) runs its FIPS provider under the host's FIPS enforcement, so Node.js crypto is FIPS-mode."
  only_if('Heimdall is not in expected_services, or this is not a deployed clone') do
    service_expected.call('heimdall') && input('firstboot_completed_expected')
  end

  %w[heimdall-pod heimdall-db heimdall].each do |unit|
    describe command("systemctl is-active #{unit}.service") do
      its('stdout.strip') { should eq 'active' }
    end
  end

  bindings = command("podman pod inspect heimdall --format '{{json .InfraConfig.PortBindings}}'").stdout
  describe 'Ports the heimdall pod publishes on the host' do
    subject { (JSON.parse(bindings.empty? ? '{}' : bindings) || {}).transform_values { |b| b.map { |x| "#{x['HostIp']}:#{x['HostPort']}" } } }
    it { should eq('3000/tcp' => ["127.0.0.1:#{loopback_port}"]) }
  end

  [loopback_port, 5432].each do |p|
    describe port(p) do
      its('addresses') { should_not include '0.0.0.0' }
      its('addresses') { should_not include '::' }
    end
  end

  describe command("curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:#{loopback_port}/") do
    its('stdout') { should eq '200' }
  end

  describe command(%q(podman exec heimdall node -p "require('crypto').getFips()")) do
    its('stdout.strip') { should eq '1' }
  end

  describe command('runuser -u nobody -- /usr/local/bin/safbox status') do
    its('stdout') { should match(/^Heimdall:\s+active$/) }
  end
end

control 'safbox-heimdall-4' do
  impact 0.3
  title 'Heimdall hashes local account passwords with a FIPS-approved algorithm'
  desc "Heimdall stores local account passwords as bcrypt hashes made by bcryptjs, a pure JavaScript implementation outside the container's OpenSSL FIPS provider; bcrypt is not FIPS-approved. Every SAFBox with Heimdall has such a hash, because Heimdall seeds an administrator at first start. Heimdall's source hashes API keys the same way (upstream mitre/heimdall2#4145); this control observes passwords only, since a fresh box has no API keys. Recorded as a low-severity finding; it is never waived."
  tag finding: 'Heimdall password hashing (bcryptjs) bypasses the FIPS provider'
  only_if('Heimdall is not in expected_services, or this is not a deployed clone') do
    service_expected.call('heimdall') && input('firstboot_completed_expected')
  end

  # bcrypt hashes start with $2 (modular crypt format).
  bcrypt_accounts = %q(podman exec heimdall-db psql -U postgres -d heimdall-server-production -tAc "SELECT count(*) FROM \"Users\" WHERE \"encryptedPassword\" LIKE '\$2%'")
  describe 'Heimdall accounts whose password is a bcrypt hash' do
    subject { command(bcrypt_accounts).stdout.strip }
    it { should eq '0' }
  end
end

control 'safbox-heimdall-5' do
  impact 0.3
  title "Heimdall's PostgreSQL container carries an OpenSSL FIPS provider"
  desc 'The upstream postgres image (Debian) carries an OpenSSL with no FIPS provider, so PostgreSQL (SCRAM-SHA-256 password authentication, pgcrypto) does not use FIPS-validated crypto although the host enforces FIPS. Recorded as a low-severity finding; it is never waived.'
  tag finding: "Heimdall's PostgreSQL image has no OpenSSL FIPS provider"
  only_if('Heimdall is not in expected_services, or this is not a deployed clone') do
    service_expected.call('heimdall') && input('firstboot_completed_expected')
  end

  describe 'OpenSSL FIPS provider modules in the heimdall-db container' do
    subject { command(%q(podman exec heimdall-db find / -xdev -name fips.so -path '*ossl-modules*')).stdout.strip }
    it { should_not be_empty }
  end
end
