# frozen_string_literal: true

# The hardening role (ADR-0001 §Decision: hardened with documented
# deviations) applies the RHEL 10 STIG with the pinned Ansible Lockdown role
# as the last role of the appliance play. Whether each STIG requirement is
# met is the STIG overlay's job; these controls assert what SAFBox itself
# needs from hardening: that it ran, and that the box is still reachable
# and administrable over SSH afterwards (ADR-0001 risk: hardening severs the
# build connection).

control 'safbox-hardening-1' do
  impact 1.0
  title 'The RHEL 10 STIG was applied by the pinned Ansible Lockdown release'
  desc 'The hardening role writes its record only after the Lockdown role completed, naming the release it applied; an image hardened by another release, or not hardened, fails here.'
  only_if('The hardening task group is switched off (hardening_expected)') { input('hardening_expected') }

  describe file('/usr/local/share/safbox/hardening') do
    it { should exist }
    its('owner') { should eq 'root' }
    its('content') { should match(/^SAFBOX_LOCKDOWN_ROLE=RHEL10-STIG$/) }
    its('content') { should match(/^SAFBOX_LOCKDOWN_VERSION=#{Regexp.escape(input('lockdown_version'))}$/) }
  end
end

control 'safbox-hardening-2' do
  impact 1.0
  title 'SSH key logins and sudo still work for the connecting account after hardening'
  desc 'The scan itself connects over SSH with a key and escalates with sudo, so a broken session fails the scan. This names what hardening must leave in place for that account: sshd running, public key authentication and PAM enabled, the account not excluded by sshd, and the account in sudo.'
  only_if('The hardening task group is switched off (hardening_expected)') { input('hardening_expected') }

  # CINC Auditor's --sudo runs each command through sudo; SUDO_USER is the
  # account that logged in over SSH.
  login = command('printenv SUDO_USER').stdout.strip
  describe 'The account the scan logged in as' do
    subject { login }
    it { should_not be_empty }
  end

  describe service('sshd') do
    it { should be_enabled }
    it { should be_running }
  end

  # sshd -T with a connection specification evaluates Match blocks for that
  # account, so this is the configuration a login of that account gets.
  effective = command("sshd -T -C user=#{login},host=localhost,addr=127.0.0.1").stdout
  describe "sshd's effective configuration for #{login}" do
    subject { effective }
    it { should match(/^pubkeyauthentication yes$/) }
    it { should match(/^usepam yes$/) }
    it { should_not match(/^denyusers .*\b#{Regexp.escape(login)}\b/) }
    it { should_not match(/^allowusers (?!.*\b#{Regexp.escape(login)}\b)/) }
  end

  describe command("sudo -l -U #{login}") do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/may run the following commands/) }
  end
end
