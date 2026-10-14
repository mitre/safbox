# frozen_string_literal: true

control 'safbox-firstboot-1' do
  impact 1.0
  title 'The first-boot framework is installed and enabled'
  desc 'ADR-0001 §Decision: a safbox-firstboot systemd unit creates per-install credentials on first boot.'

  describe file('/etc/systemd/system/safbox-firstboot.service') do
    it { should exist }
    its('content') { should match(%r{^ConditionPathExists=!/var/lib/safbox/firstboot\.done$}) }
    its('content') { should match(/^Type=oneshot$/) }
    its('content') { should match(/^RemainAfterExit=yes$/) }
  end

  describe service('safbox-firstboot') do
    it { should be_enabled }
  end

  describe file('/usr/local/sbin/safbox-firstboot') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end

  describe file('/usr/local/lib/safbox/secrets.sh') do
    it { should exist }
    its('owner') { should eq 'root' }
  end

  describe directory('/etc/safbox') do
    it { should exist }
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0700' }
  end

  describe directory('/etc/safbox/firstboot.d') do
    it { should exist }
    its('owner') { should eq 'root' }
  end
end

control 'safbox-firstboot-3' do
  impact 1.0
  title 'The first-boot unit is not in an ordering cycle with multi-user.target'
  desc 'The unit is wanted by multi-user.target, so it is ordered before it. If it is ordered after a ' \
       'unit that itself comes after multi-user.target (cloud-final.service, cloud-init.target), ' \
       'systemd breaks the cycle by deleting the first-boot job and first boot never runs.'

  unit = 'safbox-firstboot.service'
  after = command("systemctl show -p After --value #{unit}").stdout.split
  after.each do |dependency|
    describe "#{unit} ordered after #{dependency}, which" do
      subject { command("systemctl show -p After --value #{dependency}").stdout.split }
      it { should_not include 'multi-user.target' }
    end
  end

  describe command('journalctl -b --no-pager -o cat -u safbox-firstboot.service') do
    its('stdout') { should_not match(/ordering cycle/i) }
  end
end

control 'safbox-firstboot-2' do
  impact 1.0
  title 'First boot has completed exactly once on a deployed clone'
  desc 'Phase 2 acceptance: the unit runs once on first boot, records completion, and does not run ' \
       'again. The journal is persistent, so it holds exactly one completion message however many ' \
       'times the clone has booted.'
  only_if('not a deployed clone') { input('firstboot_completed_expected') }

  describe file('/var/lib/safbox/firstboot.done') do
    it { should exist }
    its('content') { should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/) }
  end

  describe command('systemctl show -p Result --value safbox-firstboot.service') do
    its('stdout.strip') { should eq 'success' }
  end

  describe command('runuser -u nobody -- /usr/local/bin/safbox status') do
    its('stdout') { should match(/^First boot:\s+completed/) }
  end

  completions = command('journalctl --no-pager -o cat -t safbox-firstboot').stdout
                .scan(/^safbox-firstboot: first boot complete;/).length
  describe 'first-boot completions recorded in the persistent journal' do
    subject { completions }
    it { should eq 1 }
  end
end
