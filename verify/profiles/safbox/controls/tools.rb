# frozen_string_literal: true

tools = input('expected_tools')

control 'safbox-cli-1' do
  impact 1.0
  title 'The safbox status command works'
  desc 'safbox status shows any user the distribution, FIPS mode, first boot, tool versions and service states.'

  describe command('/usr/local/bin/safbox status') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^FIPS mode:\s+enabled/) }
  end
end

control 'safbox-tools-1' do
  impact 1.0
  title 'CINC Auditor is installed at its pinned version'
  desc 'CINC Auditor runs InSpec profiles on the box.'
  only_if('CINC Auditor is switched off', impact: 0.0) { tools.include?('cinc-auditor') }

  describe package('cinc-auditor') do
    it { should be_installed }
    its('version') { should match(/^#{Regexp.escape(input('cinc_auditor_version'))}-/) }
  end
end

control 'safbox-tools-2' do
  impact 1.0
  title 'The SAF CLI is installed at its pinned version on a FIPS-mode Node.js'
  desc "The SAF CLI is installed from npm and runs on the distribution's Node.js, which uses the system OpenSSL FIPS provider."
  only_if('The SAF CLI is switched off', impact: 0.0) { tools.include?('saf-cli') }

  describe json('/usr/local/lib/node_modules/@mitre/saf/package.json') do
    its('version') { should cmp input('saf_cli_version') }
  end
  describe file('/usr/local/bin/saf') do
    it { should be_executable }
  end
  describe command(%q(node -p "require('crypto').getFips()")) do
    its('stdout.strip') { should eq '1' }
  end
end

control 'safbox-tools-3' do
  impact 1.0
  title 'Ansible and the collections the Lockdown STIG role needs are installed at their pinned versions'
  desc 'ansible-core comes from the distribution; the collections are installed system-wide so every user can run Lockdown playbooks.'
  only_if('Ansible is switched off', impact: 0.0) { tools.include?('ansible') }

  describe package('ansible-core') do
    it { should be_installed }
    its('version') { should match(/^#{Regexp.escape(input('ansible_core_version'))}-/) }
  end
  input('ansible_collections').each do |name, version|
    namespace, collection = name.to_s.split('.')
    describe json("/usr/share/ansible/collections/ansible_collections/#{namespace}/#{collection}/MANIFEST.json") do
      its(%w[collection_info version]) { should cmp version.to_s }
    end
  end
end

control 'safbox-tools-4' do
  impact 1.0
  title 'HashiCorp Packer is installed at its pinned version with its license'
  desc 'Packer ships unmodified, with its Business Source License text beside it.'
  only_if('Packer is switched off', impact: 0.0) { tools.include?('packer') }

  describe command('/usr/local/bin/packer version') do
    its('stdout') { should match(/^Packer v#{Regexp.escape(input('packer_version'))}$/) }
  end
  describe file('/usr/local/share/licenses/packer/LICENSE.txt') do
    its('content') { should match(/Business Source License/) }
  end
end
