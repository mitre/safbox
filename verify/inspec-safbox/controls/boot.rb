# frozen_string_literal: true

control 'safbox-secureboot-1' do
  impact 0.7
  title 'UEFI Secure Boot is enabled'
  desc 'The install layer boots the image with Secure Boot enforced; the shim and kernel signature ' \
       'chain is what makes the FIPS kernel the kernel that actually runs.'
  only_if('Secure Boot is not required for this image') { input('secure_boot_required') }

  describe command('mokutil --sb-state') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^SecureBoot enabled$/) }
  end
end
