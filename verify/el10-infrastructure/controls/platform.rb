# frozen_string_literal: true

os_release = file('/etc/os-release').content.to_s
os_release_value = lambda do |key|
  os_release[/^#{key}="?([^"\n]*)"?$/, 1]
end

control 'safbox-platform-1' do
  impact 1.0
  title 'The operating system is one the appliance layer supports'
  desc 'ADR-0001: RHEL 10 family for v1 (Rocky Linux 10 or AlmaLinux 10); Debian family untested but present.'

  describe os.family do
    it { should be_in %w[redhat debian] }
  end

  if os.redhat?
    describe 'PLATFORM_ID in /etc/os-release' do
      subject { os_release_value.call('PLATFORM_ID') }
      it { should cmp input('expected_platform_id') }
    end
    describe os.release.to_s do
      it { should match(/^10(\.|$)/) }
    end
  end
end

control 'safbox-platform-2' do
  impact 1.0
  title 'The distribution and microarchitecture level of the running image are recorded'
  desc 'ADR-0001 Risks: validation records which distribution and microarchitecture level an image ' \
       'was built from so a lab artifact is never mistaken for a release artifact. The values appear ' \
       'in the test descriptions of this control: the package architecture is what the image was ' \
       'built from (x86_64_v2 on the AlmaLinux v2 media), the loader level is what this CPU supports.'

  describe "distribution #{os_release_value.call('PRETTY_NAME')} (#{os.arch})" do
    subject { os.name }
    it { should_not be_nil }
  end

  package_arch = if os.redhat?
                   command("rpm -q --qf '%{ARCH}' glibc").stdout.strip
                 else
                   command('dpkg --print-architecture').stdout.strip
                 end
  describe "image package architecture #{package_arch}" do
    subject { package_arch }
    it { should match(/^(x86_64(_v[234])?|aarch64|amd64|arm64)$/) }
  end

  loader = command('/lib64/ld-linux-x86-64.so.2 --help')
  if loader.exit_status.zero?
    level = loader.stdout[/x86-64-v\d+(?= \(supported)/] || 'none'
    describe "highest microarchitecture level this CPU supports #{level}" do
      subject { level }
      it { should match(/^x86-64-v[234]$/) }
    end
  else
    describe "microarchitecture level not applicable on #{os.arch}" do
      subject { os.arch }
      it { should_not eq 'x86_64' }
    end
  end
end
