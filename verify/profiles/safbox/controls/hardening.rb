# frozen_string_literal: true

# Whether each STIG requirement is met is the STIG overlay's job. These
# controls check that hardening ran and left the box administrable.

control 'safbox-hardening-1' do
  impact 1.0
  title 'The RHEL 10 STIG was applied by the pinned Ansible Lockdown release'
  desc 'The hardening role writes its record only after the Lockdown role completed.'

  describe parse_config_file('/usr/local/share/safbox/hardening') do
    its('SAFBOX_LOCKDOWN_ROLE') { should eq 'RHEL10-STIG' }
    its('SAFBOX_LOCKDOWN_VERSION') { should eq input('lockdown_version') }
  end
end

control 'safbox-hardening-2' do
  impact 1.0
  title 'SSH key logins still work after hardening'
  desc 'sshd accepts public keys through PAM, so admin can log in and administer the box.'

  describe command('sshd -T') do
    its('stdout') { should match(/^pubkeyauthentication yes$/) }
    its('stdout') { should match(/^usepam yes$/) }
  end
end
