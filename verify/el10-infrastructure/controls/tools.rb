# frozen_string_literal: true

# One control per tools task group (safbox-tools-<n>, ADR-0001 Phase 3).
# The expected versions are profile inputs whose defaults equal the pins in
# ansible/group_vars/all/main.yml (tests/ansible/pins.sh fails on drift).
# The expected_tools input lists the tools the image ships: a site that
# switches a tools group off drops its tool there and the control skips.
# An expected tool that is missing fails: its version command does not run.
# Tools under /usr/local/bin are named by full path: sudo's secure_path,
# which the profile runs under, does not include /usr/local/bin.

expected_tools = input('expected_tools').map(&:to_s)
tool_expected = ->(tool) { expected_tools.include?(tool) }

# `safbox status` prints each tool's version for any user (ADR-0001 Phase 3).
status_row = lambda do |label, version|
  describe command('runuser -u nobody -- /usr/local/bin/safbox status') do
    its('stdout') { should match(/^#{Regexp.escape(label)}:\s+#{Regexp.escape(version.to_s)}(\s|$)/) }
  end
end

control 'safbox-tools-1' do
  impact 1.0
  title 'CINC Auditor is installed at its pinned version'
  desc 'ADR-0001 Phase 3: CINC Auditor ships on the box as an assessment tool (tools group ' \
       'safbox-tools-1), at the version pinned in group_vars. Only the version is compared, so ' \
       'a site build of the same version (another release) passes.'
  only_if('CINC Auditor is not in expected_tools (tools group safbox-tools-1 switched off)') do
    tool_expected.call('cinc-auditor')
  end

  version = input('cinc_auditor_version')
  describe command('cinc-auditor version') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^#{Regexp.escape(version)}$/) }
  end

  instance_exec('CINC Auditor', version, &status_row)
end

control 'safbox-tools-2' do
  impact 1.0
  title 'The SAF CLI is installed at its pinned version on the distribution Node.js'
  desc 'ADR-0001 Phase 3: the MITRE SAF CLI (tools group safbox-tools-2), installed from npm at ' \
       "its pinned version and run by the distribution's Node.js, which uses the system OpenSSL and so its FIPS provider."
  only_if('the SAF CLI is not in expected_tools (tools group safbox-tools-2 switched off)') do
    tool_expected.call('saf-cli')
  end

  version = input('saf_cli_version')
  # Run in a scratch directory that is removed afterwards: the SAF CLI
  # writes saf-cli.log to its working directory and has no option to stop it.
  # One sh -c, because sudo (the profile's --sudo) applies to the first word
  # of a command line only.
  saf_version = %q(sh -c 'd=$(mktemp -d) && cd "$d" && /usr/local/bin/saf --version; rc=$?; cd / && rm -rf "$d"; exit $rc')
  describe command(saf_version) do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(%r{^@mitre/saf/#{Regexp.escape(version)} }) }
  end

  instance_exec('SAF CLI', version, &status_row)

  # The SAF CLI writes saf-cli.log to its working directory on every run,
  # even for --version. Running it must leave nothing in the scanning
  # user's home or in /, so a scan of a consumer's box leaves no residue.
  scan_user = command('printf %s "${SUDO_USER:-$(id -un)}"').stdout.strip
  scan_home = command("getent passwd #{scan_user} | cut -d: -f6").stdout.strip
  ["#{scan_home}/saf-cli.log", '/saf-cli.log'].uniq.each do |residue|
    describe file(residue) do
      it { should_not exist }
    end
  end

  if input('fips_required')
    describe command("node -p \"require('crypto').getFips()\"") do
      its('exit_status') { should eq 0 }
      its('stdout.strip') { should cmp '1' }
    end
  end
end

control 'safbox-tools-3' do
  impact 1.0
  title 'Ansible and the collections the Lockdown STIG role needs are installed at their pinned versions'
  desc 'ADR-0001 Phase 3: ansible-core from the distribution at the version pinned in group_vars ' \
       '(tools group safbox-tools-3), and the collections the Ansible Lockdown RHEL10-STIG role ' \
       'requires, installed system-wide at their pinned versions so every user on the box can ' \
       'run Lockdown playbooks.'
  only_if('Ansible is not in expected_tools (tools group safbox-tools-3 switched off)') do
    tool_expected.call('ansible')
  end

  version = input('ansible_core_version')
  describe command('ansible --version') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^ansible \[core #{Regexp.escape(version)}\]$/) }
  end

  instance_exec('Ansible core', version, &status_row)

  listing = command('ansible-galaxy collection list --format json -p /usr/share/ansible/collections')
  installed = begin
    JSON.parse(listing.stdout).fetch('/usr/share/ansible/collections/ansible_collections', {})
  rescue JSON::ParserError
    {}
  end
  input('ansible_collections').each do |name, pinned|
    describe "collection #{name} in /usr/share/ansible/collections" do
      subject { installed.dig(name.to_s, 'version') }
      it { should cmp pinned.to_s }
    end
  end
end

control 'safbox-tools-4' do
  impact 1.0
  title 'HashiCorp Packer is installed at its pinned version with its license'
  desc 'ADR-0001 Phase 3 and Risks (Packer license): Packer is its own switchable tools group ' \
       '(safbox-tools-4) so a distributor can exclude it, and its Business Source License text ' \
       'ships beside the unmodified binary.'
  only_if('Packer is not in expected_tools (tools group safbox-tools-4 switched off)') do
    tool_expected.call('packer')
  end

  version = input('packer_version')
  describe command('CHECKPOINT_DISABLE=1 /usr/local/bin/packer version') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^Packer v#{Regexp.escape(version)}$/) }
  end

  instance_exec('Packer', version, &status_row)

  describe file('/usr/local/share/licenses/packer/LICENSE.txt') do
    it { should exist }
    its('content') { should match(/Business Source License/) }
  end
end
