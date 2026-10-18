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

control 'safbox-os-3' do
  impact 1.0
  title 'The console boots to the interface the image was built for'
  desc 'A SAFBox is headless unless it was built with the desktop: no display manager, booting to the text console. A desktop SAFBox boots to the GNOME login screen, which shows the SAF logo, and gives every new user the SAF wallpaper, profile picture and terminal palette as defaults the user can change.'

  if input('desktop')
    describe package('gdm') do
      it { should be_installed }
    end
    describe service('gdm') do
      it { should be_enabled }
    end
    describe command('systemctl get-default') do
      its('stdout.strip') { should eq 'graphical.target' }
    end

    navy = '/usr/share/backgrounds/safbox/saf-navy-3440x1440.png'
    logo = '/usr/share/pixmaps/saf-logo.svg'
    avatar = '/usr/share/pixmaps/saf-avatar.png'
    terminal_profile = 'a64f2cd413c97b9f9cdb8f7438946c23'

    # The branding files, and the settings files that name them.
    [navy, logo, avatar, '/etc/skel/.local/share/org.gnome.Ptyxis/palettes/saf.palette',
     '/usr/share/gnome-background-properties/safbox.xml',
     '/etc/dconf/db/gdm.d/10-safbox-logo',
     '/etc/dconf/db/local.d/10-safbox-background',
     '/etc/dconf/db/local.d/10-safbox-terminal',
     '/etc/accountsservice/user-templates/standard',
     '/etc/accountsservice/user-templates/administrator'].each do |path|
      describe file(path) do
        it { should be_file }
      end
    end

    describe file('/usr/share/gnome-background-properties/safbox.xml') do
      its('content') { should include "<filename>#{navy}</filename>" }
    end
    describe ini('/etc/dconf/db/gdm.d/10-safbox-logo') do
      its(['org/gnome/login-screen', 'logo']) { should eq "'#{logo}'" }
    end
    describe ini('/etc/dconf/db/local.d/10-safbox-background') do
      its(['org/gnome/desktop/background', 'picture-uri']) { should eq "'file://#{navy}'" }
      its(['org/gnome/desktop/background', 'picture-uri-dark']) { should eq "'file://#{navy}'" }
    end
    %w[standard administrator].each do |template|
      describe ini("/etc/accountsservice/user-templates/#{template}") do
        its(%w[User Icon]) { should eq avatar }
      end
    end
    describe ini('/etc/dconf/db/local.d/10-safbox-terminal') do
      its(['org/gnome/Ptyxis', 'default-profile-uuid']) { should eq "'#{terminal_profile}'" }
      its(["org/gnome/Ptyxis/Profiles/#{terminal_profile}", 'palette']) { should eq "'saf'" }
    end

    # Defaults, not locks: a user may choose another wallpaper or palette.
    describe command('grep -rhxE "/org/gnome/(desktop/background|Ptyxis)/.*" /etc/dconf/db/local.d/locks') do
      its('stdout') { should be_empty }
    end
  else
    describe package('gdm') do
      it { should_not be_installed }
    end
    describe command('systemctl get-default') do
      its('stdout.strip') { should eq 'multi-user.target' }
    end
  end
end

control 'safbox-disk-1' do
  impact 0.5
  title 'The disk is in use to its end, and /home, /var, /var/log and /var/log/audit hold their shares of it'
  desc 'The volume group fills the disk. After the fixed-size volumes (/, /tmp, /var/tmp and swap), /home gets 40% of its space, /var 40%, /var/log 10% and /var/log/audit 10%, at install and again on the first boot of a clone whose disk was enlarged. A share may fall short by one percentage point for rounding.'
  only_if('The host does not have the vg_safbox volume group', impact: 0.0) do
    command('vgs vg_safbox').exit_status.zero?
  end

  pv_name, pv_bytes = command('pvs --noheadings --units b --nosuffix -o pv_name,dev_size -S vg_name=vg_safbox').stdout.split
  disk = command("lsblk -dno PKNAME #{pv_name}").stdout.strip
  lv_bytes = command('lvs --noheadings --units b --nosuffix -o lv_name,lv_size vg_safbox').stdout.split.each_slice(2).to_h
  shared = pv_bytes.to_i - lv_bytes.values_at('root', 'tmp', 'var_tmp', 'swap').sum(&:to_i)

  describe command("growpart --dry-run /dev/#{disk} #{pv_name.to_s[/\d+$/]}") do
    its('stdout') { should match(/^NOCHANGE:/) }
  end
  { 'home' => 40, 'var' => 40, 'var_log' => 10, 'var_log_audit' => 10 }.each do |lv, share|
    describe "Logical volume #{lv} (bytes)" do
      subject { lv_bytes[lv].to_i }
      it { should be >= shared * (share - 1) / 100 }
    end
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

control 'safbox-logging-1' do
  impact 1.0
  title 'rsyslog writes the local log files'
  desc 'rsyslog copies the journal into /var/log/messages, and authentication messages into /var/log/secure, the files the STIG and an administrator read. An rsyslog forwarding action with no target server (Lockdown RHEL-10-200646 applied without a remote log server) suspends rsyslog, and both files stop growing seconds after boot. The control logs a message of each kind, unique to this scan, and waits up to 20 seconds for it to arrive, three times with a fresh message. Rate limiting can also keep a message out of the files (journald per service, rsyslog imjournal for the whole journal); a failure prints the rate-limit messages journald and rsyslog logged since boot, so the two causes can be told apart.'

  describe command(%q(grep -rlsE "target\s*=\s*(\"\"|'')" /etc/rsyslog.conf /etc/rsyslog.d)) do
    its('stdout') { should be_empty }
  end

  marker = "safbox-logging-1-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%NZ')}"
  { 'user.info' => '/var/log/messages', 'authpriv.info' => '/var/log/secure' }.each do |priority, log|
    # sh -c, so the whole command runs with the scan's sudo, not only logger.
    script = "for try in 1 2 3; do m=#{marker}-#{priority}-$try; " \
             "logger -t safbox-logging-1 -p #{priority} $m; " \
             "for _ in $(seq 20); do grep -qF $m #{log} && exit 0; sleep 1; done; done; " \
             "echo no #{priority} test message reached #{log} in 3 tries; " \
             'journalctl -b --no-pager -o short-iso -u systemd-journald -u rsyslog --grep "Suppressed|rate-limit" | tail -n 5; exit 1'
    describe command("sh -c '#{script}'") do
      its('stdout') { should be_empty }
      its('exit_status') { should eq 0 }
    end
  end
end

control 'safbox-motd-1' do
  impact 1.0
  title 'Logins show the SAF greeting'
  desc 'The message of the day shows the SAF shield and "Welcome to SAFBox!" after every console and SSH login. The login banner before it (/etc/issue) is separate.'

  describe file('/etc/motd.d/safbox') do
    it { should be_file }
    its('mode') { should cmp '0644' }
    its('content') { should include 'Welcome to SAFBox!' }
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
