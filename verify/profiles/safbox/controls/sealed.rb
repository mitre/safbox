# frozen_string_literal: true

# The seal runs at the end of the build: it records the build, deletes the
# build user and removes installer residue. First boot then runs once on
# each deployed clone.

deployed = input('deployed')

control 'safbox-build-info-1' do
  impact 1.0
  title 'The build record names the commit, the distribution, a full seal and the exact build of each unpinned package'
  desc 'The seal writes a world-readable record of the build, so a development image is never mistaken for a release one. It names the exact build of each package the install layer installs without a version pin: cloud-init and every guest agent (input guest_agents).'
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
  # The install layer installs these without a version pin; the record
  # names the exact build of each.
  unpinned = %w[cloud-init] +
             input('guest_agents').values.map { |agent| agent.to_h.transform_keys(&:to_s)['package'] }
  describe parse_config_file('/usr/local/share/safbox/build-info') do
    unpinned.each do |name|
      its('SAFBOX_UNPINNED_PACKAGES') { should match(/(^| )#{Regexp.escape(name)}-[0-9]/) }
    end
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
  title 'The first-boot unit is installed and enabled to run the first-boot play once'
  desc 'A one-shot unit runs the first-boot play locally with the box\'s own ansible-core; the play\'s last task leaves a marker, so it never runs again. The play, its configuration, its vars and the services\' secret lists run as root, so only root can change them. Its configuration keeps module invocations out of the system log and Ansible\'s temporary files in the unit\'s runtime directory. The build writes the vars from the site\'s switches, which decide the roles the play runs: admin\'s part of clone_accounts when safbox_base_6 is on (the box has an admin_user), safuser\'s when safbox_base_5 is, clone_secrets when Heimdall, Vulcan or Keycloak is, clone_proxy_tls when the proxy is; clone_grow_disk always runs and hands a clone\'s larger disk to the growing volumes. Only the first-boot roles (clone_) ship, none of the build\'s (template_).'

  play_dir = '/usr/local/lib/safbox/firstboot'
  describe service('safbox-firstboot') do
    it { should be_enabled }
  end
  describe parse_config_file('/etc/systemd/system/safbox-firstboot.service') do
    its('Unit.ConditionPathExists') { should eq '!/var/lib/safbox/firstboot.done' }
    its('Service.Type') { should eq 'oneshot' }
    its('Service.ExecStart') { should eq "/usr/bin/ansible-playbook -c local -i localhost, #{play_dir}/firstboot.yml" }
    its('Service.Environment') { should match(%r{(\A| )ANSIBLE_CONFIG=#{play_dir}/ansible\.cfg( |\z)}) }
    its('Service.RuntimeDirectory') { should eq 'safbox-firstboot' }
  end
  %w[firstboot.yml ansible.cfg vars.yml roles/clone_grow_disk/tasks/main.yml roles/clone_grow_disk/files/grow-disk.sh
     roles/clone_accounts/tasks/main.yml roles/clone_secrets/tasks/main.yml
     roles/clone_proxy_tls/tasks/main.yml roles/clone_heimdall_scans/tasks/main.yml].each do |name|
    describe file("#{play_dir}/#{name}") do
      it { should be_file }
    end
  end
  describe command("find #{play_dir}/roles -mindepth 1 -maxdepth 1 ! -name 'clone_*' -print") do
    its('stdout') { should eq '' }
    its('exit_status') { should eq 0 }
  end
  describe command("find #{play_dir} \\( ! -user root -o -perm /022 \\) -print") do
    its('stdout') { should eq '' }
    its('exit_status') { should eq 0 }
  end
  describe ini("#{play_dir}/ansible.cfg") do
    its('defaults.no_target_syslog') { should cmp 'True' }
    its('defaults.local_tmp') { should eq '/run/safbox-firstboot/ansible' }
    its('defaults.remote_tmp') { should eq '/run/safbox-firstboot/ansible' }
  end
  services = input('expected_services')
  describe yaml("#{play_dir}/vars.yml") do
    its('safbox_firstboot_done') { should eq '/var/lib/safbox/firstboot.done' }
    its('safbox_base_6') { should eq !input('admin_user').empty? }
    its('safbox_base_5') { should eq input('safuser') }
    its('safbox_services_1') { should eq services.include?('heimdall') }
    its('safbox_services_2') { should eq services.include?('vulcan') }
    its('safbox_services_5') { should eq services.include?('keycloak') }
    its('safbox_services_3') { should eq services.include?('proxy') }
  end
end

control 'safbox-firstboot-2' do
  impact 1.0
  title 'First boot completed on the deployed clone and logged no secret'
  desc 'The unit ran the play to its end, whose last task leaves the completion marker. Every task that handles a password or a key is no_log, so the journal holds none of the secrets first boot made: safuser\'s generated password, the two private keys and every podman secret it made for the services. One exception is upstream behaviour, not first boot\'s: Heimdall prints its administrator\'s password in its own log on its first start, so that secret is looked for in first boot\'s log only.'
  only_if('This is not a deployed clone', impact: 0.0) { deployed }

  describe file('/var/lib/safbox/firstboot.done') do
    it { should exist }
    its('owner') { should eq 'root' }
    its('mode') { should cmp '0600' }
  end
  describe service('safbox-firstboot') do
    its('params.Result') { should eq 'success' }
  end
  # Each secret is read into grep's pattern file, never onto a command
  # line, and only the number of journal lines holding it is printed.
  {
    'safuser\'s generated password' => 'sed -n s/^SAFUSER_PASSWORD=//p /etc/safbox/safuser.env',
    'the local CA\'s private key' => 'grep -v -- ----- /etc/safbox/ca/ca.key',
    'the proxy\'s private key' => 'grep -v -- ----- /etc/safbox/tls/safbox.key',
  }.each do |secret, read|
    describe "Journal lines holding #{secret}" do
      subject { command(%(bash -c 'journalctl -o cat --no-pager | grep -cF -f <(#{read} 2>/dev/null | grep .)')).stdout.strip }
      it { should cmp 0 }
    end
  end
  command("podman secret ls --noheading --format '{{.Name}}'").stdout.split.each do |name|
    journal = name == 'heimdall-admin-password' ? 'journalctl -o cat --no-pager -u safbox-firstboot.service' : 'journalctl -o cat --no-pager'
    describe "Journal lines holding the podman secret #{name}" do
      subject { command(%(bash -c '#{journal} | grep -cF -f <(podman secret inspect --showsecret --format "{{.SecretData}}" #{name} | grep .)')).stdout.strip }
      it { should cmp 0 }
    end
  end
end

control 'safbox-firstboot-3' do
  impact 1.0
  title 'Every unit the build enables stays enabled through a First Boot preset'
  desc 'The seal leaves /etc/machine-id "uninitialized", so a clone\'s first boot is a systemd First Boot, which may reset every unit to its preset policy, and the distribution\'s presets end in "disable *". SAFBox\'s one preset file (/etc/systemd/system-preset/50-safbox.preset) enables each unit the build enables, SAFBox\'s own (by pattern) and usbguard (when the build enables it: the usbguard input), which the STIG requires and the distribution presets disable, so a First Boot preset leaves them enabled. Quadlet-generated units have no preset state.'

  units = %w[safbox-firstboot.service safbox-aide-init.service]
  units << 'usbguard.service' if input('usbguard')
  units += %w[safbox-site-status.service safbox-site-status.timer safbox-proxy-renew.timer] if input('expected_services').include?('proxy')
  # Any other SAFBox unit that can be enabled is held to the same rule
  # (no backslash in the pattern, so no quoting layer can drop one).
  units |= command('grep -l "^[[]Install[]]" /etc/systemd/system/safbox-*.service /etc/systemd/system/safbox-*.timer').stdout.split.map { |path| File.basename(path) }
  units.each do |unit|
    describe "#{unit}: its state and its preset" do
      subject { command("systemctl list-unit-files --no-legend --no-pager #{unit}").stdout.split[1, 2] }
      it { should eq %w[enabled enabled] }
    end
  end
end
