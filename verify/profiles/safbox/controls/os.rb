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
  desc 'A SAFBox is headless unless it was built with the desktop: no display manager, booting to the text console. A desktop SAFBox boots to the GNOME login screen, which shows the SAF logo, and gives every new user the SAF wallpaper, profile picture and terminal palette, and Firefox in the dash beside the distribution\'s default favourites, as defaults the user can change.'

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
     '/etc/dconf/db/local.d/10-safbox-shell',
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

    # The dash: GNOME Shell's default favourites on EL10, in order, with the
    # RPM Firefox's desktop file first (the default names only the Flatpak's).
    favorites = %w[firefox.desktop org.mozilla.Firefox.desktop org.gnome.Calendar.desktop
                   org.gnome.Nautilus.desktop org.gnome.Software.desktop org.gnome.Ptyxis.desktop
                   org.gnome.TextEditor.desktop org.gnome.Calculator.desktop]
    describe ini('/etc/dconf/db/local.d/10-safbox-shell') do
      its(['org/gnome/shell', 'favorite-apps']) { should eq "[#{favorites.map { |app| "'#{app}'" }.join(', ')}]" }
    end
    describe file('/usr/share/applications/firefox.desktop') do
      it { should be_file }
    end

    # Defaults, not locks: a user may choose another wallpaper or palette,
    # and pin or unpin apps in the dash.
    describe command('grep -rhxE "/org/gnome/((desktop/background|Ptyxis)/.*|shell/favorite-apps)" /etc/dconf/db/local.d/locks') do
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

control 'safbox-os-4' do
  impact 0.3
  title 'The desktop console starts at 1920x1080'
  desc "The console's display adapter prefers 1024x768 until a console client sends its window size, and GNOME cannot follow the client's window on it. GNOME's system-wide monitor configuration gives the login screen and every session 1920x1080 on that display (Virtual-1, which has no EDID), in physical layout mode; a user may choose another size in Settings, which GNOME keeps in the user's own configuration."
  only_if('This is not a desktop build', impact: 0.0) { input('desktop') }

  monitors = '/etc/xdg/monitors.xml'
  describe file(monitors) do
    it { should be_file }
    its('owner') { should eq 'root' }
    its('group') { should eq 'root' }
    its('mode') { should cmp '0644' }
  end
  describe xml(monitors) do
    its(['/monitors/@version']) { should eq ['2'] }
    its(['//configuration/layoutmode']) { should eq ['physical'] }
    its(['//monitorspec/connector']) { should eq ['Virtual-1'] }
    its(['//monitorspec/vendor']) { should eq ['unknown'] }
    its(['//monitorspec/product']) { should eq ['unknown'] }
    its(['//monitorspec/serial']) { should eq ['unknown'] }
    its(['//monitor/mode/width']) { should eq ['1920'] }
    its(['//monitor/mode/height']) { should eq ['1080'] }
    its(['//monitor/mode/rate']) { should eq ['60.000'] }
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

