# frozen_string_literal: true

control 'safbox-accounts-1' do
  impact 1.0
  title 'No distribution default user exists'
  desc 'Cloud images create a default account with passwordless sudo. A SAFBox has only the accounts its deployer asked for.'

  %w[cloud-user almalinux rocky ubuntu debian].each do |name|
    describe user(name) do
      it { should_not exist }
    end
  end
end

users_cfg = '/etc/cloud/cloud.cfg.d/80-safbox-users.cfg'

control 'safbox-accounts-2' do
  impact 1.0
  title 'cloud-init creates admin, and only when the deployment asks for a user, and never gives it a password'
  desc 'The system configuration sets users to an empty list, so a boot without user data creates no account. A deployment that asks for the default user (as a clone with no user name set does) gets admin, locked, not the distribution\'s user. The set_passwords module does not run: the password a deployment supplies is for safuser, which first boot gives it, not for admin. Apart from set_passwords, cloud-init runs the modules its package lists, so the override does not drift from the package.'

  describe yaml(users_cfg) do
    its('users') { should eq [] }
    its(%w[system_info default_user name]) { should eq 'admin' }
    its(%w[system_info default_user lock_passwd]) { should eq true }
    its('cloud_init_modules') { should_not include 'set_passwords' }
  end

  package_cfg = yaml('/etc/cloud/cloud.cfg')
  %w[cloud_init_modules cloud_config_modules cloud_final_modules].each do |stage|
    package_modules = Array(package_cfg[stage]).map { |m| Array(m).first }
    if stage == 'cloud_init_modules'
      describe "The modules #{users_cfg} runs at the init stage" do
        subject { Array(yaml(users_cfg)['cloud_init_modules']).map { |m| Array(m).first } }
        it { should eq(package_modules - ['set_passwords']) }
      end
    else
      describe "The modules the package runs at the #{stage.delete_prefix('cloud_').delete_suffix('_modules')} stage" do
        subject { package_modules }
        it { should_not include 'set_passwords' }
      end
    end
  end
end

deployed = input('deployed')
admin_user = input('admin_user')

control 'safbox-accounts-3' do
  impact 1.0
  title 'safuser has a password that expires, the deployer\'s SSH key, and sudo that asks for its password'
  desc 'First boot creates safuser, the account for using the tools day to day. It logs in with the deployer\'s SSH key, or with its password at the console and the desktop login screen. Its password is the one the deployer supplied through cloud-init, or one generated at first boot, which meets the password quality policy, and kept readable by root only in /etc/safbox/safuser.env. It is not expired, so the first login does not force a change, and it follows the STIG\'s ageing: at most 60 days, then 35 days of grace before the account is disabled. Its sudo asks for that password.'
  only_if('First boot creates safuser on a deployed clone when safbox_base_5 is on', impact: 0.0) { deployed && input('safuser') }

  describe user('safuser') do
    it { should exist }
    its('home') { should eq '/home/safuser' }
    its('shell') { should eq '/bin/bash' }
  end
  describe shadow.where(user: 'safuser') do
    its('passwords.first') { should match(/^\$6\$/) }
    its('last_changes.first.to_i') { should be > 0 }
    its('max_days.first') { should cmp 60 }
    its('inactive_days.first') { should cmp 35 }
  end
  # A generated password meets the password quality policy. The check reads
  # it from the root-only file inside the shell and reports only pwscore's
  # verdict; with a supplied password there is none to check.
  describe command("p=$(sed -n 's/^SAFUSER_PASSWORD=//p' /etc/safbox/safuser.env 2>/dev/null); " \
                   "[ -z \"$p\" ] || printf '%s\\n' \"$p\" | pwscore safuser >/dev/null") do
    its('exit_status') { should eq 0 }
  end
  describe file('/home/safuser/.ssh/authorized_keys') do
    it { should be_owned_by 'safuser' }
    its('mode') { should cmp '0600' }
    its('content') { should match(/^ssh-/) }
  end
  describe file('/etc/sudoers.d/50-safuser') do
    its('content') { should match(/^safuser ALL=\(ALL\) ALL$/) }
    its('mode') { should cmp '0440' }
  end
end

control 'safbox-accounts-4' do
  impact 1.0
  title 'Only admin has passwordless sudo'
  desc 'admin (cloud-init\'s default user) keeps passwordless sudo for Ansible and the outside-in checks; no other sudo rule skips the password.'
  only_if('cloud-init creates admin on a deployed clone', impact: 0.0) { deployed && !admin_user.empty? }

  describe user(admin_user) do
    it { should exist }
  end
  describe command('grep -rhi nopasswd /etc/sudoers /etc/sudoers.d | grep -Ev "^[[:space:]]*#"') do
    its('stdout') { should match(/\A(#{Regexp.escape(admin_user)} ALL=\(ALL\) NOPASSWD:ALL\n)+\z/) }
  end
end

control 'safbox-accounts-5' do
  impact 1.0
  title 'SSH does not accept passwords'
  desc 'Accounts log in over SSH with keys only; passwords work at the console and the desktop login screen.'

  describe command('sshd -T') do
    its('stdout') { should match(/^passwordauthentication no$/) }
    its('stdout') { should match(/^kbdinteractiveauthentication no$/) }
  end
end

control 'safbox-accounts-6' do
  impact 1.0
  title 'admin has no password, never expires, and is not offered at the login screen'
  desc 'admin logs in with the deployer\'s SSH key only. Its password field is a lock with no hash, so no password works for it and none can expire; first boot exempts it from password ageing and inactivity, so its key login is never refused for an old password. On a desktop build it is a system account to AccountsService, so the login screen does not list it.'
  only_if('cloud-init creates admin on a deployed clone', impact: 0.0) { deployed && !admin_user.empty? }

  describe shadow.where(user: admin_user) do
    its('passwords.first') { should match(/\A[!*]+\z/) }
  end
  describe command("chage -l #{admin_user}") do
    its('stdout') { should match(/^Password expires\s*:\s*never$/) }
    its('stdout') { should match(/^Password inactive\s*:\s*never$/) }
    its('stdout') { should match(/^Maximum number of days between password change\s*:\s*-1$/) }
  end
  if input('desktop')
    describe ini("/var/lib/AccountsService/users/#{admin_user}") do
      its('User.SystemAccount') { should cmp 'true' }
    end
  end
end
