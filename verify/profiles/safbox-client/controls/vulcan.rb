# frozen_string_literal: true

# Vulcan through the proxy, from this machine. The request goes to the
# box's address with Vulcan's name as its Host header, as a DNS or hosts
# entry would send it; the certificate is not verified here because
# safbox-client-proxy-1 checks it for every name.

services = input('expected_services')
name = "vulcan.#{input('domain')}"

control 'safbox-client-vulcan-1' do
  impact 1.0
  title "Vulcan's sign-in page answers here through the proxy"
  desc "Vulcan's sign-in page answers 200 at its name; the proxy's start page has no such path."
  only_if('Vulcan or the proxy is switched off', impact: 0.0) { services.include?('vulcan') && services.include?('proxy') }

  describe http("https://#{input('address')}/users/sign_in", headers: { 'Host' => name }, ssl_verify: false) do
    its('status') { should eq 200 }
    its('body') { should match(/Vulcan/) }
  end
end
