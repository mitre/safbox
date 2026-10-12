# frozen_string_literal: true

control 'safbox-podman-1' do
  impact 0.7
  title 'podman is installed and the Quadlet unit directory exists'
  desc 'ADR-0001 §Decision: services run as podman Quadlets from the distribution podman stack.'

  describe package('podman') do
    it { should be_installed }
  end

  describe command('podman --version') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/podman version \d+\./) }
  end

  describe directory('/etc/containers/systemd') do
    it { should exist }
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0755' }
  end

  describe file('/etc/containers/registries.conf.d/50-safbox.conf') do
    it { should exist }
    its('content') { should match(/^short-name-mode = "enforcing"$/) }
  end
end

control 'safbox-podman-2' do
  impact 0.7
  title 'The smoke test Quadlet unit is present and running'
  desc 'Phase 2 acceptance: a trivial Quadlet unit starts on boot of a clone and survives reboot.'
  only_if('smoke test unit not installed in this build') do
    file('/etc/containers/systemd/safbox-example.container').exist?
  end

  describe service('safbox-example') do
    it { should be_running }
  end
end
