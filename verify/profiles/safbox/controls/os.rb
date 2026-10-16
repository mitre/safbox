# frozen_string_literal: true

control 'safbox-os-1' do
  impact 1.0
  title 'The operating system is Rocky Linux 10 or AlmaLinux 10'
  desc 'SAFBox is built on the RHEL 10 family.'

  describe os do
    its('name') { should be_in %w[rocky almalinux] }
    its('release') { should match(/^10(\.|$)/) }
  end
end

control 'safbox-os-2' do
  impact 1.0
  title 'The CPU supports the x86-64 level the image was built for'
  desc 'Rocky Linux 10 needs x86-64-v3; the AlmaLinux development build runs on x86-64-v2.'

  describe command('/lib64/ld-linux-x86-64.so.2 --help') do
    its('stdout') { should match(/x86-64-v[234] \(supported/) }
  end
end

control 'safbox-secureboot-1' do
  impact 1.0
  title 'UEFI Secure Boot is enabled'
  desc 'The image boots with Secure Boot enforced, so the signed FIPS kernel is the one that runs.'

  describe command('mokutil --sb-state') do
    its('stdout') { should match(/^SecureBoot enabled$/) }
  end
end

control 'safbox-fips-1' do
  impact 1.0
  title 'The kernel runs in FIPS mode, enabled at install'
  desc 'FIPS mode is set on the kernel command line at installation and cannot be turned on later.'

  describe kernel_parameter('crypto.fips_enabled') do
    its('value') { should eq 1 }
  end
  describe file('/proc/cmdline') do
    its('content') { should match(/(^|\s)fips=1(\s|$)/) }
  end
end

control 'safbox-fips-2' do
  impact 1.0
  title 'The system-wide crypto policy is FIPS'
  desc 'Any other policy lets programs negotiate algorithms outside the validated module.'

  describe command('update-crypto-policies --show') do
    its('stdout.strip') { should eq 'FIPS' }
  end
end

control 'safbox-fips-3' do
  impact 1.0
  title 'The OpenSSL FIPS provider is active'
  desc 'Without it, programs that use OpenSSL fall back to unvalidated code.'

  describe command('openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
end

control 'safbox-system-1' do
  impact 1.0
  title 'The guest agent, cloud-init, sshd and chronyd are enabled and the firewall allows SSH'
  desc 'A clone is configured by cloud-init, reports its address through the guest agent, keeps time and is reached over SSH through the firewall.'

  %w[qemu-guest-agent cloud-init sshd chronyd].each do |name|
    describe service(name) do
      it { should be_enabled }
    end
  end
  %w[qemu-guest-agent sshd chronyd].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe firewalld do
    it { should be_running }
    it { should have_service_enabled_in_zone('ssh', firewalld.default_zone) }
  end
end

control 'safbox-system-3' do
  impact 1.0
  title 'The journal is kept on disk'
  desc 'journald stores the journal persistently, so first-boot and security logs survive a reboot.'

  describe parse_config_file('/etc/systemd/journald.conf.d/10-safbox.conf') do
    its('Journal.Storage') { should eq 'persistent' }
  end
end

control 'safbox-guest-agent-1' do
  impact 1.0
  title 'The guest agent cannot run commands or touch files in the guest'
  desc 'With guest-exec or guest-file-* enabled, a hypervisor administrator could run commands and read or write files inside the appliance. The distribution allow list leaves them out and must be unmodified.'

  agent = service('qemu-guest-agent').params['MainPID']
  describe file("/proc/#{agent}/cmdline") do
    its('content') { should match(/--allow-rpcs=/) }
    its('content') { should_not match(/guest-exec|guest-file-/) }
  end
  describe command('rpm -V qemu-guest-agent') do
    its('stdout') { should be_empty }
  end
end

control 'safbox-podman-1' do
  impact 1.0
  title 'podman is installed, with fully qualified image names and read access to the host CA trust store'
  desc 'Services run as podman Quadlet units; short image names are refused, and containers may read the host CA trust store.'

  describe package('podman') do
    it { should be_installed }
  end
  describe toml('/etc/containers/registries.conf.d/50-safbox.conf') do
    its('short-name-mode') { should eq 'enforcing' }
  end
  describe selinux.booleans.where(name: 'container_read_certs') do
    it { should be_on }
  end
end

control 'safbox-podman-2' do
  impact 1.0
  title 'The example Quadlet unit runs'
  desc 'A build that installs the example container proves Quadlet units start at boot.'
  only_if('The example container is not installed', impact: 0.0) do
    file('/etc/containers/systemd/safbox-example.container').exist?
  end

  describe service('safbox-example') do
    it { should be_running }
  end
end

control 'safbox-trust-1' do
  impact 1.0
  title 'The site CA roots are in the system trust store'
  desc 'The DoD PKI roots, or the bundles a site configures, are trusted by OpenSSL, curl and the containers.'

  trusted = command('trust list --filter=ca-anchors').stdout
  input('trusted_roots').each do |label|
    describe "#{label} in the system trust store" do
      subject { trusted }
      it { should match(/^\s+label: #{Regexp.escape(label)}$/) }
    end
  end
end
