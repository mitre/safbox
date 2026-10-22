# frozen_string_literal: true

# SAFBox deviations from the RHEL 10 STIG baseline. This file is the record
# of them. Every baseline control is included; a requirement SAFBox
# deliberately does not apply is set Not Applicable here: impact 0.0, a
# justification, and a deliberate skip. The template_hardening role switches the
# matching Lockdown rule off (rhel10stig_<n> in ansible/group_vars/all/main.yml)
# where that rule would undo the deviation. SV-281170's (RHEL-10-600110)
# stays on: it changes accounts only under rhel10stig_disruption_high, and
# then only those that exist at build time with an unlocked password, while
# admin is made at first boot with a locked one.
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

  control 'SV-281170' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      admin, the key-only account cloud-init creates for deploying and
      automation, has no password and is exempt from password ageing
      (chage -M -1), because sshd refuses even its key login once its
      locked password passes the maximum age; every other account gets the
      60-day maximum from /etc/login.defs (SV-281169), and the safbox
      profile checks safuser's (safbox-accounts-3).
    JUSTIFICATION
    describe '60-day maximum password lifetime for existing passwords, admin excepted' do
      skip 'Not Applicable: admin has no password to age; see the justification.'
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

  control 'SV-280970' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      SAFBox is an automation runner: its accounts run the InSpec profiles and
      Ansible playbooks they bring. fapolicyd judges the program that opens a
      file, and for InSpec, Ansible and Node.js packages an account installs,
      that program is an interpreter (CINC Auditor's Ruby, Python, Node.js), so
      it cannot allow a tool without allowing its interpreter to run any code; a
      rule on the process name is met by any link given that name. Tested with
      fapolicyd enforcing, as an account other than root: an InSpec profile with
      Ruby libraries, a playbook with its own module or filter plugin, a
      collection in the account's home, a Python virtual environment and an npm
      package were all refused, as were cp and git checkout of Ruby files.
      /home, /tmp, /var/tmp and /dev/shm are mounted noexec, so programs placed
      there cannot be run directly; that does not stop interpreters or rootless
      containers running code an account supplies, which is what a runner is
      for. fapolicyd stays installed (RHEL-10-200600) and is not enabled.
    JUSTIFICATION
    describe 'Enable the fapolicy module (application allow-listing)' do
      skip 'Not Applicable: a usability deviation for an automation runner; see the justification.'
    end
  end

  control 'SV-280971' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      The policy takes effect only while fapolicyd runs, and SAFBox does not
      enable fapolicyd (SV-280970, same reasoning). Its rules are left as the
      package installs them.
    JUSTIFICATION
    describe 'Employ a deny-all, permit-by-exception fapolicy policy' do
      skip 'Not Applicable: follows the SV-280970 deviation; see the justification.'
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

  # Not Applicable only until a site names its remote log server, as
  # SV-280985 above.
  control 'SV-280989' do
    unless input_object('remote_log_server').has_value?
      impact 0.0
      desc 'justification', <<~JUSTIFICATION
        Remote log offload over TLS is provided by the deploying site's log
        server. SAFBox forwards no logs until a site names its server
        (safbox_remote_log_server); the rule is then applied and this
        control evaluated.
      JUSTIFICATION
      describe 'Off-loading audit records over TLS (gtls) via rsyslog' do
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

  control 'SV-281211' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      admin, the account cloud-init creates for the deployer, keeps
      passwordless sudo: it logs in with an SSH key and has no password,
      and Ansible and the outside-in checks escalate through it unattended.
      No other account has it: safuser, the account for using the tools day
      to day, has sudo that asks for its password. The safbox profile checks
      that admin's rule is the only NOPASSWD rule (safbox-accounts-4).
    JUSTIFICATION
    describe 'Require a password for privilege escalation by admin' do
      skip 'Not Applicable: admin alone keeps passwordless sudo; see the justification.'
    end
  end
  control 'SV-281353' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      SAFBox runs Heimdall, Vulcan and Keycloak as podman pods on bridge
      networks, and podman's network backend (netavark) enables IPv4
      forwarding so that the containers can reach the box and the network
      through the host. The box is not a router: it has one network
      interface, and forwarding serves only its own containers. The
      template_hardening role leaves Lockdown's rule RHEL-10-800210 off: applied to
      a running box, its setting turns forwarding off under the pods until
      the next boot.
    JUSTIFICATION
    describe 'IPv4 packet forwarding disabled' do
      skip 'Not Applicable: the container network needs forwarding; see the justification.'
    end
  end

  control 'SV-281250' do
    impact 0.0
    desc 'justification', <<~JUSTIFICATION
      Elevating sudo into the SELinux sysadm_r role requires administrators
      to log in as confined SELinux users (staff_u), with every
      administrative path (Ansible through admin, the outside-in checks,
      safuser's tools) tested under that confinement. That is a design
      change SAFBox has not made: its accounts log in unconfined
      (unconfined_u), with SELinux enforcing for the system's services.
    JUSTIFICATION
    describe 'Elevate the SELinux context when an administrator calls sudo' do
      skip 'Not Applicable: confined administrator users are a design change; see the justification.'
    end
  end

  # Not Applicable on the RHEL rebuilds (Rocky Linux, AlmaLinux) only; on
  # Red Hat Enterprise Linux the baseline control runs unchanged.
  control 'SV-280952' do
    unless os.name == 'redhat'
      impact 0.0
      desc 'justification', <<~JUSTIFICATION
        subscription-manager registers a system with Red Hat's subscription
        service. On a RHEL rebuild such as Rocky Linux or AlmaLinux there is
        no Red Hat subscription to register and the tool has no function;
        packages come from the distribution's own signed repositories.
      JUSTIFICATION
      describe 'The subscription-manager package installed' do
        skip 'Not Applicable: no Red Hat subscription on a RHEL rebuild; see the justification.'
      end
    end
  end
end
