# frozen_string_literal: true

# SAFBox deviations from the RHEL 10 STIG baseline. Every baseline control is
# included; a requirement SAFBox deliberately does not apply is set Not
# Applicable here: impact 0.0, a justification, and a deliberate skip.
# The overrides are exactly the entries of
# ansible/roles/hardening/vars/deviations.yml, with the same justification
# text; scripts/deviations-check.sh fails if the two differ. Change both
# together.
include_controls 'redhat-enterprise-linux-10-stig-baseline' do
  control 'SV-280935' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      SAFBox is distributed as a virtual machine template and cannot encrypt
      its own disks. Any key that let the template boot unattended would be
      shared by every copy, so SAFBox does not presently provide encryption
      within the VM itself. Data at rest encryption should be implemented by
      the hypervisor or storage layer of the deploying environment.
    JUSTIFICATION
    describe 'Data at rest encryption within the SAFBox VM' do
      skip 'Not Applicable: cannot be implemented in a VM template; see the justification.'
    end
  end

  control 'SV-281197' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      SAFBox is an appliance for operators who may be its only administrator.
      A lock that only an administrator can release can leave nobody able to
      log in. Where pam_faillock locks an account, the lock instead expires
      after the pam_faillock default of 10 minutes.
    JUSTIFICATION
    describe 'An account lock that only an administrator can release' do
      skip 'Not Applicable: a usability deviation for single-operator appliances; see the justification.'
    end
  end

  control 'SV-281195' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      Root is the recovery account of last resort on the console of a SAFBox
      that may have a single operator. Locking it until an administrator
      releases it can leave the appliance unrecoverable without a rebuild.
    JUSTIFICATION
    describe 'Locking the root account until an administrator releases it' do
      skip 'Not Applicable: a usability deviation for single-operator appliances; see the justification.'
    end
  end

  control 'SV-281169' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      SAFBox deploy accounts are created at first boot, log in with an SSH key
      and have no password. Tested: once such an account's password passed the
      60-day maximum age, its key login was refused because a password change
      was required that a locked password cannot make.
    JUSTIFICATION
    describe '60-day maximum password lifetime for new users in /etc/login.defs' do
      skip 'Not Applicable: a usability deviation; see the justification.'
    end
  end

  control 'SV-281175' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      SAFBox deploy accounts log in with an SSH key and have no password to
      keep active. Tested: 35 days after such an account's password expired,
      PAM disabled the account and refused its key login.
    JUSTIFICATION
    describe 'Disable accounts after 35 days of inactivity' do
      skip 'Not Applicable: a usability deviation; see the justification.'
    end
  end

  control 'SV-281103' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      A panic on an audit processing failure would halt SAFBox and take its
      services down. SAFBox rotates its audit logs instead
      (max_log_file_action = ROTATE) and reports audit failures to the kernel
      log.
    JUSTIFICATION
    describe 'Panic the system on a critical audit processing failure' do
      skip 'Not Applicable: a usability deviation; see the justification.'
    end
  end

  # Not Applicable only until a site names its remote log server (input
  # remote_log_server, set with group_vars safbox_remote_log_server); then
  # the baseline control runs unchanged. InSpec holds an empty input as
  # having no value, hence has_value?.
  control 'SV-280985' do
    unless input_object('remote_log_server').has_value?
      impact 0.0
      desc 'justification', <<~JUSTIFICATION
        The remote log server is the deploying site's. SAFBox forwards no logs
        until a site names its server (safbox_remote_log_server); the rule is
        then applied and this control evaluated.
      JUSTIFICATION
      describe 'Forwarding audit records to a remote log server' do
        skip 'Not Applicable: provided by the deploying site; see the justification.'
      end
    end
  end

  control 'SV-280987' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      Remote log offload is provided by the deploying site's log server.
      SAFBox ships without one to authenticate.
    JUSTIFICATION
    describe 'Authenticate the remote logging server for off-loading audit logs via rsyslog' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-280988' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      Remote log offload is provided by the deploying site's log server.
      SAFBox ships without one to send encrypted records to.
    JUSTIFICATION
    describe 'Encrypt audit records off-loaded via rsyslog' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-281338' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      Name servers are provided by the deploying site's network, through DHCP
      or cloud-init.
    JUSTIFICATION
    describe 'At least two name servers configured' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-281325' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      PKI-based multifactor authentication is provided by the deploying site's
      PKI and identity service. SAFBox ships without one.
    JUSTIFICATION
    describe 'Certificate status checking for multifactor authentication' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-281329' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      The trust anchors for PKI-based authentication are provided by the
      deploying site's PKI. SAFBox ships without one.
    JUSTIFICATION
    describe 'Validate PKI certificates by constructing a certification path to an accepted trust anchor' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-281330' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      The mapping of PKI identities to accounts is provided by the deploying
      site's identity service. SAFBox ships without one.
    JUSTIFICATION
    describe 'Map the authenticated PKI identity to a user or group account' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-281166' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      A boot loader password baked into the template would be shared by every
      copy. The deploying site sets it (grub2-setpassword).
    JUSTIFICATION
    describe 'Require a boot loader superuser password' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end

  control 'SV-281167' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      The boot loader superuser and its password are set by the deploying
      site, so that no copy of the template shares them.
    JUSTIFICATION
    describe 'Require a unique boot loader superuser name' do
      skip 'Not Applicable: provided by the deploying site; see the justification.'
    end
  end
end
