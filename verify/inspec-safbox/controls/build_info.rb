# frozen_string_literal: true

build_info_path = '/usr/local/share/safbox/build-info'

control 'safbox-build-info-1' do
  impact 0.7
  title 'The build record exists and names the distribution and microarchitecture level'
  desc 'ADR-0001 Risks: the image records which distribution and microarchitecture level it was built ' \
       'from so a lab artifact is never mistaken for a release artifact. Written by the seal step ' \
       'outside the root-only /etc/safbox, since it is not a secret and safbox status reads it, ' \
       'which also records the exact builds of packages the install layer installs unpinned.'
  only_if('build record is written by the seal step, which has not run yet') { input('build_info_expected') }

  describe file(build_info_path) do
    it { should exist }
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0644' }
    its('content') { should match(/^SAFBOX_BUILD_DATE=\d{4}-\d{2}-\d{2}T/) }
    its('content') { should match(/^SAFBOX_GIT_COMMIT=\S+$/) }
    its('content') { should match(/^SAFBOX_DISTRIBUTION=\S+$/) }
    its('content') { should match(/^SAFBOX_DISTRIBUTION_VERSION=\S+$/) }
    its('content') { should match(/^SAFBOX_PACKAGE_ARCH=\S+$/) }
    its('content') { should match(/^SAFBOX_MICROARCH_LEVEL=(x86-64-v[234]|n\/a)$/) }
    its('content') { should match(/^SAFBOX_FIPS_ENABLED=1$/) }
    its('content') { should match(/^SAFBOX_SEAL_MODE=#{Regexp.escape(input('seal_mode_expected'))}$/) }
    its('content') { should match(/^SAFBOX_UNPINNED_PACKAGES=.*\bcloud-init-\d/) }
    its('content') { should match(/^SAFBOX_UNPINNED_PACKAGES=.*\bqemu-guest-agent-\d/) }
  end

  describe command('runuser -u nobody -- /usr/local/bin/safbox status') do
    its('stdout') { should match(/^Microarchitecture level:\s+x86-64-v[234]$/) }
    its('stdout') { should match(/^Build MICROARCH_LEVEL:\s+\S/) }
  end

  # Surface the recorded values in the test description so the results carry them.
  if file(build_info_path).exist?
    build_info = parse_config_file(build_info_path)
    describe "built from #{build_info['SAFBOX_DISTRIBUTION']} #{build_info['SAFBOX_DISTRIBUTION_VERSION']} " \
             "#{build_info['SAFBOX_PACKAGE_ARCH']} at #{build_info['SAFBOX_MICROARCH_LEVEL']}" do
      subject { build_info['SAFBOX_DISTRIBUTION'] }
      it { should_not be_nil }
    end
  end
end
