# frozen_string_literal: true

sshd_unit = os.debian? ? 'ssh' : 'sshd'
chrony_unit = os.debian? ? 'chrony' : 'chronyd'

control 'safbox-services-1' do
  impact 0.7
  title 'The guest agent, cloud-init and sshd are enabled'
  desc 'ADR-0001 install layer contract: a booted, SSH-reachable OS with the guest agent and cloud-init present.'

  %w[qemu-guest-agent cloud-init].push(sshd_unit).each do |unit|
    describe service(unit) do
      it { should be_installed }
      it { should be_enabled }
    end
  end

  describe service(sshd_unit) do
    it { should be_running }
  end
end

control 'safbox-services-2' do
  # High: a disabled firewall or unsynchronised clock must fail the build.
  impact 0.7
  title 'Time synchronisation and the firewall are enabled with SSH allowed'
  desc 'platform role: chrony and firewalld run; the firewall allows SSH (ADR-0001 Quality Standards).'

  describe service(chrony_unit) do
    it { should be_enabled }
    it { should be_running }
  end

  describe service('firewalld') do
    it { should be_enabled }
    it { should be_running }
  end

  describe command('firewall-cmd --list-services') do
    its('stdout') { should match(/(^|\s)ssh(\s|$)/) }
  end
end

control 'safbox-services-3' do
  impact 0.7
  title 'The journal persists across reboots'
  desc 'platform role: journald keeps the journal on disk (Storage=persistent), so first-boot output and ' \
       'security-relevant logs survive a reboot. The distribution default keeps it in memory only.'

  describe command('systemd-analyze cat-config systemd/journald.conf') do
    its('stdout') { should match(/^Storage=persistent$/) }
  end

  describe file('/var/log/journal') do
    it { should be_directory }
  end
end