control 'safbox-initramfs-1' do
  impact 0.5
  title 'Every kernel boots from a host-only initramfs that adds each supported hypervisor\'s disk drivers'
  desc 'A host-only initramfs carries only the drivers of the machine it was made on, the build VM\'s, so a clone on another hypervisor\'s disk controller never finds its root disk. A dracut drop-in adds the drivers in input initramfs_drivers to every initramfs dracut makes, now and for later kernels, and each installed kernel\'s holds them. The initramfs stays host-only: a generic one (dracut-config-generic) also carries every GPU\'s firmware, and the desktop image\'s then leaves no room in /boot for the kernels dnf keeps.'

  drivers = input('initramfs_drivers')
  describe package('dracut-config-generic') do
    it { should_not be_installed }
  end
  describe file('/etc/dracut.conf.d/90-safbox-storage-drivers.conf') do
    it { should be_file }
    it { should be_owned_by 'root' }
    its('mode') { should cmp '0644' }
    drivers.each do |driver|
      its('content') { should match(/^add_drivers\+=" (.* )?#{Regexp.escape(driver)}( .*)? "$/) }
    end
  end
  images = command("find /boot -maxdepth 1 -name 'initramfs-*.img'").stdout.split.reject { |path| path.match?(/rescue|kdump/) }
  describe 'Initramfs images of the installed kernels' do
    subject { images }
    it { should_not be_empty }
  end
  images.each do |image|
    describe command("lsinitrd #{image}") do
      its('exit_status') { should eq 0 }
      drivers.each do |driver|
        its('stdout') { should match(%r{/#{Regexp.escape(driver)}\.ko(\.[a-z]+)?$}) }
      end
    end
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

# The guest agents the image ships, keyed by the hypervisor each serves
# (input guest_agents, from the install layer's answer file), with string
# keys whichever way the inputs were read; and the hypervisor this box runs
# on, as systemd detects it.
guest_agents = input('guest_agents').to_h { |virt, agent| [virt.to_s, agent.to_h.transform_keys(&:to_s)] }
detected_virt = command('systemd-detect-virt').stdout.strip

control 'safbox-system-1' do
  impact 1.0
  title 'The guest agent for this hypervisor, cloud-init, sshd and chronyd are enabled and running, and the firewall allows SSH'
  desc 'A clone is configured by cloud-init, reports its address through the guest agent, keeps time and is reached over SSH through the firewall. The image carries a guest agent for each hypervisor it runs on (input guest_agents); the one for the hypervisor systemd detects must run, and every one is installed and enabled, so it starts when the image moves to its hypervisor.'

  describe "The guest agent for the detected hypervisor (#{detected_virt})" do
    subject { guest_agents[detected_virt] }
    it { should_not be_nil }
  end
  guest_agents.each_value do |agent|
    describe package(agent['package']) do
      it { should be_installed }
    end
    describe service(agent['service']) do
      it { should be_enabled }
    end
  end
  if guest_agents.key?(detected_virt)
    describe service(guest_agents[detected_virt]['service']) do
      it { should be_running }
    end
  end
  %w[cloud-init sshd chronyd].each do |name|
    describe service(name) do
      it { should be_enabled }
    end
  end
  %w[sshd chronyd].each do |name|
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

  # 15 lines leaves room for the STIG banner and the prompt on an 80x24
  # console.
  describe file('/etc/motd.d/safbox').content.to_s.lines.count do
    it { should be <= 15 }
  end
end

control 'safbox-guest-agent-1' do
  impact 1.0
  title 'No guest agent can run commands or touch files in the guest'
  desc 'A guest agent that runs programs or reads and writes files on request (qemu-guest-agent\'s guest-exec and guest-file-*, open-vm-tools\' guest operations) would let a hypervisor administrator into the appliance. Each agent the image ships (input guest_agents) is the package as shipped, its own configuration unmodified, and keeps those off: by the command line the running agent was given (the distribution\'s allow list), or by the settings of the configuration file the install layer writes, which hold on every hypervisor because the image moves between them.'

  guest_agents.each do |virt, agent|
    describe command("rpm -V #{agent['package']}") do
      its('stdout') { should be_empty }
    end
    if agent['config_file']
      describe file(agent['config_file']) do
        it { should be_file }
      end
      describe ini(agent['config_file']) do
        agent['settings'].to_h.each do |section, keys|
          keys.to_h.each do |key, value|
            its([section.to_s, key.to_s]) { should cmp value.to_s }
          end
        end
      end
    end
    next unless virt == detected_virt && (agent['cmdline_includes'] || agent['cmdline_excludes'])

    pid = service(agent['service']).params['MainPID']
    describe file("/proc/#{pid}/cmdline") do
      Array(agent['cmdline_includes']).each do |pattern|
        its('content') { should include pattern }
      end
      Array(agent['cmdline_excludes']).each do |pattern|
        its('content') { should_not include pattern }
      end
    end
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
