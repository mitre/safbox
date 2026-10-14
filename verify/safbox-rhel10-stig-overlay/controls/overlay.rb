# frozen_string_literal: true

# SAFBox deviations from the RHEL 10 STIG baseline. Every baseline control is
# included; a requirement that cannot be implemented as written on SAFBox is
# set Not Applicable here: impact 0.0, a justification, and a deliberate skip.
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
end
