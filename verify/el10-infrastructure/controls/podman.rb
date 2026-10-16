# frozen_string_literal: true

control 'safbox-podman-1' do
  impact 1.0
  title 'podman is installed and the Quadlet unit directory exists'
  desc 'ADR-0001 §Decision: services run as podman Quadlets from the distribution podman stack. Containers may read the host\'s CA trust store (the SELinux boolean container_read_certs), which the service containers mount read-only.'

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

  # The service containers mount the host's extracted CA trust store (cert_t)
  # read-only; SELinux lets a container read it only with this boolean, set
  # persistently. Nothing on the host is relabelled.
  describe command('getsebool container_read_certs') do
    its('stdout.strip') { should eq 'container_read_certs --> on' }
  end
  describe command('semanage boolean --list --locallist') do
    its('stdout') { should match(/^container_read_certs\s+\(on\s*,\s*on\)/) }
  end
end

control 'safbox-podman-2' do
  impact 1.0
  title 'The smoke test Quadlet unit is present and running'
  desc 'Phase 2 acceptance: a trivial Quadlet unit starts on boot of a clone and survives reboot.'
  only_if('smoke test unit not installed in this build') do
    file('/etc/containers/systemd/safbox-example.container').exist?
  end

  describe service('safbox-example') do
    it { should be_running }
  end
end
