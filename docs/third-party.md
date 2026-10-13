# Third-party software in the SAFBox image

SAFBox itself is licensed as described in [LICENSE.md](../LICENSE.md). The
image it builds bundles third-party software; each component keeps its own
license, and this file records the ones that need an explicit note.

## HashiCorp Packer
  Packer is distributed under the Business Source License 1.1 (BSL). The
  license shipped with the pinned release (1.16.1) names IBM as licensor.
  Its Additional Use Grant permits production use except offering Packer to
  third parties on a hosted or embedded basis to compete with the
  licensor's paid versions; a competitive offering is a product offered on a
  paid basis, including through paid support, and products not provided on
  a paid basis are not competitive. SAFBox is free and open source, is not a
  Packer-as-a-service, and bundles the unmodified Packer binary so the
  appliance can build hardened images. Bundling is therefore within the
  grant as published at the time of this build.

  Packer is installed by its own task group of the `tools` role,
  `safbox-tools-4`, switched by `safbox_tools_4` in
  `ansible/group_vars/all/main.yml`. A downstream distributor who does not
  want to redistribute BSL software sets `safbox_tools_4: false` (in that
  file or in `ansible/local.yml`); the image then contains no Packer, and
  the validation profile skips its Packer control once `packer` is left
  out of its `expected_tools` input (see `docs/rebuild.md`). When Packer is
  installed, its license text is installed beside it at
  `/usr/local/share/licenses/packer/LICENSE.txt`, as the BSL requires.
  Re-check the license text on every Packer version bump, and before SAFBox
  is ever sold, offered with paid support, or offered as a hosted service.

## AlmaLinux and Rocky Linux
  Base operating systems redistributed under their respective licenses.
  Rocky Linux's cryptographic modules carry no FIPS 140-3 certificate of
  their own; the deploy guide (Phase 8) will state this.

## MITRE SAF CLI, CINC Auditor, Ansible, Node.js
  Installed by the `tools` role (Phase 3) at the versions pinned in
  `ansible/group_vars/all/main.yml`: the SAF CLI and CINC Auditor under the
  Apache License 2.0; ansible-core and Node.js from the distribution under
  their packaged licenses (GNU GPL v3 or later for ansible-core). The SAF
  CLI's npm dependencies, resolved by npm at build time, keep their own
  licenses, each in its package under `/usr/local/lib/node_modules`.

## Ansible collections
  Installed system-wide for the on-box Ansible because the Ansible Lockdown
  RHEL10-STIG role requires them: ansible.posix and community.general
  (GNU GPL v3 or later), community.crypto (GNU GPL v3 or later, with some
  files under Apache-2.0, BSD-2-Clause, BSD-3-Clause and PSF-2.0). Each
  collection carries its license files in its install directory under
  `/usr/share/ansible/collections`.

## MITRE Heimdall, MITRE Vulcan, podman
  Planned components (Phases 5, 6) and the distribution's podman. Apache
  License 2.0, as distributed by their upstream projects.

## Vendored security content
  Planned (Phase 4): InSpec profiles from the MITRE SAF content library and
  hardening roles from Ansible Lockdown, vendored at pinned versions under
  /opt/safbox/content, each with its upstream LICENSE file intact.
