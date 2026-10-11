# SAFBox

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

The design is recorded in [docs/adrs/0001-safbox-appliance-pipeline.md](docs/adrs/0001-safbox-appliance-pipeline.md).

## Two ways to use it

- **Deploy the image.** See `docs/deploy.md` (arrives with the release gate).
- **Rebuild the image.** See [docs/rebuild.md](docs/rebuild.md). The build is
  Packer for the OS install and Ansible for everything that makes it a SAFBox,
  so the Ansible layer also works on a machine you already have.

## Status

Phase 1 of 8: the install layer builds a FIPS-enabled RHEL 10 family template
on Proxmox. The appliance layer follows.
