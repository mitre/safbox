# frozen_string_literal: true

# SAFBox deviations from the RHEL 10 STIG baseline. Every baseline control is
# included; a control is overridden here only to explain a deviation, which
# the baseline's own input puts into effect (see inspec.yml).
include_controls 'redhat-enterprise-linux-10-stig-baseline' do
  control 'SV-280935' do
    desc 'caveat', 'Not Applicable: SAFBox is distributed as a virtual machine template and cannot ' \
                   'encrypt its own disks. Any key that let the template boot unattended would be ' \
                   'shared by every copy, so SAFBox does not presently provide encryption within the ' \
                   'VM itself. Data at rest is protected by the hypervisor or storage layer of the ' \
                   'deploying environment, which is the case this requirement names: "If there is a ' \
                   'documented and approved reason for not having data-at-rest encryption at the ' \
                   'operating system level, such as encryption provided by a hypervisor or a disk ' \
                   'storage array in a virtualized environment, this requirement is not applicable." ' \
                   'This caveat is the documented reason; approval rests with the deploying ' \
                   "organization's authorizing official, who must confirm that the storage holding " \
                   'this VM is encrypted.'
  end
end
