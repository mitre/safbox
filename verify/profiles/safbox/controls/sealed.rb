# frozen_string_literal: true

# The seal runs at the end of the build: it records the build, deletes the
# build user and removes installer residue. First boot then runs once on
# each deployed clone.

deployed = input('deployed')

control 'safbox-build-info-1' do
  impact 1.0
  title 'The build record names the commit, the distribution and a full seal'
  desc 'The seal writes a world-readable record of the build, so a development image is never mistaken for a release one.'
  only_if('The seal has not run on the build VM', impact: 0.0) { deployed }

  describe file('/usr/local/share/safbox/build-info') do
    its('mode') { should cmp '0644' }
  end
  describe parse_config_file('/usr/local/share/safbox/build-info') do
    its('SAFBOX_GIT_COMMIT') { should_not be_empty }
    its('SAFBOX_DISTRIBUTION') { should match(/^(Rocky|AlmaLinux)/) }
    its('SAFBOX_FIPS_ENABLED') { should eq '1' }
    its('SAFBOX_SEAL_MODE') { should eq 'full' }
  end
end

control 'safbox-sealed-1' do
  impact 1.0
  title 'The build user, its home and its sudo rule are gone'
  desc 'The template carries no build credential.'
  only_if('The seal has not run on the build VM', impact: 0.0) { deployed }

  describe user('packer') do
    it { should_not exist }
  end
  describe file('/etc/sudoers.d/90-packer') do
    it { should_not exist }
  end
  describe directory('/home/packer') do
    it { should_not exist }
  end
end

control 'safbox-sealed-2' do
  impact 1.0
  title 'No installer residue is left'
  desc 'The kickstart copies and installer logs name the build user and its key; the seal removes them.'
  only_if('The seal has not run on the build VM', impact: 0.0) { deployed }

  %w[/root/anaconda-ks.cfg /root/original-ks.cfg /root/ks-post.log /var/log/anaconda].each do |path|
    describe file(path) do
      it { should_not exist }
    end
  end
end

control 'safbox-firstboot-1' do
  impact 1.0
  title 'The first-boot unit is installed and enabled to run once'
  desc 'A one-shot unit runs the first-boot hooks on a clone, then leaves a marker so it never runs again.'

  describe service('safbox-firstboot') do
    it { should be_enabled }
  end
  describe parse_config_file('/etc/systemd/system/safbox-firstboot.service') do
    its('Unit.ConditionPathExists') { should eq '!/var/lib/safbox/firstboot.done' }
    its('Service.Type') { should eq 'oneshot' }
  end
end

control 'safbox-firstboot-2' do
  impact 1.0
  title 'First boot completed on the deployed clone'
  desc 'The unit ran successfully and left its completion marker.'
  only_if('This is not a deployed clone', impact: 0.0) { deployed }

  describe file('/var/lib/safbox/firstboot.done') do
    it { should exist }
  end
  describe service('safbox-firstboot') do
    its('params.Result') { should eq 'success' }
  end
end
