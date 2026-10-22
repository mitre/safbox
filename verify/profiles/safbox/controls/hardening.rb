# frozen_string_literal: true

# Whether each STIG requirement is met is the STIG overlay's job. These
# controls check that hardening ran and left the box administrable.

control 'safbox-hardening-1' do
  impact 1.0
  title 'The RHEL 10 STIG was applied by the pinned Ansible Lockdown release'
  desc 'The template_hardening role writes its record only after the Lockdown role completed.'

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

control 'safbox-hardening-3' do
  impact 0.7
  title 'AIDE checks file integrity every day'
  desc 'The template_hardening role writes /etc/aide.conf and the daily check (/etc/cron.daily/aide, run by anacron, which mails the report to root); Lockdown\'s own aide.conf is not valid AIDE syntax. The database describes a deployed box, so it is made on its first boot (safbox-aide-init.service), never in the template: on a clone it must exist and a check must run; on the build VM, before the seal, it is not checked.'

  describe command('aide --config-check') do
    its('exit_status') { should eq 0 }
  end
  describe file('/etc/cron.daily/aide') do
    it { should be_file }
    it { should be_owned_by 'root' }
    it { should be_executable.by('owner') }
    its('content') { should match(%r{^/usr/sbin/aide --check}) }
  end
  describe package('cronie-anacron') do
    it { should be_installed }
  end
  describe service('crond') do
    it { should be_enabled }
    it { should be_running }
  end
  if input('deployed')
    describe file('/var/lib/aide/aide.db.gz') do
      it { should be_file }
    end
    # aide --check exits 0 with no changes, 1 to 7 for the kinds of change
    # found, 14 and above for errors.
    describe command('aide --check') do
      its('exit_status') { should be < 14 }
    end
  end
end

control 'safbox-hardening-4' do
  impact 0.7
  title 'Pressing Ctrl-Alt-Delete repeatedly does not reboot the box'
  desc 'systemd reboots at once when Ctrl-Alt-Delete is pressed more than seven times in two seconds unless CtrlAltDelBurstAction is none (RHEL-10-700950). The template_hardening role sets it in a system.conf.d drop-in; Lockdown\'s drop-in has no .conf suffix, so systemd ignores it, and the baseline control cannot tell (its grep prints file names before the setting).'

  describe command('systemctl show -p CtrlAltDelBurstAction') do
    its('stdout') { should cmp "CtrlAltDelBurstAction=none\n" }
  end
end

control 'safbox-hardening-5' do
  impact 0.5
  title 'New accounts start with local initialization files of mode 0740 or less'
  desc 'RHEL-10-400235 (SV-281064) wants every local initialization file (a dotfile at the top of a home directory) 0740 or less. useradd -m, which cloud-init uses for admin and first boot for safuser, copies /etc/skel with its modes, so the template_hardening role sets the dotfiles there at build, after every package install and again on every run, since an update of the package that owns one can restore 0644. The STIG overlay checks the real homes (SV-281064).'

  describe command("find /etc/skel -maxdepth 1 -type f -name '.*' -perm /g+wx,o+rwx -print") do
    its('stdout') { should eq '' }
    its('exit_status') { should eq 0 }
  end
  describe file('/etc/skel/.bashrc') do
    it { should be_file }
    it { should_not be_more_permissive_than('0740') }
  end
end
