# frozen_string_literal: true

# The firewall (ADR-0001 Quality Standards, security by design: the firewall
# allows SSH and the proxy ports only). Every network interface is in one
# firewalld zone, safbox_firewall_zone in group_vars: drop on a hardened
# image (the Lockdown STIG role moves the interface there and makes it the
# default zone), public without hardening. That zone allows exactly the
# services in the firewall_services input (ssh) and the proxy's HTTPS ports,
# and nothing else, at runtime and in the permanent configuration.
#
# podman's netavark puts the subnet of each container network into the
# trusted zone as a source, so containers can reach the host; those subnets
# are host-internal bridges, not a path in from the network, and they are
# the only sources any other zone may hold.

service_expected = ->(service) { input('expected_services').map(&:to_s).include?(service) }
hardened = input('hardening_expected')
zone = hardened ? 'drop' : 'public'
proxy_ports = input('proxy_ports').transform_keys(&:to_s)
proxy_apps = %w[heimdall vulcan].select { |app| service_expected.call(app) }
want_ports = service_expected.call('proxy') ? (['landing'] + proxy_apps).map { |key| "#{proxy_ports[key]}/tcp" }.sort : []
want_services = input('firewall_services').map(&:to_s).sort

control 'safbox-firewall-1' do
  impact 1.0
  title 'The firewall allows SSH and the proxy ports only'
  desc "ADR-0001 Quality Standards: the firewall allows SSH and the proxy ports only. Every interface is in the #{zone} zone, which is the default zone and allows exactly the firewall_services input and the HTTPS ports of the landing page and each application the image ships, with no other port, protocol, source port, forward port or rich rule, at runtime and permanently. On a hardened image the zone's target is DROP. The DNS and NTP services the Lockdown role allows by default are left out: they admit inbound queries to servers SAFBox does not run, while the box's own DNS and NTP client traffic returns as related to its outbound connections. Other zones hold no interface, and the only sources they hold are podman's container network subnets."

  describe command('firewall-cmd --get-default-zone') do
    its('stdout.strip') { should eq zone }
  end

  { 'runtime' => 'firewall-cmd', 'permanent' => 'firewall-cmd --permanent' }.each do |label, cmd|
    {
      'services' => want_services,
      'ports' => want_ports,
      'protocols' => [],
      'source-ports' => [],
      'forward-ports' => [],
    }.each do |what, want|
      describe "#{what.capitalize} the #{zone} zone allows (#{label})" do
        subject { command("#{cmd} --zone=#{zone} --list-#{what}").stdout.split.sort }
        it { should eq want }
      end
    end

    describe "Rich rules in the #{zone} zone (#{label})" do
      subject { command("#{cmd} --zone=#{zone} --list-rich-rules").stdout.strip }
      it { should be_empty }
    end
  end

  if hardened
    describe "Target of the #{zone} zone" do
      subject { command("firewall-cmd --permanent --zone=#{zone} --get-target").stdout.strip }
      it { should eq 'DROP' }
    end
  end

  # Subnets of every podman network, the only sources another zone may hold.
  podman_subnets = command("sh -c 'podman network ls --format \"{{.Name}}\" | xargs -r podman network inspect --format \"{{range .Subnets}}{{.Subnet}} {{end}}\"'").stdout.split
  other_zones = command('firewall-cmd --get-zones').stdout.split - [zone]
  describe 'Zones other than the default zone' do
    subject { other_zones }
    it { should_not be_empty }
  end
  other_zones.each do |other|
    describe "Interfaces in the #{other} zone" do
      subject { command("firewall-cmd --zone=#{other} --list-interfaces").stdout.split }
      it { should be_empty }
    end
    describe "Sources in the #{other} zone that are not podman network subnets" do
      subject { command("firewall-cmd --zone=#{other} --list-sources").stdout.split - podman_subnets }
      it { should be_empty }
    end
  end
end
