# frozen_string_literal: true

# The TLS proxy (the proxy role, task group safbox-proxy-1): one nginx
# Quadlet container from a pinned upstream image that terminates TLS for
# each application on its own HTTPS port and serves the landing page on
# 443, with a certificate generated on first boot. The landing page shows
# each service's status from small files a systemd timer regenerates from
# `safbox services`. The build-time gate checks the units, the configuration
# and the absence of a certificate; the release gate (a deployed clone)
# checks TLS on each port and the landing page. The firewall that opens the
# proxy's ports is checked by safbox-firewall-1.

service_expected = ->(service) { input('expected_services').map(&:to_s).include?(service) }
deployed = input('firstboot_completed_expected')
# InSpec gives the nested keys of a Hash input from inspec.yml as symbols (an
# inputs file may give strings), so normalise them.
proxy_image = input('service_images')['proxy'].transform_keys(&:to_s)
image = "#{proxy_image['name']}@#{proxy_image['digest']}"
proxy_ports = input('proxy_ports').transform_keys(&:to_s)
landing_port = proxy_ports['landing']
apps = %w[heimdall vulcan].select { |app| service_expected.call(app) }
tls_dir = '/etc/safbox/tls'
cert = "#{tls_dir}/safbox.crt"
key = "#{tls_dir}/safbox.key"
nginx_conf = '/etc/safbox-proxy/nginx.conf'
landing_dir = '/etc/safbox-proxy/landing'
status_dir = '/run/safbox-landing'
status_unit = 'safbox-landing-status'
# The status timer runs every 30 seconds; a status file older than three
# intervals means the timer has stopped.
status_max_age = 90
labels = { 'heimdall' => 'Heimdall', 'vulcan' => 'Vulcan', 'proxy' => 'TLS proxy and landing page' }

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
  title 'The TLS proxy Quadlet unit, its configuration and the landing page are installed and enabled'
  desc "An nginx container from a pinned upstream image (Red Hat UBI 9, whose OpenSSL runs its FIPS provider under the host's FIPS enforcement) on the host network, terminating TLS for each application on its own HTTPS port and serving the landing page on #{landing_port}, with nothing on port 80. Cipher selection defers to the system crypto policy (PROFILE=SYSTEM), which podman maps into the container from the FIPS host. The unit waits for the certificate first boot generates. The landing page's status files are written by a sandboxed oneshot service without capabilities, run by an enabled timer."
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
    # The workers' user switch, and binding the landing page's port below 1024.
    its('content') { should match(/^AddCapability=CAP_CHOWN CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID$/) }
    its('content') { should match(/^Memory=\d+[kmg]?$/i) }
    its('content') { should match(%r{^ConditionPathExists=#{Regexp.escape(key)}$}) }
    its('content') { should match(%r{^Volume=#{Regexp.escape(status_dir)}:/etc/nginx/safbox-landing-status:ro,z$}) }
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
    its('content') { should_not match(/^\s*listen\s+(\S+:)?80[\s;]/) }
    its('content') { should match(/^\s*listen #{landing_port} ssl;$/) }
    its('content') { should match(/^\s*ssi on;$/) }
  end

  # The landing page: the static files the proxy role renders, the generator
  # of the status files the page includes, and the timer that runs it.
  %w[index.html safbox.css].each do |name|
    describe file("#{landing_dir}/#{name}") do
      it { should exist }
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0644' }
    end
  end

  describe file("/usr/local/sbin/#{status_unit}") do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end

  describe file('/etc/tmpfiles.d/safbox-landing.conf') do
    its('content') { should match(%r{^d #{Regexp.escape(status_dir)} 0755 root root -$}) }
  end

  describe file("/etc/systemd/system/#{status_unit}.service") do
    its('content') { should match(%r{^ExecStart=/usr/local/sbin/#{status_unit}$}) }
    its('content') { should match(/^CapabilityBoundingSet=$/) }
    its('content') { should match(/^NoNewPrivileges=yes$/) }
    its('content') { should match(/^ProtectSystem=strict$/) }
    its('content') { should match(%r{^ReadWritePaths=#{Regexp.escape(status_dir)}$}) }
  end

  describe command("systemctl show -p WantedBy --value #{status_unit}.timer") do
    its('stdout.split') { should include 'timers.target' }
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

control 'safbox-proxy-7' do
  impact 1.0
  title 'The landing page on port 443 shows the status of each service and links to the applications, and no secret'
  desc "ADR-0001 Phase 8: an HTTPS landing page on #{landing_port} shows service status and links. nginx assembles it with server-side includes from a page the proxy role renders and one status file per service, which the #{status_unit} timer regenerates every 30 seconds from safbox services; each link names the host the browser asked for. The page carries a Content-Security-Policy that allows only its own stylesheet, the status files are reachable only through the page, and the page holds nothing secret: no first-boot secret value appears in it."
  only_if('the proxy is not in expected_services, or this is not a deployed clone') do
    service_expected.call('proxy') && input('firstboot_completed_expected')
  end

  instance_exec(landing_port, '/', &tls_port)

  page = command("curl -sS -k https://127.0.0.1:#{landing_port}/").stdout
  apps.each do |app|
    describe "Landing page link to #{labels[app]}" do
      subject { page }
      it { should include %(href="https://127.0.0.1:#{proxy_ports[app]}/") }
    end
  end
  (apps + ['proxy']).each do |service|
    describe "Landing page status of #{labels[service]}" do
      subject { page[%r{<tr id="service-#{service}">.*?</tr>}m].to_s }
      it { should include %(<th scope="row">#{labels[service]}</th>) }
      it { should include '<span class="state state-running">Running</span>' }
    end
  end

  describe "Age in seconds of the landing page's status (#{status_dir}/updated)" do
    subject { command(%(sh -c 'echo $(( $(date +%s) - $(stat -c %Y #{status_dir}/updated) ))')).stdout.strip.to_i }
    it { should be <= status_max_age }
  end

  describe command("systemctl is-active #{status_unit}.timer") do
    its('stdout.strip') { should eq 'active' }
  end

  headers = command("curl -sS -k -D - -o /dev/null https://127.0.0.1:#{landing_port}/").stdout.downcase
  describe 'Landing page response headers' do
    subject { headers }
    it { should match(/^content-security-policy: default-src 'none'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r?$/) }
    it { should match(/^x-content-type-options: nosniff\r?$/) }
    it { should match(/^x-frame-options: deny\r?$/) }
    it { should match(/^referrer-policy: no-referrer\r?$/) }
    it { should match(/^cache-control: no-store\r?$/) }
    it { should match(/^server: nginx\r?$/) }
  end

  # The status files and the configuration are not served on their own; a
  # path above the page's root is refused outright.
  { '/status/proxy' => '404', '/status/updated' => '404', '/nginx.conf' => '404', '/../nginx.conf' => '400' }.each do |path, code|
    describe command("curl -sS -k --path-as-is -o /dev/null -w '%{http_code}' https://127.0.0.1:#{landing_port}#{path}") do
      its('stdout') { should eq code }
    end
  end

  # The host a link names comes from the request, so markup in it must
  # arrive escaped.
  describe command(%(curl -sS -k -H 'Host: safbox"><b>x' https://127.0.0.1:#{landing_port}/)) do
    its('stdout') { should include 'https://safbox&quot;&gt;&lt;b&gt;x:' }
    its('stdout') { should_not include '"><b>x' }
  end

  describe command("curl -sS -k -X POST -o /dev/null -w '%{http_code}' https://127.0.0.1:#{landing_port}/") do
    its('stdout') { should eq '405' }
  end

  # Names (never values) of the first-boot secrets whose value appears in the
  # page. The page is fetched and compared on the box, so no secret value
  # reaches the results.
  leak_check = %{sh -c 'page=$(curl -sS -k https://127.0.0.1:#{landing_port}/); for f in /etc/safbox/*.env; do while IFS== read -r k v; do if [ -n "$v" ]; then case "$page" in *"$v"*) echo "$f:$k" ;; esac; fi; done < "$f"; done; case "$page" in *"PRIVATE KEY"*) echo private-key ;; esac'}
  describe 'First-boot secrets that appear in the landing page' do
    subject { command(leak_check).stdout.split }
    it { should be_empty }
  end
end
