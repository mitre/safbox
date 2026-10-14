# frozen_string_literal: true

# Merged cloud-init system configuration (cloud.cfg plus cloud.cfg.d), as
# cloud-init itself reads it, so the check follows cloud-init's merge rules
# rather than any one file.
cloud_cfg_script = 'import json; from cloudinit import util; ' \
                   'c = util.read_conf_with_confd("/etc/cloud/cloud.cfg"); ' \
                   'print(json.dumps({"users": c.get("users"), ' \
                   '"default_user": c.get("system_info", {}).get("default_user", {}).get("name")}))'
cloud_cfg_cmd = command("python3 -c '#{cloud_cfg_script}'")
cloud_cfg = cloud_cfg_cmd.exit_status.zero? ? JSON.parse(cloud_cfg_cmd.stdout) : {}

control 'safbox-accounts-1' do
  impact 1.0
  title 'No distribution default user exists'
  desc 'Distribution cloud images create a default account with passwordless sudo. A SAFBox has only ' \
       'the accounts its deployer asked for; a default account nobody configured is an unmanaged root path.'

  (input('distro_default_users') + [cloud_cfg['default_user']]).compact.uniq.each do |name|
    describe user(name) do
      it { should_not exist }
    end
  end
end

control 'safbox-accounts-2' do
  impact 1.0
  title 'cloud-init creates no default user unless a datasource asks for one'
  desc 'The system configuration sets users to an empty list, so a boot without user data (the build ' \
       'VM, or a clone deployed without a user) creates no default account. User data that names a ' \
       'user, as a deployment does, still gets one built from the distribution default_user definition.'

  describe 'merged cloud-init system configuration' do
    subject { cloud_cfg_cmd }
    its('exit_status') { should eq 0 }
  end

  describe 'cloud-init system users' do
    subject { cloud_cfg['users'] }
    it { should eq [] }
  end

  describe 'cloud-init default_user definition (used when user data names a user)' do
    subject { cloud_cfg['default_user'] }
    it { should_not be_nil }
  end
end
