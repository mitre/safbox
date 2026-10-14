# frozen_string_literal: true

# The TLS proxy (the proxy role, task group safbox-proxy-1): one nginx
# Quadlet container from a pinned upstream image that terminates TLS for
# each application on its own HTTPS port, with a certificate generated on
# first boot. 443 stays free for the Phase 8 landing page. The build-time
# gate checks the unit, its configuration, the firewall and the absence of a
# certificate; the release gate (a deployed clone) checks TLS on each port.

service_expected = ->(service) { input('expected_services').map(&:to_s).include?(service) }
deployed = input('firstboot_completed_expected')
# InSpec gives the nested keys of a Hash input from inspec.yml as symbols (an
# inputs file may give strings), so normalise them.
proxy_image = input('service_images')['proxy'].transform_keys(&:to_s)
image = "#{proxy_image['name']}@#{proxy_image['digest']}"
proxy_ports = input('proxy_ports')
apps = %w[heimdall vulcan].select { |app| service_expected.call(app) }
tls_dir = '/etc/safbox/tls'
cert = "#{tls_dir}/safbox.crt"
key = "#{tls_dir}/safbox.key"
nginx_conf = '/etc/safbox-proxy/nginx.conf'

# TLS on one application's port, from the box itself: the handshake
# negotiates TLS 1.3 with an AES-GCM suite (the FIPS policy allows no
# ChaCha20), and the certificate served verifies against the one first boot
# generated as the only trust anchor, for the address connected to; and the
# application answers through the proxy.
tls_port = lambda do |port, path|
  handshake = command("sh -c 'openssl s_client -connect 127.0.0.1:#{port} -CAfile #{cert} -verify_return_error -verify_ip 127.0.0.1 -brief </dev/null 2>&1'").stdout
  describe "TLS handshake with the proxy on port #{port}" do
    subject { handshake }
    it { should match(/^Protocol version: TLSv1\.3$/) }
    it { should match(/^Ciphersuite: TLS_AES_(128|256)_GCM_SHA(256|384)$/) }
    it { should match(/^Verification: OK$/) }
  end

  describe command("curl -sS -k -o /dev/null -w '%{http_code}' https://127.0.0.1:#{port}#{path}") do
    its('stdout') { should eq '200' }
  end
end

