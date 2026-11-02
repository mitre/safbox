# frozen_string_literal: true

# Heimdall through the proxy, from this machine. The request goes to the
# box's address with Heimdall's name as its Host header, as a DNS or hosts
# entry would send it; the certificate is not verified here because
# safbox-client-proxy-1 checks it for every name.

services = input('expected_services')
name = "heimdall.#{input('domain')}"

control 'safbox-client-heimdall-1' do
  impact 1.0
  title "Heimdall's page answers here through the proxy"
  desc "Heimdall's page answers 200 at its name, from Heimdall itself and not the proxy's start page."
  only_if('Heimdall or the proxy is switched off', impact: 0.0) { services.include?('heimdall') && services.include?('proxy') }

  describe http("https://#{input('address')}/", headers: { 'Host' => name }, ssl_verify: false) do
    its('status') { should eq 200 }
    its('body') { should match(%r{<title>Heimdall</title>}) }
  end
end
