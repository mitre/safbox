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
quadlet = '/etc/containers/systemd'
trust_store = '/etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro'
pinned = /@sha256:\h{64}$/

control 'safbox-heimdall-1' do
  impact 1.0
  title 'The Heimdall Quadlet units are installed'
  desc 'Heimdall and its database run from images pinned by digest, with memory limits, no new privileges and the host CA trust store mounted read-only. The pod publishes 127.0.0.1:3000 only and waits for first boot to write its secrets.'
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  describe parse_config_file("#{quadlet}/heimdall.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3000:3000'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/heimdall.env'] }
  end
  describe parse_config_file("#{quadlet}/heimdall.container", multiple_values: true) do
    its('Container.Image') { should all match(pinned) }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Volume') { should include trust_store }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/heimdall-db.container", multiple_values: true) do
    its('Container.Image') { should all match(pinned) }
    its('Container.Memory') { should_not be_empty }
  end
end

control 'safbox-heimdall-2' do
  impact 1.0
  title "Heimdall's secrets exist only after first boot, readable by root only"
  desc 'First boot writes the database password, JWT secret and API key secret. The template and the build VM hold none.'
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  %w[/etc/safbox/heimdall.env /etc/safbox/heimdall-db.env].each do |path|
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
  title "Heimdall's PostgreSQL container has an OpenSSL FIPS provider"
  desc 'PostgreSQL password authentication and pgcrypto use the OpenSSL in its container, which needs a FIPS provider for FIPS-validated crypto.'
  only_if('Heimdall is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('heimdall') && deployed }

  describe command('podman exec heimdall-db find / -xdev -name fips.so') do
    its('stdout') { should match(/fips\.so$/) }
  end
end

control 'safbox-vulcan-1' do
  impact 1.0
  title 'The Vulcan Quadlet units are installed'
  desc 'Vulcan and its database run from images pinned by digest, with memory limits, no new privileges and the host CA trust store mounted read-only. The pod publishes 127.0.0.1:3001 only and waits for first boot to write its secrets. Local login and registration are on and the first user is admin.'
  only_if('Vulcan is switched off', impact: 0.0) { services.include?('vulcan') }

  describe parse_config_file("#{quadlet}/vulcan.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3001:3000'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/vulcan.env'] }
  end
  describe parse_config_file("#{quadlet}/vulcan.container", multiple_values: true) do
    its('Container.Image') { should all match(pinned) }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Volume') { should include trust_store }
    its('Container.Environment') { should include 'VULCAN_ENABLE_LOCAL_LOGIN=true' }
    its('Container.Environment') { should include 'VULCAN_ENABLE_USER_REGISTRATION=true' }
    its('Container.Environment') { should include 'VULCAN_FIRST_USER_ADMIN=true' }
    its('Container.Environment') { should include 'RAILS_FORCE_SSL=true' }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/vulcan-db.container", multiple_values: true) do
    its('Container.Image') { should all match(pinned) }
    its('Container.Memory') { should_not be_empty }
  end
end

control 'safbox-vulcan-2' do
  impact 1.0
  title "Vulcan's secrets exist only after first boot, readable by root only"
  desc 'First boot writes the database password, Rails secret key base and cipher password and salt. The template and the build VM hold none.'
  only_if('Vulcan is switched off', impact: 0.0) { services.include?('vulcan') }

  %w[/etc/safbox/vulcan.env /etc/safbox/vulcan-db.env].each do |path|
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
  title "Vulcan's PostgreSQL container has an OpenSSL FIPS provider"
  desc 'PostgreSQL password authentication and pgcrypto use the OpenSSL in its container, which needs a FIPS provider for FIPS-validated crypto.'
  only_if('Vulcan is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('vulcan') && deployed }

  describe command('podman exec vulcan-db find / -xdev -name fips.so') do
    its('stdout') { should match(/fips\.so$/) }
  end
end

control 'safbox-proxy-1' do
  impact 1.0
  title 'The TLS proxy unit and its nginx configuration are installed'
  desc 'An nginx container from a Red Hat UBI 9 image pinned by digest terminates TLS for each application on its own port, with ciphers from the system crypto policy, TLS 1.2 or later, and nothing on ports 80 or 443.'
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
    its('content') { should_not match(/^\s*listen\s+(\S+:)?(80|443)[\s;]/) }
  end
end

control 'safbox-proxy-2' do
  impact 1.0
  title 'Heimdall is served over HTTPS on port 8443'
  desc 'Heimdall is reachable from the network only through the proxy.'
  only_if('The proxy or Heimdall is switched off, or this is not a deployed clone', impact: 0.0) do
    services.include?('proxy') && services.include?('heimdall') && deployed
  end

  describe http('https://127.0.0.1:8443/', ssl_verify: false) do
    its('status') { should eq 200 }
  end
end

control 'safbox-proxy-3' do
  impact 1.0
  title 'Vulcan is served over HTTPS on port 9443'
  desc 'Vulcan is reachable from the network only through the proxy.'
  only_if('The proxy or Vulcan is switched off, or this is not a deployed clone', impact: 0.0) do
    services.include?('proxy') && services.include?('vulcan') && deployed
  end

  describe http('https://127.0.0.1:9443/users/sign_in', ssl_verify: false) do
    its('status') { should eq 200 }
  end
end

control 'safbox-proxy-4' do
  impact 1.0
  title "The proxy's certificate is generated on first boot, its key readable by root only"
  desc 'First boot writes a self-signed certificate for the host. The template and the build VM hold none; a site may replace both files with its own.'
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  if deployed
    describe file('/etc/safbox/tls/safbox.key') do
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0600' }
    end
    describe x509_certificate('/etc/safbox/tls/safbox.crt') do
      its('validity_in_days') { should be > 0 }
    end
  else
    describe file('/etc/safbox/tls/safbox.key') do
      it { should_not exist }
    end
  end
end

control 'safbox-proxy-5' do
  impact 1.0
  title 'The firewall opens exactly the HTTPS ports of the shipped applications'
  desc 'Apart from the services firewalld allows by name, only the proxy ports are open.'
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  ports = { 'heimdall' => '8443/tcp', 'vulcan' => '9443/tcp' }.select { |app, _| services.include?(app) }.values
  describe command('firewall-cmd --list-ports') do
    its('stdout.split') { should match_array ports }
  end
end

control 'safbox-proxy-6' do
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
