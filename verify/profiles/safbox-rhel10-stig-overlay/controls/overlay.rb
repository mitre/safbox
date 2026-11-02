# frozen_string_literal: true

# The RHEL 10 STIG baseline as SAFBox runs it. Every baseline control is
# included and runs unchanged, except where a requirement does not apply to
# SAFBox at all: that control is set Not Applicable here, with impact 0.0, a
# justification and a deliberate skip. A requirement SAFBox chooses not to
# meet is not overridden; its control fails, and it is listed with its cause
# in the known failures in docs/reference/hardening.md.
include_controls 'redhat-enterprise-linux-10-stig-baseline' do
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