control 'safbox-proxy-1' do
  impact 1.0
  title 'The TLS proxy Quadlet unit and configuration are installed and enabled'
  desc "An nginx container from a pinned upstream image (Red Hat UBI 9, whose OpenSSL runs its FIPS provider under the host's FIPS enforcement) on the host network, terminating TLS for each application on its own HTTPS port. Cipher selection defers to the system crypto policy (PROFILE=SYSTEM), which podman maps into the container from the FIPS host. The unit waits for the certificate first boot generates."
  only_if('the proxy is not in expected_services (safbox_proxy_1 switched off)') do
    service_expected.call('proxy')
  end

  describe file('/etc/containers/systemd/safbox-proxy.container') do
    it { should exist }
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0644' }
    its('content') { should match(/^Image=#{Regexp.escape(image)}$/) }
    its('content') { should match(/^Network=host$/) }
    its('content') { should match(/^ReadOnly=true$/) }
    its('content') { should match(/^NoNewPrivileges=true$/) }
    its('content') { should match(/^DropCapability=all$/) }
    its('content') { should match(/^Memory=\d+[kmg]?$/i) }
    its('content') { should match(%r{^ConditionPathExists=#{Regexp.escape(key)}$}) }
  end

  describe command("podman image exists #{image}") do
    its('exit_status') { should eq 0 }
  end

  describe command('systemctl show -p Restart --value safbox-proxy.service') do
    its('stdout.strip') { should eq 'always' }
  end

  describe command('systemctl show -p WantedBy --value safbox-proxy.service') do
    its('stdout.split') { should include 'multi-user.target' }
  end

  describe file(nginx_conf) do
    it { should exist }
    its('owner') { should eq 'root' }
    its('content') { should match(/^\s*ssl_ciphers PROFILE=SYSTEM;$/) }
    its('content') { should match(/^\s*ssl_protocols TLSv1\.2 TLSv1\.3;$/) }
    its('content') { should_not match(/^\s*listen\s+(\S+:)?(80|443)[\s;]/) }
  end

  apps.each do |app|
    describe "#{nginx_conf} listener for #{app}" do
      subject { file(nginx_conf).content }
      it { should match(/^\s*listen #{proxy_ports[app]} ssl;$/) }
    end
  end

  describe file('/etc/safbox/firstboot.d/40-proxy.sh') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end
end

control 'safbox-proxy-2' do
  impact 1.0
  title 'The proxy serves TLS on the Heimdall port'
  desc 'Heimdall is reachable only over HTTPS through the proxy, on its own port, so credentials never cross the network unencrypted.'
  only_if('the proxy or Heimdall is not in expected_services, or this is not a deployed clone') do
    service_expected.call('proxy') && service_expected.call('heimdall') && input('firstboot_completed_expected')
  end

  instance_exec(proxy_ports['heimdall'], '/', &tls_port)
end

control 'safbox-proxy-3' do
  impact 1.0
  title 'The proxy serves TLS on the Vulcan port'
  desc 'Vulcan is reachable only over HTTPS through the proxy, on its own port, so credentials never cross the network unencrypted.'
  only_if('the proxy or Vulcan is not in expected_services, or this is not a deployed clone') do
    service_expected.call('proxy') && service_expected.call('vulcan') && input('firstboot_completed_expected')
  end

  instance_exec(proxy_ports['vulcan'], '/users/sign_in', &tls_port)
end

control 'safbox-proxy-4' do
  impact 1.0
  title "The proxy's certificate is generated on first boot, never at build"
  desc "ADR-0001 §Decision: first boot mints a self-signed certificate into #{tls_dir}, the key readable by root only. Before first boot (the build VM) there is none; the seal also asserts the template holds none. A consumer replaces both files with their own certificate and key."
  only_if('the proxy is not in expected_services (safbox_proxy_1 switched off)') do
    service_expected.call('proxy')
  end

  if deployed
    describe directory(tls_dir) do
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0700' }
    end
    describe file(key) do
      it { should exist }
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0600' }
    end
    describe file(cert) do
      it { should exist }
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0644' }
    end
    describe command("openssl x509 -in #{cert} -noout -checkend 0") do
      its('exit_status') { should eq 0 }
    end
    describe "#{key} is the key of #{cert}" do
      subject do
        command(%(sh -c 'a=$(openssl pkey -in #{key} -pubout); b=$(openssl x509 -in #{cert} -noout -pubkey); [ -n "$a" ] && [ "$a" = "$b" ]')).exit_status
      end
      it { should eq 0 }
    end
  else
    [key, cert].each do |path|
      describe file(path) do
        it { should_not exist }
      end
    end
  end
end

control 'safbox-proxy-5' do
  impact 1.0
  title 'The firewall opens exactly the proxy ports'
  desc 'ADR-0001 Quality Standards: the firewall opens no port beyond the proxy ports. Every open port in the default zone, at runtime and permanently, is a proxy port of an application this image ships. The applications themselves listen on the loopback address only.'
  only_if('the proxy is not in expected_services (safbox_proxy_1 switched off)') do
    service_expected.call('proxy')
  end

  want = apps.map { |app| "#{proxy_ports[app]}/tcp" }.sort
  { 'runtime' => 'firewall-cmd --list-ports', 'permanent' => 'firewall-cmd --permanent --list-ports' }.each do |label, cmd|
    describe "Open ports in the default zone (#{label})" do
      subject { command(cmd).stdout.split.sort }
      it { should eq want }
    end
  end
end

control 'safbox-proxy-6' do
  impact 1.0
  title "The proxy's TLS stack runs the OpenSSL FIPS provider under the FIPS crypto policy"
  desc "nginx in the pinned image links the image's OpenSSL, which loads its FIPS provider on a FIPS host, and podman gives the container the FIPS system crypto policy, which ssl_ciphers PROFILE=SYSTEM follows: TLS 1.2 or later, no ChaCha20, approved groups and signatures only."
  only_if('the proxy is not in expected_services, or this is not a deployed clone') do
    service_expected.call('proxy') && input('firstboot_completed_expected')
  end

  describe command('podman exec safbox-proxy openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n\s+version: .*\n\s+status: active$/) }
  end

  describe command('podman exec safbox-proxy cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end

  describe command('runuser -u nobody -- /usr/local/bin/safbox status') do
    its('stdout') { should match(/^TLS proxy:\s+active$/) }
  end
end
