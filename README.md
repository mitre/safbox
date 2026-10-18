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
- A RHEL 10 family base (the packaged image uses Rocky Linux 10; AlmaLinux 10
  builds the same way), FIPS mode enabled from installation, hardened to the
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
- **Build the image.** Follow the
  [Proxmox build guide](docs/guides/proxmox/build.md); the
  [reference pages](docs/reference/platform.md) describe the result. The build is
  Packer for the OS install and Ansible for everything that makes it a SAFBox,
  so the Ansible layer also works on a machine you already have.

## Status

Phases 1 and 2 of 8: the install layer builds a FIPS-enabled RHEL 10 family
template on Proxmox, and the appliance foundation (platform, first-boot
framework, seal, outside-in validation) turns it into a sealed SAFBox base.
Every push runs the static suite and secret scan in CI (see
[Developing SAFBox](docs/reference/development.md)).

## Licences

SAFBox is licensed as described in [LICENSE.md](LICENSE.md). The software it
bundles keeps its own licences:

| Component | Licence |
|---|---|
| Heimdall, Vulcan, SAF CLI (MITRE) | Apache License 2.0 |
| Keycloak | Apache License 2.0 |
| Bouncy Castle FIPS jars (Keycloak's FIPS provider) | Bouncy Castle Licence (MIT) |
| MITRE RHEL 10 STIG baseline profile | Apache License 2.0 |
| CINC Auditor | Apache License 2.0 |
| podman | Apache License 2.0 |
| ansible-core, ansible.posix, community.general, community.crypto | GNU GPL v3 or later |
| Ansible Lockdown RHEL10-STIG role | MIT |
| Node.js | MIT |
| VitePress (the documentation site's runtime) | MIT |
| nginx | BSD 2-Clause |
| PostgreSQL | PostgreSQL Licence |
| Rocky Linux / AlmaLinux | their distributions' licences |
| Container base images of Heimdall, Vulcan, Keycloak and the TLS proxy | Red Hat Universal Base Image (UBI) 9 End User License Agreement, which allows redistribution |

**HashiCorp Packer is the one source-available component**, under the
Business Source License 1.1 (licensor IBM). Its Additional Use Grant
permits production use except offering Packer to third parties as a hosted or embedded product that
competes with the licensor's paid versions. SAFBox is free, is not a
Packer service, and ships the unmodified binary with its licence at
`/usr/local/share/licenses/packer/LICENSE.txt`. A distributor who does not
want to ship BSL software sets `safbox_tools_4: false`; the image then
contains no Packer. Re-check the licence on every Packer version bump.

Some components carry more than one licence: community.crypto has files
under Apache-2.0, BSD-2-Clause, BSD-3-Clause and PSF-2.0 beside its GPL;
the SAF CLI's npm dependencies keep their own licences, each in its
package under `/usr/local/lib/node_modules`; each Ansible collection
carries its licence files in its install directory. Rocky Linux's
cryptographic modules carry no FIPS 140-3 certificate of their own.
Keycloak's FIPS provider is Bouncy Castle FIPS (bc-fips) 2.1.3, the version
Keycloak 26.8.1 requires: a patch release on the line NIST's CMVP
certificate #4943 validates, which lists 2.1.1.
