# frozen_string_literal: true

# Heimdall, Vulcan and Keycloak each run as a podman pod (the application
# and its PostgreSQL) on the loopback address, behind one nginx TLS proxy.
# The units are installed at build and start once first boot has made their
# secrets, so the build VM has units and no secrets, and a deployed clone
# has both and runs them. A secret's value is only ever read into a pipe on
# the box (grep's pattern file), and only counts reach the results.

services = input('expected_services')
deployed = input('deployed')
domain = input('domain')
quadlet = '/etc/containers/systemd'
pinned = /@sha256:\h{64}$/
# The names the proxy serves besides the domain, one per application.
served_apps = %w[heimdall vulcan keycloak]

control 'safbox-secrets-1' do
  impact 1.0
  title "No service secret is in an env file, a container's visible settings or the journal, and the template holds none"
  desc "First boot makes each service's secrets (database and administrator passwords, signing keys, client secrets) as podman secrets in the root-only secret store, and each container receives them as environment variables that podman inspect masks. No env file under /etc/safbox holds one (safuser's generated OS password, in safuser.env, is the one plaintext secret there), no container shows one unmasked, this boot's journal holds no secret's value, and Keycloak's realm file holds placeholders only. The build VM, and so the template, holds no podman secret."
  only_if('Heimdall, Vulcan and Keycloak are switched off', impact: 0.0) { (services & served_apps).any? }

  describe command("find /etc/safbox -maxdepth 1 -name '*.env' ! -name safuser.env -print") do
    its('stdout') { should eq '' }
  end
  if services.include?('keycloak')
    describe file('/etc/safbox-keycloak/safbox-realm.json') do
      its('content') { should_not match(/"(secret|value)": "(?!\$\{)/) }
    end
  end
  if deployed
    describe file('/var/lib/containers/storage/secrets/filedriver/secretsdata.json') do
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0600' }
    end
    # Every secret's value, one per line, as grep's pattern file.
    values = '<(podman secret ls --noheading --format "{{.Name}}" | xargs -r -n1 podman secret inspect --showsecret --format "{{.SecretData}}" | grep .)'
    describe "Lines of the running containers' podman inspect holding a secret's value" do
      subject { command(%(bash -c 'podman ps -q | xargs -r podman inspect | grep -cF -f #{values}')).stdout.strip }
      it { should cmp 0 }
    end
    describe "Lines of this boot's journal holding a secret's value" do
      subject { command(%(bash -c 'journalctl -b --no-pager -o cat | grep -cF -f #{values}')).stdout.strip }
      it { should cmp 0 }
    end
  else
    describe command('podman secret ls --quiet') do
      its('stdout') { should eq '' }
    end
  end
end

control 'safbox-heimdall-1' do
  impact 1.0
  title 'Heimdall runs from pinned images, starts at boot and answers on the loopback address only'
  desc 'Heimdall and its PostgreSQL run from images pinned by digest and start at boot. The pod publishes 127.0.0.1:3000 only, so Heimdall is reached through the proxy, and on a deployed clone both containers run and Heimdall answers there.'
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  describe parse_config_file("#{quadlet}/heimdall.pod") do
    its('Pod.PublishPort') { should eq '127.0.0.1:3000:3000' }
  end
  %w[heimdall heimdall-db].each do |name|
    describe parse_config_file("#{quadlet}/#{name}.container") do
      its('Container.Image') { should match pinned }
      its('Install.WantedBy') { should eq 'multi-user.target' }
    end
    next unless deployed

    describe service(name) do
      it { should be_running }
    end
  end
  if deployed
    describe port(3000) do
      its('addresses') { should eq ['127.0.0.1'] }
    end
    describe http('http://127.0.0.1:3000/') do
      its('status') { should eq 200 }
    end
  end
end

control 'safbox-vulcan-1' do
  impact 1.0
  title 'Vulcan runs from pinned images, starts at boot and answers on the loopback address only'
  desc 'Vulcan and its PostgreSQL run from images pinned by digest and start at boot. The pod publishes 127.0.0.1:3001 only, so Vulcan is reached through the proxy, and on a deployed clone both containers run and Vulcan answers there.'
  only_if('Vulcan is switched off', impact: 0.0) { services.include?('vulcan') }

  describe parse_config_file("#{quadlet}/vulcan.pod") do
    its('Pod.PublishPort') { should eq '127.0.0.1:3001:3000' }
  end
  %w[vulcan vulcan-db].each do |name|
    describe parse_config_file("#{quadlet}/#{name}.container") do
      its('Container.Image') { should match pinned }
      its('Install.WantedBy') { should eq 'multi-user.target' }
    end
    next unless deployed

    describe service(name) do
      it { should be_running }
    end
  end
  if deployed
    describe port(3001) do
      its('addresses') { should eq ['127.0.0.1'] }
    end
    # Vulcan redirects plain HTTP unless the proxy says the client used HTTPS.
    describe http('http://127.0.0.1:3001/up', headers: { 'X-Forwarded-Proto' => 'https' }) do
      its('status') { should eq 200 }
    end
  end
end

control 'safbox-keycloak-1' do
  impact 1.0
  title 'Keycloak runs from its FIPS image built on a pinned base, starts at boot and answers on the loopback address only'
  desc "Keycloak runs from the image the build makes on the template from Keycloak's image pinned by digest, and its PostgreSQL from an image pinned by digest; both start at boot. The pod publishes 127.0.0.1:3002 only, so Keycloak is reached through the proxy, and on a deployed clone both containers run and Keycloak serves the safbox realm there."
  only_if('Keycloak is switched off', impact: 0.0) { services.include?('keycloak') }

  describe file('/etc/safbox-keycloak/Containerfile') do
    its('content') { should match(%r{^FROM quay\.io/keycloak/keycloak@sha256:\h{64}( AS builder)?$}) }
    its('content') { should_not match(%r{^FROM (?!quay\.io/keycloak/keycloak@sha256:\h{64})}) }
  end
  describe parse_config_file("#{quadlet}/keycloak.pod") do
    its('Pod.PublishPort') { should eq '127.0.0.1:3002:8080' }
  end
  { 'keycloak' => %r{^localhost/safbox-keycloak-fips:}, 'keycloak-db' => pinned }.each do |name, image|
    describe parse_config_file("#{quadlet}/#{name}.container") do
      its('Container.Image') { should match image }
      its('Install.WantedBy') { should eq 'multi-user.target' }
    end
    next unless deployed

    describe service(name) do
      it { should be_running }
    end
  end
  if deployed
    describe port(3002) do
      its('addresses') { should eq ['127.0.0.1'] }
    end
    describe http('http://127.0.0.1:3002/realms/safbox/.well-known/openid-configuration') do
      its('status') { should eq 200 }
    end
  end
end

control 'safbox-keycloak-2' do
  impact 1.0
  title "Keycloak's administration console and master realm answer to the box itself only"
  desc "Keycloak's reverse-proxy guide advises against exposing /admin/ and the master realm. The proxy serves them to requests from the box's own address and refuses every other client; the safbox realm, which the applications and browsers use, is served to all. The refusal from another machine is checked from outside (safbox-client-keycloak-1 in the safbox-client profile)."
  only_if('Keycloak or the proxy is switched off', impact: 0.0) { services.include?('keycloak') && services.include?('proxy') }

  conf = file('/etc/safbox-proxy/nginx.conf').content.to_s
  %w[/admin/ /realms/master/].each do |path|
    describe "nginx's location for #{path}" do
      subject { conf[/location \^~ #{Regexp.escape(path)} \{[^}]*\}/m] }
      it { should match(/allow 127\.0\.0\.1;/) }
      it { should match(/deny all;/) }
    end
  end
end

control 'safbox-proxy-1' do
  impact 1.0
  title 'The TLS proxy runs from a pinned image on ports 80 and 443, the only ports the firewall opens'
  desc 'An nginx container from an image pinned by digest starts at boot and listens on port 80, which only redirects to HTTPS, and 443, and on no other port. Apart from the services firewalld allows by name (ssh and the like), only http and https are open, so the applications are reached through the proxy only.'
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe parse_config_file("#{quadlet}/safbox-proxy.container") do
    its('Container.Image') { should match pinned }
    its('Install.WantedBy') { should eq 'multi-user.target' }
  end
  describe file('/etc/safbox-proxy/nginx.conf') do
    its('content') { should_not match(/^\s*listen\s+(?!(80|443)[\s;])/) }
  end
  describe firewalld do
    it { should have_service_enabled_in_zone('http') }
    it { should have_service_enabled_in_zone('https') }
  end
  describe command('firewall-cmd --list-ports') do
    its('stdout.split') { should be_empty }
  end
  if deployed
    describe service('safbox-proxy') do
      it { should be_running }
    end
    [80, 443].each do |number|
      describe port(number) do
        it { should be_listening }
      end
    end
  end
end

control 'safbox-proxy-2' do
  impact 1.0
  title 'The start page and each application answer at their names over HTTPS, with a certificate the box trusts'
  desc "#{domain} serves the SAFBox start page and each application answers at its own name on port 443. The box resolves its names to itself and first boot adds the local CA that signs the proxy's certificate to the system trust store, so each request verifies the certificate."
  only_if('The proxy is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('proxy') && deployed }

  {
    domain => ['/', /<title>SAFBox/],
    "heimdall.#{domain}" => ['/', %r{<title>Heimdall</title>}],
    "vulcan.#{domain}" => ['/users/sign_in', /Vulcan/],
    "keycloak.#{domain}" => ['/realms/safbox/.well-known/openid-configuration', %r{"issuer":"https://keycloak\.#{Regexp.escape(domain)}/realms/safbox"}],
  }.each do |name, (path, page)|
    next unless name == domain || services.include?(name.split('.').first)

    describe http("https://#{name}#{path}") do
      its('status') { should eq 200 }
      its('body') { should match(page) }
    end
  end
end

control 'safbox-proxy-3' do
  impact 1.0
  title "The proxy's private keys are root's alone, the template holds none, and its certificate is renewed before it expires"
  desc "First boot makes the proxy's key and certificate, signed by a local CA of the box's own, so no two boxes share a key and the template holds neither. Both keys are root's alone, and the CA's key is kept outside the directory the proxy container mounts. A daily timer, safbox-proxy-renew.timer, signs a new certificate within 30 days of expiry; the certificate has more than 14 days left. A site that installs its own certificate retires the local CA and renews its certificate itself."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe service('safbox-proxy-renew.timer') do
    it { should be_enabled }
    it { should be_running } if deployed
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
    if file('/etc/safbox/ca/ca.key').exist?
      describe file('/etc/safbox/ca/ca.key') do
        its('owner') { should eq 'root' }
        its('mode') { should cmp '0600' }
      end
      # The local CA is in the system trust store; its constraints limit what
      # a leaked CA key could sign to server certificates under the domain.
      describe x509_certificate('/etc/safbox/ca/ca.crt') do
        its('extensions.nameConstraints') do
          should eq ['critical', 'Permitted:', "DNS:#{domain}", "DNS:.#{domain}",
                     'Excluded:', 'IP:0.0.0.0/0.0.0.0', 'IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0']
        end
        its('extensions.extendedKeyUsage') { should eq ['TLS Web Server Authentication'] }
      end
    end
    describe x509_certificate('/etc/safbox/tls/safbox.crt') do
      its('validity_in_days') { should be > 14 }
    end
  else
    %w[/etc/safbox/tls/safbox.key /etc/safbox/ca].each do |path|
      describe file(path) do
        it { should_not exist }
      end
    end
  end
end

control 'safbox-firefox-1' do
  impact 0.5
  title 'Firefox on the desktop opens the start page, sends Mozilla no telemetry and bookmarks each application'
  desc "On a desktop build Firefox's system-wide policy, which users cannot change, makes the start page the home page, turns telemetry off and puts the box's applications (Heimdall, Vulcan, Keycloak's account page), SAF, SAF Training and the start page on the bookmarks toolbar."
  only_if('This is not a desktop build', impact: 0.0) { input('desktop') }

  policy_file = '/etc/firefox/policies/policies.json'
  proxy = services.include?('proxy')
  app_paths = { 'heimdall' => '/', 'vulcan' => '/', 'keycloak' => '/realms/safbox/account/' }
  expected = []
  if proxy
    served_apps.select { |app| services.include?(app) }.each do |app|
      expected << [app.capitalize, "https://#{app}.#{domain}#{app_paths[app]}"]
    end
  end
  expected << ['SAF', 'https://saf.mitre.org']
  expected << ['SAF Training', 'https://mitre.github.io/saf-training/']
  expected << ['SAFBox - Start Here', "https://#{domain}/"] if proxy

  describe file(policy_file) do
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0644' }
  end
  describe json(policy_file) do
    its(%w[policies DisableTelemetry]) { should eq true }
    its(%w[policies Homepage URL]) { should eq "https://#{domain}/" } if proxy
  end
  describe 'Firefox policy bookmarks (title, URL)' do
    subject { Array(json(policy_file).params.dig('policies', 'Bookmarks')).map { |b| b.values_at('Title', 'URL') } }
    it { should eq expected }
  end
end
