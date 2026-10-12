# Third-party software in the SAFBox image

SAFBox itself is licensed as described in [LICENSE.md](../LICENSE.md). The
image it builds bundles third-party software; each component keeps its own
license, and this file records the ones that need an explicit note.

## HashiCorp Packer
  Packer is distributed under the Business Source License 1.1 (BSL). The
  licensor's Additional Use Grant permits production use except offering
  Packer to third parties on a hosted or embedded basis in competition with
  the licensor's paid products, and it names free products as outside that
  restriction. SAFBox is free and open source, is not a Packer-as-a-service,
  and bundles unmodified Packer binaries so the appliance can build hardened
  images. Bundling is therefore within the grant as published at the time of
  this build. Packer is installed by its own switchable group of the
  `tools` role (Phase 3), so a downstream distributor can exclude it.
  Phase 1 images do not yet contain Packer. Re-check the license text if
  SAFBox is ever sold or offered as a hosted service.

## AlmaLinux and Rocky Linux
  Base operating systems redistributed under their respective licenses.
  Rocky Linux's cryptographic modules carry no FIPS 140-3 certificate of
  their own; the deploy guide (Phase 8) will state this.

## MITRE Heimdall, MITRE Vulcan, MITRE SAF CLI, CINC Auditor, Ansible, podman
  Planned components (Phases 3, 5, 6). Apache License 2.0 (Heimdall, Vulcan,
  SAF CLI, CINC Auditor, podman) and GNU GPL v3 (Ansible), as distributed by
  their upstream projects.

## Vendored security content
  Planned (Phase 4): InSpec profiles from the MITRE SAF content library and
  hardening roles from Ansible Lockdown, vendored at pinned versions under
  /opt/safbox/content, each with its upstream LICENSE file intact.
