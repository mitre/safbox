# frozen_string_literal: true

control 'safbox-cli-1' do
  impact 1.0
  title 'The safbox command and its subcommand registry are installed'
  desc 'ADR-0001 §Shared Abstractions: the safbox command of the base role, with subcommand registration.'

  describe file('/usr/local/bin/safbox') do
    it { should exist }
    it { should be_executable }
    its('owner') { should eq 'root' }
  end

  describe directory('/usr/local/lib/safbox/commands') do
    it { should exist }
    its('owner') { should eq 'root' }
  end

  describe file('/usr/local/lib/safbox/commands/status') do
    it { should exist }
    it { should be_executable }
  end

  describe command('/usr/local/bin/safbox help') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^\s+status\s/) }
  end

  describe command('/usr/local/bin/safbox status') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^Distribution:/) }
    its('stdout') { should match(/^Microarchitecture level:\s+\S/) }
    its('stdout') { should match(/^FIPS mode:\s+enabled/) }
    its('stdout') { should match(/^First boot:/) }
    # One row per tool group, with the version or 'not installed'; the
    # versions themselves are checked by the safbox-tools-<n> controls.
    its('stdout') { should match(/^CINC Auditor:\s+\S/) }
    its('stdout') { should match(/^SAF CLI:\s+\S/) }
    its('stdout') { should match(/^Ansible core:\s+\S/) }
    its('stdout') { should match(/^Packer:\s+\S/) }
  end
end
