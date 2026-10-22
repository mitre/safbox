# frozen_string_literal: true

# The TLS proxy, from this machine: the only way in. The box's FIPS crypto
# policy limits what the proxy will negotiate; that is probed from here,
# with a client that would accept more, because the box's own FIPS-mode
# client will not make the weaker offers at all, which proves nothing.

services = input('expected_services')
address = input('address')
domain = input('domain')
client = safbox_client(address, domain, input('work_dir'))
names = client.apps.select { |app| services.include?(app) }.map { |app| "#{app}.#{domain}" }
# Each application and its database listen on the box's loopback address
# only (safbox-heimdall-3, safbox-vulcan-3 and safbox-keycloak-4 check the
# binding on the box).
app_ports = { 'heimdall' => 3000, 'vulcan' => 3001, 'keycloak' => 3002 }

control 'safbox-client-proxy-1' do
  impact 1.0
  title 'Each name negotiates TLS 1.3 with a certificate for that name, and is refused TLS 1.0, TLS 1.1 and ChaCha20'
  desc "Offered each application's name, the proxy negotiates TLS 1.3 and serves a certificate that names it. Under the FIPS crypto policy it refuses TLS 1.0, TLS 1.1 and a TLS 1.2 offer of ChaCha20-Poly1305 alone, which is not FIPS-approved, with a TLS alert: a client that would not make the offer, or a refused connection, is no verdict and fails."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  names.each do |name|
    describe "#{name} offered TLS" do
      subject { command(client.s_client(name, '-brief')) }
      its('stdout') { should match(/^Protocol version: TLSv1\.3$/) }
    end
    describe "The certificate served for #{name}" do
      subject { command("#{client.s_client(name, '-showcerts')} | openssl x509 -noout -checkhost #{name}") }
      its('stdout') { should eq "Hostname #{name} does match certificate\n" }
    end
    {
      'TLS 1.0' => "-tls1 -cipher 'ALL:@SECLEVEL=0'",
      'TLS 1.1' => "-tls1_1 -cipher 'ALL:@SECLEVEL=0'",
      'ChaCha20-Poly1305 alone over TLS 1.2' => '-tls1_2 -cipher ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-CHACHA20-POLY1305',
    }.each do |offer, args|
      describe "#{name} offered #{offer}" do
        subject { command(client.s_client(name, args)) }
        its('stdout') { should match(/alert (protocol version|handshake failure|insufficient security)|wrong version number/) }
        # No cipher agreed: OpenSSL reports "Cipher is (NONE)" after an alert.
        its('stdout') { should_not match(/Cipher is (?!\(NONE\))/) }
      end
    end
  end
end

control 'safbox-client-proxy-2' do
  impact 1.0
  title "Only the proxy's ports answer from here"
  desc "Ports 80 and 443 answer this machine. The applications' own ports and PostgreSQL's do not: each application and its database listen on the box's loopback address only, behind the proxy."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  # The host resource probes a port with nc or ncat; without either it may
  # skip, which would pass this control unseen.
  describe 'nc or ncat on this machine, for the port probes' do
    subject { command('nc').exist? || command('ncat').exist? }
    it { should eq true }
  end
  [80, 443].each do |port|
    describe host(address, port: port, protocol: 'tcp') do
      it { should be_reachable }
    end
  end
  (app_ports.select { |app, _| services.include?(app) }.values + [5432]).each do |port|
    describe host(address, port: port, protocol: 'tcp') do
      it { should_not be_reachable }
    end
  end
end

control 'safbox-client-proxy-3' do
  impact 1.0
  title 'Plain HTTP to each name and to the address is redirected to HTTPS with the same name and path'
  desc 'Port 80 answers a request for each name, and for the bare address, with a permanent redirect to https:// on the same name and path, and a plain HTTP request sent to port 443 is redirected the same way instead of being refused with 400.'
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  ([domain, address] + names).each do |name|
    [80, 443].each do |port|
      url = port == 80 ? "http://#{name}/safbox/check?probe=1" : "http://#{name}:443/safbox/check?probe=1"
      describe "#{url} from here" do
        subject { command("curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --resolve #{name}:#{port}:#{address} '#{url}'") }
        its('stdout') { should eq "301 https://#{name}/safbox/check?probe=1" }
      end
    end
  end
end
