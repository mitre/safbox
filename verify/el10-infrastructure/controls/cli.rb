# frozen_string_literal: true

deployed = input('firstboot_completed_expected')
expected_services = input('expected_services').map(&:to_s)
services_registry = '/usr/local/share/safbox/services.d'
# Each service role registers its service with `safbox services`: the
# registry file name (first-boot order, as its hook), the label shown, and
# the units whose health makes up the service's.
registered_services = {
  'heimdall' => { file: '20-heimdall', label: 'Heimdall', units: %w[heimdall-pod.service heimdall-db.service heimdall.service] },
  'vulcan' => { file: '30-vulcan', label: 'Vulcan', units: %w[vulcan-pod.service vulcan-db.service vulcan.service] },
  'proxy' => { file: '40-proxy', label: 'TLS proxy and landing page', units: %w[safbox-proxy.service safbox-landing-status.timer] },
}

control 'safbox-cli-1' do
  impact 1.0
  title 'The safbox command and its subcommand registry are installed'
  desc 'ADR-0001 §Shared Abstractions: the safbox command of the base role, with subcommand registration.'

  describe file('/usr/local/bin/safbox') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end

  describe directory('/usr/local/lib/safbox/commands') do
    it { should exist }
    its('owner') { should eq 'root' }
  end

  describe file('/usr/local/lib/safbox/commands/status') do
    it { should exist }
    it { should be_executable }
  end

  describe command('/usr/local/bin/safbox help') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^\s+status\s/) }
  end

  describe command('/usr/local/bin/safbox status') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^Distribution:/) }
    its('stdout') { should match(/^Microarchitecture level:\s+\S/) }
    its('stdout') { should match(/^FIPS mode:\s+enabled/) }
    its('stdout') { should match(/^First boot:/) }
    # One row per tool group, with the version or 'not installed'; the
    # versions themselves are checked by the safbox-tools-<n> controls.
    its('stdout') { should match(/^CINC Auditor:\s+\S/) }
    its('stdout') { should match(/^SAF CLI:\s+\S/) }
    its('stdout') { should match(/^Ansible core:\s+\S/) }
    its('stdout') { should match(/^Packer:\s+\S/) }
  end
end

control 'safbox-cli-2' do
  impact 1.0
  title 'safbox services reports the health of the proxy, Heimdall and Vulcan and of their units'
  desc "ADR-0001 Phase 8: safbox services reports unit health for each service the image ships. Each service role registers its service in #{services_registry} (a label and the units that make it up); the command reads systemd's view of each unit, so any user may run it, and sums each service up as running, starting, stopping, waiting (a unit's condition failed: first boot has not written its secrets or certificate), stopped, failed or not installed. It exits 0 only when every registered service runs, and 3 otherwise. On a deployed clone every service runs; on the build VM none has started."

  describe file('/usr/local/lib/safbox/commands/services') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end

  describe command('/usr/local/bin/safbox help') do
    its('stdout') { should match(/^\s+services\s+\S/) }
  end

  describe command("sh -c 'ls -1 #{services_registry}'") do
    its('stdout.split') { should eq expected_services.map { |s| registered_services[s][:file] }.sort }
  end

  want = deployed ? 'running' : 'stopped'
  want_active = deployed ? 'active' : 'inactive'
  tsv = command('runuser -u nobody -- /usr/local/bin/safbox services --tsv')
  describe tsv do
    its('exit_status') { should eq(deployed ? 0 : 3) }
  end
  describe 'Services safbox services --tsv reports, as name, label and health' do
    subject { tsv.stdout.lines.map { |line| line.chomp.split("\t") }.sort }
    it { should eq expected_services.map { |s| [s, registered_services[s][:label], want] }.sort }
  end

  human = command('runuser -u nobody -- /usr/local/bin/safbox services')
  expected_services.each do |service|
    describe "safbox services for #{service}" do
      subject { human.stdout }
      it { should match(/^#{Regexp.escape(registered_services[service][:label])}\s+#{want}$/) }
      registered_services[service][:units].each do |unit|
        it { should match(/^\s+#{Regexp.escape(unit)}\s+#{want_active} \(/) }
      end
    end
  end
end
