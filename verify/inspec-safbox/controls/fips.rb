# frozen_string_literal: true

control 'safbox-fips-1' do
  impact 1.0
  title 'FIPS mode is enabled and was set at install'
  desc 'ADR-0001: FIPS mode is on from installation and is not configurable afterward. ' \
       'The kernel must report fips_enabled=1 and fips=1 must be on the command line.'
  only_if('FIPS is not required for this image') { input('fips_required') }

  describe file('/proc/sys/crypto/fips_enabled') do
    it { should exist }
    its('content.strip') { should cmp '1' }
  end

  describe file('/proc/cmdline') do
    its('content') { should match(/(^|\s)fips=1(\s|$)/) }
  end
end

control 'safbox-fips-2' do
  impact 1.0
  title 'The system-wide crypto policy is FIPS'
  desc 'A FIPS install sets the crypto-policies level to FIPS; any other policy lets userland ' \
       'negotiate algorithms outside the validated module.'
  only_if('FIPS is not required for this image') { input('fips_required') }
  only_if('crypto-policies is the RHEL family mechanism') { os.redhat? }

  describe command('update-crypto-policies --show') do
    its('exit_status') { should eq 0 }
    its('stdout.strip') { should cmp 'FIPS' }
  end
end

control 'safbox-fips-3' do
  impact 1.0
  title 'The OpenSSL FIPS provider is loaded and active'
  desc 'In FIPS mode OpenSSL 3 must load its FIPS provider; without it, libraries fall back to ' \
       'unvalidated implementations.'
  only_if('FIPS is not required for this image') { input('fips_required') }

  describe command('openssl list -providers') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
end
