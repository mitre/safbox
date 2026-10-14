# frozen_string_literal: true

control 'safbox-seal-1' do
  impact 1.0
  title 'The build user, its SSH key and its sudo drop-in are gone'
  desc 'ADR-0001 Phase 2: the seal step deletes the build account the install layer created, with its ' \
       'authorized key and passwordless sudo rule, so the template carries no build credential.'
  only_if('the seal step has not run yet') { input('build_info_expected') }

  build_user = input('build_user')
  describe user(build_user) do
    it { should_not exist }
  end
  describe file("/etc/sudoers.d/90-#{build_user}") do
    it { should_not exist }
  end
  describe file("/home/#{build_user}") do
    it { should_not exist }
  end
end

control 'safbox-seal-2' do
  impact 1.0
  title 'No installer residue: kickstart copies, the %post log or installer logs'
  desc 'The kickstart copies and logs carry the build user name and public key. The seal step removes ' \
       '/root/*ks*.cfg, /root/ks-post.log and /var/log/anaconda.'
  only_if('the seal step has not run yet') { input('build_info_expected') }

  describe command("find /root -maxdepth 1 -name '*ks*.cfg'") do
    its('stdout') { should be_empty }
  end
  describe file('/root/ks-post.log') do
    it { should_not exist }
  end
  describe file('/var/log/anaconda') do
    it { should_not exist }
  end
end
