# frozen_string_literal: true

control 'safbox-accounts-1' do
  impact 1.0
  title 'No distribution default user exists'
  desc 'Cloud images create a default account with passwordless sudo. A SAFBox has only the accounts its deployer asked for.'

  %w[cloud-user almalinux rocky ubuntu debian].each do |name|
    describe user(name) do
      it { should_not exist }
    end
  end
end

control 'safbox-accounts-2' do
  impact 1.0
  title 'cloud-init creates no user unless the deployment asks for one'
  desc 'The system configuration sets users to an empty list, so a boot without user data creates no default account.'

  describe yaml('/etc/cloud/cloud.cfg.d/80-safbox-users.cfg') do
    its('users') { should eq [] }
  end
end
