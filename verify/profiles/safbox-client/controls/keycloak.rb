# frozen_string_literal: true

# Keycloak through the proxy, from this machine. Each request goes to the
# box's address with Keycloak's name as its Host header, as a DNS or hosts
# entry would send it; the certificate is not verified here because
# safbox-client-proxy-1 checks it for every name.

services = input('expected_services')
name = "keycloak.#{input('domain')}"
box = "https://#{input('address')}"
host = { 'Host' => name }

control 'safbox-client-keycloak-1' do
  impact 1.0
  title "Keycloak's safbox realm answers here through the proxy, and its administration paths do not"
  desc "Keycloak's discovery document answers 200 at its name and names the safbox realm there as its issuer. The administration console (/admin/) and the master realm answer 403 to any client but the box itself (safbox-keycloak-2 checks the proxy's rule on the box)."
  only_if('Keycloak or the proxy is switched off', impact: 0.0) { services.include?('keycloak') && services.include?('proxy') }
  # The discovery body is read here, so stop before any request when skipped.
  next unless services.include?('keycloak') && services.include?('proxy')

  discovery = http("#{box}/realms/safbox/.well-known/openid-configuration", headers: host, ssl_verify: false)
  describe discovery do
    its('status') { should eq 200 }
  end
  describe json(content: discovery.body) do
    its('issuer') { should eq "https://#{name}/realms/safbox" }
  end
  %w[/admin/ /realms/master/.well-known/openid-configuration].each do |path|
    describe http("#{box}#{path}", headers: host, ssl_verify: false) do
      its('status') { should eq 403 }
    end
  end
end
