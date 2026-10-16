# SAFBox

[![static](https://github.com/mitre/safbox/actions/workflows/static.yml/badge.svg)](https://github.com/mitre/safbox/actions/workflows/static.yml)

SAF in a box: a pre-built virtual machine image carrying the MITRE Security
Automation Framework toolchain and a curated library of validation profiles
and hardening content, ready to deploy into a network as an assessment and
hardening appliance, or to explore the SAF tools without setting anything up.

What's inside (v1 target):

- Heimdall and Vulcan, hosted as podman Quadlet services
- CINC Auditor, Ansible, the SAF CLI, and Packer
- Pinned InSpec STIG profiles and Ansible Lockdown hardening roles for the
  major operating systems
- A Rocky Linux 10 base, FIPS mode enabled from installation, hardened to the
  RHEL 10 STIG with every deviation documented

**Encryption at rest.** SAFBox does not presently have a way to build disk
encryption into the VM itself: a template that boots unattended would share
its key with every copy. In most deployment contexts the STIG's data-at-rest
requirement is inherited from the hypervisor or storage layer instead, and
SAFBox's STIG overlay marks it Not Applicable on that basis. Make sure the
storage that holds your SAFBox is encrypted.

SAFBox is hardened to the DISA RHEL 10 STIG with documented deviations; what
is relaxed, and why, is in the STIG overlay profile,
[verify/profiles/safbox-rhel10-stig-overlay/controls/overlay.rb](verify/profiles/safbox-rhel10-stig-overlay/controls/overlay.rb).

The design is recorded in [docs/adrs/0001-safbox-appliance-pipeline.md](docs/adrs/0001-safbox-appliance-pipeline.md).

## Two ways to use it

- **Deploy the image.** See `docs/deploy.md` (arrives with the release gate).
- **Rebuild the image.** See [docs/rebuild.md](docs/rebuild.md). The build is
  Packer for the OS install and Ansible for everything that makes it a SAFBox,
  so the Ansible layer also works on a machine you already have.

## Status

Phases 1 and 2 of 8: the install layer builds a FIPS-enabled RHEL 10 family
template on Proxmox, and the appliance foundation (platform, first-boot
framework, seal, outside-in validation) turns it into a sealed SAFBox base.
Every push runs the static suite and secret scan in CI (see
[docs/rebuild.md](docs/rebuild.md#continuous-integration)).
