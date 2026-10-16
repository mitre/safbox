# ADR-0001: SAFBox, a Packer + Ansible built security appliance image

**Date:** 2026-10-10
**Status:** proposed
**Deciders:** will@dower.dev

## Context

Security engineers who adopt the MITRE Security Automation Framework (SAF) today
assemble the toolchain by hand: Heimdall for results, Vulcan for authoring, an
InSpec runner, Ansible plus hardening playbooks, the SAF CLI, and a pile of
profile repositories. In a customer network that assembly is repeated per
engagement, often without internet access. Newcomers who just want to see what
SAF does face the same setup wall before they see anything.

SAFBox is a pre-built virtual machine image with that suite installed and
wired together: "SAF in a box." It has two audiences and two delivery modes.

- **Audiences.** Security engineers deploying an assessment and hardening
  appliance into customer networks, which may have no internet access. And curious
  non-experts who want to deploy one VM and start clicking.
- **Delivery.** A pre-baked image consumers import into their own hypervisor or
  cloud. And this repository itself, published as open source, so others can
  rebuild or fork the appliance.

Forces that shape the design:

1. **Portability is the product.** v1 targets Rocky Linux 10 on Proxmox, but
   the stated roadmap is other base operating systems (Ubuntu LTS next) and
   other targets (vSphere, AWS, Azure, more). Anything hypervisor-specific
   must be isolated from the start or the project forks itself later.
2. **Disconnected operation is normal.** Everything the appliance needs must
   be on disk at build time. Reproducibility matters: a build from a given
   commit should produce the same content set. Operating on an organization's
   network also means fitting into that network: a package mirror, a corporate
   proxy, internal DNS, NTP, and trusted CAs. The image cannot know those in
   advance; they must be configurable at deploy time.
3. **It is a security appliance.** A distributed image with baked-in database
   passwords or signing keys is a vulnerability shipped to every consumer.
   Consumers in regulated networks will also ask whether it runs in FIPS
   mode, and FIPS is not a runtime toggle on any operating system: a system
   either was installed in FIPS mode and can prove it, or it was not.
4. **Build hosts vary in size.** Early builds run on constrained lab hardware.
   The design must not depend on a large host, but the first milestones must
   run on a small one.
5. **The build runner has API access only.** Packer drives Proxmox over its
   HTTPS API from a least-privilege account scoped to a resource pool, a small
   set of reserved VM IDs, one storage for disks, one for ISOs, one bridge, and
   one node. The runner has no shell on the Proxmox nodes. Creation rights
   come from the pool: every create and clone request names it, because
   Proxmox deletes per-VM ACLs when a VM is destroyed, so grants on reserved
   IDs can only act as a ceiling on which IDs may ever exist.

Decisions already taken during design review and recorded here:

- Base image for v1 is **Rocky Linux 10**, installed from the distribution
  ISO (minimal for headless builds, DVD when a desktop is wanted) by
  kickstart with **FIPS mode enabled at install** (`fips=1`). Rocky 10 is
  chosen over Ubuntu 26.04 because the full hardening stack exists for it
  today: a published DISA RHEL 10 STIG, an Ansible Lockdown role, and a MITRE
  SAF baseline. Ubuntu becomes the second base. Rocky 9 is the documented
  fallback if the RHEL 10 content proves too immature.
- **AlmaLinux 10 x86-64-v2 is the development variant.** Rocky 10 requires
  x86-64-v3 hardware and the Rocky project ships no lower build. AlmaLinux 10
  is the RHEL 10 rebuild that does, so development hosts without AVX2 build
  from the Alma DVD using the same kickstart, the same `fips=1`, the same
  STIG content, and the same appliance layer. Release images are built from
  Rocky 10. The only difference between the two builds is the ISO variable.
- The image is **headless by default**. A desktop environment is a kickstart
  environment-group variable, but it requires the full DVD ISO or a reachable
  package mirror at build time; the minimal ISO used for development builds
  cannot install one. Builds from the minimal ISO are therefore always
  headless, and a GUI build is a release-time option from the DVD.
- Container hosting is **podman with Quadlet** systemd units, not Kubernetes.
  k3s is the named upgrade path if the service set grows.
- Content is **pinned in a manifest at build time** with an on-box updater for
  connected deployments.
- First-boot **secret generation is a hard requirement**.
- Reference footprint is **4 vCPU, 8 GB RAM, 60 GB disk**, with size exposed as
  build variables so constrained hosts can run a reduced build.
- The appliance is **STIG-hardened with documented deviations**, using SAF
  patterns for both the hardening side and the validation side. Full
  compliance is not the goal; usability for non-experts is preserved by
  deliberately excluding specific requirements and recording why.
- The reverse proxy is **nginx** (see the proxy sub-alternatives).

## Decision

Build SAFBox as a **two-layer pipeline with a hard seam between them**:

1. **Install layer (Packer, per platform).** One Packer `source` block per
   hypervisor-and-OS pair, plus the unattended-install answer file that pair
   needs. Its only job is to produce a booted, SSH-reachable, minimal OS with
   the guest agent and cloud-init present. v1 ships exactly one: `proxmox-iso`
   with a Rocky 10 kickstart. Ubuntu adds an autoinstall file and a second
   source. vSphere, AWS, and Azure add sources that reuse the same answer
   files or start from marketplace images.
2. **Appliance layer (Ansible, platform-agnostic).** A single playbook and a
   set of roles that turn any booted Linux into a SAFBox. Roles select package
   names and paths by `ansible_os_family`. Nothing in this layer may reference
   Proxmox, vSphere, or any cloud. This layer is what makes the image a SAFBox
   and it is the part consumers are most likely to reuse on their own.

A shared `build` block in Packer chains the two: run the Ansible playbook over
SSH, validate the result from outside, then seal the image.

**Validation stages** (amended 2026-10-11 after the Phase 2 build work):

1. *Build-time gate.* Between the appliance playbook and the seal, Packer
   runs the `verify/inspec-safbox` profile from the build runner against the
   build VM over SSH with CINC Auditor, and `saf validate threshold` gates
   the build. Nothing is installed or staged on the image for this.
2. *Seal self-assertion.* After the seal nothing can log in to check the
   template, so the seal's final privileged script asserts its own
   post-conditions (no build user, sudo rule, host keys, initialised
   machine-id, cloud-init instance state, installer residue, first-boot
   secrets, or build-VM network profiles) and fails the build otherwise.
   A development build runs the same seal in its development mode, which
   scrubs identity and residue but stops before deleting the build user,
   host keys and logs; the build record names the mode, and the release
   gate requires `full`.
3. *Release gate.* Some promises only exist on a deployed instance: fresh
   host keys and machine-id, the consumer's cloud-init user, first boot
   running once. Before an image is published, a clone is booted and the
   same profile runs against it from outside as the deploy user. This is a
   release step, not a per-build step.

Scheduled self-scans of a deployed box against the STIG overlay are a
separate feature and do not use the build profile.

**Validation layout** (amended 2026-10-13 by the owner): one profile, one
script, one threshold per context.

- *Wrapper and children.* `verify/inspec-safbox` is a root wrapper with no
  controls, inputs or platform support of its own. It depends by path on
  its children and includes each one whole: `verify/el10-infrastructure`
  (every SAFBox infrastructure control, supports the redhat family at
  release 10.*) and `verify/safbox-rhel10-stig-overlay` (the STIG overlay below).
  One scan of the wrapper is both the build-time gate and the release
  gate; each child also runs alone. The wrapper fetches the overlay's
  pinned baseline from git at scan time; the build is online already, so
  the baseline is not vendored.
- *Omniprofile direction.* A later OS family adds its own children
  (for example a Debian-family infrastructure profile and an Ubuntu STIG
  overlay) to the same wrapper. Each child's `supports` names its
  platform, and CINC Auditor skips a child that does not match the
  target, so the wrapper stays one profile for every image.
- *Inputs from files.* `scripts/validate.sh <target> <key> <label>
  <profile> <threshold> <inputs-file>` passes a tracked inputs file per
  context (`verify/inputs/build.yml`, `verify/inputs/release.yml`) to CINC
  Auditor with `--input-file`; inputs given to the wrapper this way reach
  every child (proven against a clone). No caller passes `--input`.
- *Critical-bucket thresholds.* Every infrastructure control is impact
  1.0, the SAF CLI's critical severity, and no STIG control uses it (CAT I
  is 0.7). The one exception is a documented finding: a known weakness
  SAFBox ships with is a low-impact (below 0.4) infrastructure control
  tagged `finding` that fails by design, listed by ID under
  `failed.low.controls` so a new one fails the gate (amended 2026-10-14). Each tracked threshold (`verify/thresholds/build.yml`,
  `verify/thresholds/release.yml`) lists exactly the infrastructure
  controls a repository-default image passes in that context under
  `passed.critical.controls`, which the SAF CLI treats as an exact set,
  with `failed.critical.max: 0` and `error.total.max: 0`. A static test
  derives the list from the controls' `only_if` conditions and the
  context's inputs, so a control cannot be added without its threshold.
  Limits: the SAF CLI judges whole controls, not their tests; and the list
  holds only for repository defaults, so a site that changes what applies
  supplies its own threshold.
- *STIG: lock the documented state.* Per severity (high,
  medium, low) `passed.<sev>.controls` and `failed.<sev>.controls` list
  exactly which STIG controls pass and which fail on the current (since
  Phase 7, hardened) image in each context, as exact sets, `max: 0` where a
  set is empty (the SAF CLI cannot judge an empty list). Any control that changes status fails the
  gate, an improvement or a swap as much as a regression, so every change
  to the documented state is a reviewed threshold diff.
  `scripts/lock-stig-threshold.sh` regenerates the lists from a results
  file (`saf generate threshold -c`) and records the source. No baseline
  control is skipped to pass, and the critical and error clauses are never
  loosened. Known weaknesses remain visible findings: SAFBox demonstrates
  a controlled, documented security state, not a clean report.
  (Amended 2026-10-13 by the owner: exact control lists replace the
  per-severity count floors, which could not tell one control from
  another. Amended 2026-10-14: the lists now lock the hardened image, and
  an empty set is written `max: 0`.)
- *Site overrides.* A site whose image differs from the repository
  defaults (a tools group switched off, a pin overridden) names a site
  inputs file, layered after the tracked one, and a site threshold file,
  which replaces the tracked one. The build takes them through the Packer
  variables `build_gate_site_inputs_file` and
  `build_gate_site_threshold_file`, the release gate through
  `SAFBOX_SITE_INPUTS` and `SAFBOX_SITE_THRESHOLD`; both default to none.
  Site files live in git-ignored `verify/local/` and are never committed.
- *On-box exercise profiles.* Profiles that exercise the box rather than
  inspect it live beside the children under `verify/` but are not in the
  wrapper: `verify/el10-fips-exercise` (each tool doing TLS or hashing
  under FIPS enforcement; needs outbound HTTPS) and `verify/el10-firstboot`
  (the first-boot runner in a scratch tree it removes; writes files). Each
  runs alone through `scripts/validate.sh` with its own
  `verify/inputs/<name>.yml` and `verify/thresholds/<name>.yml`.
  (Amended 2026-10-12 by the owner: every test that talks to the box over
  SSH is an InSpec profile.)

**Role layout and task groups** (amended 2026-10-11): the appliance layer
has `platform` (OS contract and container runtime), `base` (first-boot
framework and the `safbox` command), `tools` (CINC Auditor now; the SAF CLI,
Ansible, and Packer in Phase 3), and `seal`; service roles and `hardening`
follow in later phases. Every task group is a block tagged
`safbox-<role>-<n>` and gated by a `safbox_<role>_<n>` switch (default on),
in the style of Ansible Lockdown, so consumers can turn groups off or run
them selectively. The seal is tagged but not switchable: it runs whole or
not at all.

Within the appliance layer:

- **Services run as podman Quadlets.** Heimdall and Vulcan are each a systemd
  managed pod built from their upstream container images and the service
  shapes in their published compose files. A single nginx reverse proxy
  terminates TLS, serves a landing page, and fronts both applications on
  distinct ports. The proxy runs Red Hat's UBI 9 nginx image rather than
  upstream Heimdall's `nginx:alpine`, whose OpenSSL has no FIPS provider
  (owner decision 2026-10-14); it is still a published image, not rebuilt.
- **Secrets are generated on first boot**, not at build. A `safbox-firstboot`
  systemd unit creates per-install credentials (Heimdall database password,
  JWT and API key secrets; Vulcan database password, `SECRET_KEY_BASE`,
  cipher password and salt), writes them to root-only environment files, and
  mints a self-signed certificate; the service units are enabled at build but
  start only once those files exist (`ConditionPathExists`, amended
  2026-10-14). The seal
  step at build time removes SSH host keys, `machine-id`, cloud-init state,
  shell history, and the build user's credentials so each deployment is unique.
- **Content is manifest-driven.** `content/manifest.yml` lists each InSpec
  profile and hardening playbook as a Git repository pinned to a tag or commit
  with a checksum. The build vendors them to `/opt/safbox/content`. The `safbox`
  command on the box lists, verifies, and (when online) updates them against
  the same manifest format. The initial manifest is seeded from the SAF
  content library data in the `saf-site` repository, which already records the
  GitHub URL for each library entry.
- **The build validates the appliance with the SAF tools.** Before sealing,
  the build runs a small InSpec profile from the build runner against the
  build VM with CINC Auditor, asserting that the expected tools, versions,
  units, ports, and content are present, and gates the build with a SAF CLI
  threshold (see Validation stages). The same tools the appliance ships are
  the ones that prove it works.
- **The appliance is hardened against the DISA STIG for its base release,
  with documented deviations.** A `hardening` role applies the Ansible
  Lockdown STIG role for the base OS, pinned in the manifest like any other
  content. Requirements that would make the appliance hostile to non-experts
  (for example the account lockout policy) are disabled through the Lockdown
  role's per-rule variables in a single `deviations.yml`, each entry carrying
  the STIG ID and a justification. The same deviations appear on the
  validation side: an InSpec **overlay profile** (`verify/safbox-rhel10-stig-overlay`)
  depends on the MITRE SAF STIG baseline for the base OS and marks each
  deviated requirement Not Applicable with the same justification, following
  the SAF overlay pattern; the SAFBox infrastructure controls stay in their
  own profile (`verify/el10-infrastructure`), and the `verify/inspec-safbox`
  wrapper runs both (see Validation layout). One list of
  deviations, consumed by both sides, so hardening and validation cannot
  drift apart. Hardening runs as the last play before validation and the seal.
  The goal is not a box hardened to the hilt by default: no two environments
  make the same risk decisions, so the shipped posture is a sensible,
  usable baseline and the real product is that every control is a documented
  knob (the Lockdown role's variables, the deviations file, the banner text,
  and the like) that a consumer can turn when they rebuild.
- **FIPS mode is on from installation and is not configurable afterward.**
  The kickstart passes `fips=1`; every Rocky-based SAFBox image is a FIPS-mode
  system from first boot. Red Hat removed the post-install switch in RHEL 10,
  so this is the only supported path, and it matches how FIPS evidence works
  everywhere: provable from installation or not at all. The toolchain is
  therefore exercised under FIPS enforcement from the first build.
- **Deployment is Terraform, one module per target, mirroring the install
  layer.** Packer produces the image; Terraform deploys instances of it:
  clone or import the published artifact, supply cloud-init user data, start,
  expose the address. v1 ships a sample Terraform configuration for Proxmox
  under `deploy/terraform/proxmox/`, using the community Proxmox provider,
  and the deploy guide walks through it. vSphere, AWS, and Azure modules
  follow their Packer sources in later phases. Terraform is not used to build
  the image (see Alternative J).
- **Tool versions are pinned** in one variables file. Distributable images
  must be reproducible from a tag at the level of what is pinned: the same
  tag installs the same tool versions, while a package manager may resolve
  different releases of those tools' own dependencies (see Pinned inputs).

Why this shape rather than a single Proxmox-centric template: the install
layer is the part that changes per target and is small. The appliance layer is
the part that carries all the value and must not change per target. Putting
the seam exactly there means a new hypervisor is one new source file and zero
Ansible changes, and a new base OS is one new answer file plus `os_family`
variables.

## Alternatives Considered

### Alternative A: Kubernetes inside the appliance (kind, as first proposed)
Host Heimdall and Vulcan on a kind cluster, with podman as the node runtime.
- **Pros:** Matches the Heimdall Helm chart; familiar to Kubernetes users.
- **Cons:** kind's own documentation says it is for testing Kubernetes, not for
  hosting workloads. Nodes are containers, cluster state does not reliably
  survive reboots, and kind on podman needs rootful podman and workarounds. A
  control plane plus two applications and two databases does not fit a 4 GB
  VM, and barely fits 8 GB alongside running scans.
- **Why rejected:** Wrong tool class for an appliance. Recorded upgrade path:
  if the service set grows, add a `k3s` role and ship Helm charts; k3s is
  single-binary, appliance-grade, and already a SAF hardening target.

### Alternative B: Docker Engine with docker compose
Install Docker CE and run the upstream compose files unchanged.
- **Pros:** Zero translation from upstream; most familiar to most users.
- **Cons:** Docker CE on Rocky and RHEL family is a third-party repository and
  conflicts with the distro's podman stack, which hurts the multi-OS goal.
  A root daemon in a security appliance is a worse posture than daemonless
  podman. Compose services are not first-class systemd units; Quadlet units
  are, which gives ordering, restart policy, journald logging, and first-boot
  dependencies for free.
- **Why rejected:** Multi-OS friction and weaker systemd integration. The
  compose files remain the reference for service shape and are cited in each
  Quadlet unit.

### Alternative C: Cloud image import instead of ISO plus answer file
Import the distribution's cloud image as a Proxmox template once, then build
with `proxmox-clone`.
- **Pros:** Fastest boots, no installer to automate, the canonical cloud
  pattern.
- **Cons:** Importing a disk image requires a root shell on a Proxmox node,
  which the least-privilege runner does not have, so the base template becomes
  an out-of-band manual step that the repo cannot reproduce. The approach does
  not transfer to vSphere, where ISO plus answer file is still the norm.
- **Why rejected for v1:** Breaks the "repo rebuilds everything" property.
  Revisit for cloud targets, where marketplace images make this the natural
  path and no import is needed.

### Alternative D: Shell provisioners instead of Ansible
Configure the image with shell scripts run by Packer.
- **Pros:** No Ansible on the build runner; simplest to start.
- **Cons:** Not idempotent, not testable in isolation, and every multi-OS
  branch becomes an `if` in bash. Ansible is already in the appliance for
  hardening, and the roles double as documentation of what a SAFBox is.
- **Why rejected:** The appliance layer is the reusable asset; it must be
  structured.

### Alternative E: Fetch content live at build or on first boot
Clone the latest profiles and playbooks when the image builds or boots.
- **Pros:** Always current, smallest image.
- **Cons:** Non-reproducible builds, breaks when upstream changes, and
  first-boot fetching fails outright on networks without internet access.
- **Why rejected:** Conflicts with forces 2 and 3. The manifest plus updater
  gives freshness when online and determinism always.

### Alternative F: Headless image instead of a desktop environment
- **Pros:** Smaller image, less memory, no display stack in an appliance.
- **Cons:** None technical; the decider prefers to keep a desktop available
  while the appliance is explored by non-experts.
- **Status:** Headless is the default. The desktop is a kickstart
  environment-group variable that needs the DVD ISO or a package mirror,
  since the minimal ISO carries no GUI packages. Same pipeline, one variable
  and a different ISO.

### Alternative H: Ubuntu 26.04 as the first base
This was the working plan until the hardening decision was made.
- **Pros:** Familiar to more newcomers; the ISO was already staged.
- **Cons:** No DISA STIG for 26.04 exists yet, so hardening and validation
  would borrow 24.04 content and carry release-mismatch deviations. FIPS on
  Ubuntu requires an Ubuntu Pro entitlement the image cannot carry, so a
  FIPS-mode SAFBox on Ubuntu is a consumer action, not an image property.
- **Why rejected for v1:** Rocky 10 has the complete stack today and makes
  FIPS an image property. Ubuntu is the second base; its STIG and FIPS
  situation is re-evaluated when that source is added.

### Alternative I: Rocky 9 as the first base
- **Pros:** Mature RHEL 9 STIG content on every side; runs on x86-64-v2
  hardware; FIPS can still be enabled post-install on 9.
- **Cons:** Older release; the RHEL 10 content is where attention is going;
  post-install FIPS enablement is the weaker evidentiary story.
- **Why rejected:** Recorded as the fallback if RHEL 10 content proves too
  immature or no x86-64-v3 build host is available.

### Alternative J: Terraform as the image builder
Describe the build VM in Terraform and provision it there instead of Packer.
- **Pros:** One tool; declarative; the same provider later deploys the box.
- **Cons:** Terraform manages the lifecycle of running infrastructure with
  state. It has no notion of driving an installer's boot sequence, running a
  provisioning chain as a build, sealing, or converting to a template;
  every attempt re-implements Packer inside provisioners and null resources.
- **Why rejected:** Wrong tool for building, right tool for deploying. Packer
  builds the image; Terraform deploys from it. That is also the vendor's own
  reference pattern.

### Alternative G: Do nothing
Publish a setup guide and let each engineer assemble the toolchain.
- **Why rejected:** That is the status quo this project exists to replace.

### Reverse proxy sub-alternatives
Criteria: TLS with a first-boot self-signed certificate and consumer-supplied
certificates later; a static landing page; familiarity for the operators;
an assessable hardening baseline so the appliance can scan its own proxy; a
credible FIPS path for regulated networks; small footprint.

| Option | For | Against |
|---|---|---|
| nginx | Heimdall upstream ships an nginx config to reuse. Universally familiar. CIS benchmark exists and the SAF library has an nginx profile, so the box can assess itself. Links the distro OpenSSL, so FIPS mode is a known path. | Certificate generation is our job (already true of first boot). More verbose config. |
| Caddy | Shortest config. Automatic internal CA and ACME. Vulcan documents a Caddy profile. | Go TLS stack with no official FIPS build. No CIS or DISA benchmark to assess against. |
| Traefik | Dynamic discovery from container labels. | Solves a problem static Quadlet units do not have; larger config surface; no benchmark. |
| HAProxy | Strong TLS termination and health checks. | Not a static file server, so the landing page needs another container. |
| No proxy | One fewer component. | Two certificate setups, TLS handled differently by a Node app and a Rails app, no landing page. |

- **Decision:** nginx. Caddy's main advantage, automatic TLS, is moot because
  first boot already generates a certificate. nginx wins on the criteria that
  matter for a security appliance: an assessable baseline and a FIPS path.

## Consequences

**What becomes easier**
- A new hypervisor target is a new `packer/source-<platform>.pkr.hcl` file
  plus a `deploy/terraform/<platform>/` module; the appliance layer is
  untouched.
- A new base OS is an answer file plus `os_family` variables.
- Consumers who only want "make my VM a SAFBox" can run the Ansible layer
  directly against any Ubuntu or Rocky host.
- Each deployment has unique secrets and host identity without any consumer
  action.
- The content set of any image is auditable from the manifest baked into it.

**What becomes harder**
- Upstream compose files must be translated to Quadlet units and kept in sync
  with upstream releases.
- Two package ecosystems (apt and dnf) must be carried in every role from the
  first Rocky commit onward.
- The build runner needs Ansible for the remote provisioner, and CINC Auditor
  and the SAF CLI for the outside-in validation that gates the seal.

**Risks and mitigations**
- *RHEL 10 content is young.* The Lockdown role is at its first release and
  the MITRE baseline describes itself as work in progress. Expect to file
  issues upstream and carry temporary deviations with a `content-defect`
  reason code until fixes land. Rocky 9 is the fallback if this becomes the
  critical path.
- *Rocky 10 needs an x86-64-v3 build host.* RHEL 10 and Rocky 10 require
  AVX2-class CPUs and refuse to boot on older ones. Development hosts that
  lack it build the AlmaLinux 10 x86-64-v2 variant instead; release builds
  run on capable hardware. The two must not drift: the kickstart and
  appliance layer are shared, and the build record and validation profile note which distribution
  and microarchitecture level an image was built from so a lab artifact is
  never mistaken for a release artifact.
- *Constrained hosts cannot run the full appliance.* Expose `vm_cores`,
  `vm_memory`, `vm_disk_size` as Packer variables. Quadlet units are
  individually enableable, so a reduced build can run Heimdall alone.
- *Packer's license.* Packer is under the Business Source License 1.1. Its
  Additional Use Grant permits production use except offering the work to third
  parties on a hosted or embedded basis to compete with the licensor's paid
  products, and explicitly excludes free products from that restriction.
  SAFBox is free and open source and does not compete with a paid Packer, so
  bundling the unmodified binary is within the grant. Record this in
  `docs/third-party.md`, keep Packer in its own switchable group of the
  `tools` role so a distributor can exclude it, and re-check if SAFBox is
  ever sold.
- *Secrets and build identity leak into the image.* The seal role is
  mandatory and runs last. It deletes the build user's authorized key, its
  sudoers drop-in, and the account itself; removes SSH host keys,
  `machine-id`, the installer's kickstart copies and logs under `/root` and
  `/var/log/anaconda`, and the installer-created NetworkManager profile. The
  seal asserts all of that plus the absence of `/etc/safbox/*.env` in
  the template. The build user authenticates only by an ephemeral per-build
  key minted outside the repository; there is no build password. Until the
  seal exists, templates are tagged `unsealed`, say so in their description,
  and are not distributable. cloud-init provisions the real login on deploy.
- *Vendored content goes stale.* The manifest records the pin date; `safbox
  content status` reports age and, when online, available updates. Re-bake on a
  cadence once distribution exists.
- *Memory contention between Heimdall, Vulcan, and scans.* Document the
  reference footprint; set container memory limits in the Quadlet units; the
  landing page shows service status so users understand what is running.
- *Upstream images change shape.* Pin Heimdall and Vulcan image tags in the
  versions file; bump deliberately with the Quadlet unit reviewed against the
  new upstream compose file.
- *The answer file is fetched over plain HTTP during the build.* Packer's
  temporary server is unauthenticated, so the build network segment is
  trusted and `http_bind_address` limits where it listens. Release builds
  must deliver the kickstart over HTTPS (`kickstart_url`, which Anaconda
  verifies) or from media; this is the subject of the kickstart-delivery
  decision card.
- *Hardening severs the build connection.* The STIG touches sshd, PAM, and
  the firewall while Packer is connected over SSH. Mitigations: the build user
  authenticates by key and is in any group the hardened sshd allows; rules
  that would break the live session are applied with a reconnect or deferred
  to a late play; the account lockout rule is a documented deviation anyway.
  If the session is lost the build fails loudly rather than silently shipping
  a half-hardened image.
- *The second base may lack a STIG when added.* DISA STIGs lag Ubuntu LTS
  releases by months. When Ubuntu is added, either the matching STIG exists
  or the phase borrows the nearest release's content with `release-mismatch`
  deviations. Decided then, not now.
- *Over-hardening hurts the non-expert audience.* Every deviation is a
  deliberate, justified entry in `deviations.yml`; the list is reviewed as a
  unit before each release, and the deploy guide explains what was relaxed and
  how a consumer can re-enable it.
- *Heimdall may not run under FIPS enforcement.* Heimdall is known not to
  deploy cleanly in FIPS mode; an upstream pull request addressing it was open
  and unmerged at the time of this decision. Node under a FIPS-enforcing
  OpenSSL is the likely fault line, which also touches the SAF CLI. This is
  accepted as a cross-the-bridge problem: Phase 5 either lands the upstream
  fix, pins a Heimdall build that works, or documents Heimdall as unavailable
  on FIPS images until it does. It must not be worked around by disabling
  FIPS. Outcome (Phase 5, 2026-10-14): Heimdall 2.14.0's UBI 9 image runs
  under FIPS enforcement with its OpenSSL FIPS provider active; its bcryptjs
  password hashing, outside any FIPS provider, is a recorded low-severity
  finding (upstream mitre/heimdall2#4145).
- *FIPS cannot be toggled, so there is no partial path.* Every Rocky image is
  FIPS-on. Any tool that cannot work under FIPS is a tool that cannot ship in
  v1, not a reason to ship a non-FIPS variant.
- *Rocky's FIPS modules are not certified.* Rocky in FIPS mode enforces the
  approved algorithms, but its crypto modules hold no FIPS 140-3 certificate
  of their own; validated modules for Rocky are a paid offering. The deploy
  guide states this plainly. Consumers who need the certificate deploy the
  same appliance layer on RHEL.

## Implementation Plan

### Scope

**IN scope (v1)**
- Repository scaffold, Packer Proxmox source, RHEL 10 family kickstart with
  FIPS enabled at install, build to a Proxmox template in a dedicated
  resource pool. Rocky 10 for release, AlmaLinux 10 x86-64-v2 for
  development hosts without AVX2, selected by the ISO variable.
- Ansible appliance layer with roles: `platform`, `base`, `tools`,
  `content`, `heimdall`, `vulcan`, `proxy`, `hardening`, `seal`, with
  tagged, switchable task groups.
- Content manifest covering major OS STIG profiles and matching Ansible
  Lockdown playbooks.
- First-boot secrets, self-signed TLS, landing page.
- Outside-in InSpec validation from the build runner: the infrastructure
  profile every build, plus the STIG overlay over the base OS baseline once
  hardening lands, with SAF CLI
  threshold gate; seal self-assertions; clone validation as the release
  gate.
- STIG hardening of the appliance via the Ansible Lockdown role, with a
  single deviations file consumed by both hardening and validation.
- A cloud-init clone booted from the template as the acceptance test.
- A sample Terraform configuration under `deploy/terraform/proxmox/` that
  deploys a SAFBox from the template with cloud-init, used by the deploy
  guide.
- Documentation for both audiences: "deploy the image" and "rebuild the image."

**OUT of scope (v1, named as later phases)**
- Distributable artifacts (qcow2, OVA, AMI, VHD) via the `qemu` and cloud
  builders.
- Ubuntu LTS base (second base; re-evaluate its STIG and FIPS story then).
- vSphere, AWS, Azure Packer sources and the matching Terraform deploy
  modules.
- k3s profile and Helm-based hosting.
- Image signing and provenance.
- A non-FIPS image variant. v1 is FIPS-on only. If a demand for a non-FIPS
  build appears (for example, to run a tool that cannot yet work under FIPS),
  it is a second kickstart variable and a second published artifact, decided
  then, never a runtime switch.
- A `site_config` role for fitting the appliance into an organization's
  network: package mirror, corporate proxy (system-wide, apt or dnf, podman,
  pip and npm, the SAF tools), internal DNS and search domains, NTP, static
  routing, and trusted CA bundles. v1 relies on cloud-init and DHCP for
  networking and assumes the SAF content on disk is sufficient.

### Quality Standards (inherited by every card)

- **Framework-first.** Use kickstart or autoinstall, cloud-init, systemd, Quadlet, and
  upstream container images. No custom init scripts where a unit will do. No
  rebuilding upstream containers.
- **Idempotent, linted Ansible.** Every role passes `ansible-lint` and
  `yamllint`. A second run of the playbook against a built box reports zero
  changed tasks. Package names and paths come from role vars: a name common
  to every OS family lives once in `vars/main.yml`, and `vars/<os_family>.yml`
  holds only what that family changes. No bare `apt` or `dnf` module calls
  in task files. (Amended 2026-10-12: OS family files previously repeated
  the common names.)
- **Platform discipline.** Nothing in the appliance layer (`ansible/`,
  `verify/`, the appliance tests) may name a hypervisor or cloud. The install
  layer (`packer/`, its tests, `scripts/`) and the documentation necessarily
  do; new platforms are added there as new source files and answer files. A test greps the
  appliance layer for this. The one exemption is the
  `qemu-guest-agent` package and unit name, which the guest-agent contract
  requires the appliance layer to manage.
- **Pinned inputs.** Tool versions in `ansible/group_vars/all/main.yml`,
  content in `content/manifest.yml`, container images by tag. No `latest`
  anywhere in a built image. A downloaded artifact is pinned by exact
  version and sha256. A package installed through a language package
  manager (the SAF CLI from npm, the Ansible collections from Galaxy) is
  pinned at its root: the package's own
  version is exact, and the package manager resolves its dependencies at
  build time within the ranges the package declares. SAFBox carries no
  lockfile for a tool's dependency tree.
  (Amended 2026-10-12 by the owner: root-dependency pinning replaces a
  committed lockfile for the SAF CLI. A full-tree lockfile's extra
  guarantee did not justify regenerating it, checking it against the pin,
  and the idempotence machinery `npm ci` needs.)
- **No secrets in the repository or the image.** Build credentials arrive via
  `PKR_VAR_*` environment variables or the Proxmox env file, never on a
  command line. `gitleaks` runs as a pre-commit hook on each developer's
  clone and, once CI exists, on every push; the hook alone does not travel
  with the repository. The seal's self-assertions and the validation profile enforce the image side.
- **Validation is the gate.** `packer build` fails if the outside-in InSpec
  run against the build VM does not meet `verify/thresholds/build.yml` (or
  the site threshold that replaces it), or if the
  seal's post-conditions are unmet. The threshold is evaluated by the SAF
  CLI, never reimplemented.
- **Two-audience docs.** Every user-facing feature lands with a line in the
  deploy guide and, if it changes the build, the rebuild guide.
- **Security by design.** Services bind to the proxy, not to all interfaces,
  except the proxy itself. Containers run with memory limits and without
  added capabilities. The firewall allows SSH and the proxy ports only.

### Shared Abstractions (built first)

| Shared need | Used by | Built in |
|---|---|---|
| `packer/build.pkr.hcl` shared provisioner chain (Ansible, outside-in validation, seal) and `variables.pkr.hcl` | every source, every phase | Phase 1 |
| `ansible/playbooks/safbox.yml` entrypoint and `group_vars/all/main.yml` (pins, group switches) | all roles | Phase 2 |
| `platform` role (OS contract, podman, Quadlet) | all service roles | Phase 2 |
| `base` role: first-boot framework (`/etc/safbox/`, `safbox-firstboot.service`, hooks) and the `safbox` command registry | heimdall, vulcan, proxy, content | Phase 2 |
| `tools` role | Phases 2 and 3 | Phase 2 (CINC Auditor) |
| `seal` role with self-assertions; `verify/` profiles, inputs, thresholds, `scripts/validate.sh` | every build and release | Phase 2 (layout amended 2026-10-13) |
| `content/manifest.yml` schema and loader | content role, `safbox content` | Phase 4 |

### Repository layout

```
safbox/
  packer/
    build.pkr.hcl              shared provisioner chain
    variables.pkr.hcl
    source-proxmox-el10.pkr.hcl   v1; ISO variable selects Rocky or Alma
    (source-qemu-el10, source-proxmox-ubuntu, source-vsphere-*, ... later;
     Packer loads only top-level *.pkr.hcl, so sources are files, not a folder)
    answerfiles/
      el10/ks.cfg.pkrtpl.hcl              shared by Rocky and Alma; fips=1 in the bootloader line
      (ubuntu/user-data, meta-data later; delivery is a variable, not a folder)
  ansible/
    playbooks/safbox.yml
    playbooks/seal.yml
    roles/<role>/{tasks,vars,templates,files,defaults}   platform, base, tools, seal, ...
    group_vars/all/main.yml
    requirements.yml           collections, pinned
  deploy/
    terraform/proxmox/          sample deployment, v1
    (terraform/vsphere, aws, azure later)
  content/
    manifest.yml
  verify/
    inspec-safbox/             root wrapper: includes every child; the build and release gates scan it
    el10-infrastructure/       SAFBox infrastructure controls, RHEL 10 family, impact 1.0 (findings low)
    safbox-rhel10-stig-overlay/  STIG overlay over the pinned MITRE baseline, deviations N/A
    inputs/{build,release}.yml       tracked inputs per context (--input-file)
    thresholds/{build,release}.yml   SAF CLI thresholds per context
    local/                     site inputs and thresholds (git-ignored)
  scripts/
    build.sh                   runs Packer; logs to .build/logs, last.log
    validate.sh                outside-in validation (CINC Auditor + saf)
    clone-and-ssh.sh           clone smoke test and release gate
    lock-stig-threshold.sh     regenerates a threshold's STIG lists from a scan
  ansible/roles/hardening/
    vars/deviations.yml        STIG IDs excluded, with justification
  docs/
    adrs/
    deploy.md
    rebuild.md
```

### Phases

#### Phase 1: Repo scaffold and first Packer build (unblocked, start here)
**Files:** `packer/build.pkr.hcl`, `packer/variables.pkr.hcl`,
`packer/source-proxmox-el10.pkr.hcl`, `packer/answerfiles/el10/ks.cfg.pkrtpl.hcl`,
`packer/example.pkrvars.hcl`, `scripts/build.sh`, `scripts/clone-and-ssh.sh`,
`tests/packer/validate.sh`, `tests/kickstart/ks-lint.sh`, `.gitignore`,
`.pre-commit-config.yaml`, `README.md`, `LICENSE.md`, `docs/rebuild.md`,
`docs/third-party.md`.
**Acceptance criteria:**
- [ ] `packer init` and `packer validate` pass with the proxmox and ansible
      plugins pinned.
- [ ] A build from the runner creates the VM on the configured node and pool
      from the RHEL 10 family ISO via kickstart, with no provisioning beyond
      the guest agent, cloud-init, and SSH, and converts it to a template.
- [ ] The same kickstart and source build from both the Rocky 10 and the
      AlmaLinux 10 x86-64-v2 ISO; the only input that changes is the ISO
      variable. Verified on Alma in the lab; Rocky verified when a v3 host is
      available.
- [ ] The template boots with `fips=1` on the kernel command line and
      `/proc/sys/crypto/fips_enabled` reads 1; the validation profile asserts this
      from Phase 2 onward.
- [ ] A clone of the template boots, receives a cloud-init user and key, and
      is reachable over SSH.
- [ ] Node, pool, VM IDs, storage, bridge, and ISO path are variables read
      from a git-ignored `*.auto.pkrvars.hcl`; the repository contains only an
      example file.
- [ ] Build credentials come from environment variables only.
- [ ] Documented in `docs/rebuild.md`: the headless default, the DVD ISO
      requirement for a GUI build, and Rocky 9 as the fallback if RHEL 10
      content blocks progress.
**Verification:** `packer validate packer/` then `packer build packer/`
followed by a scripted clone-and-ssh check.

#### Phase 2: Appliance foundation (blocked by Phase 1)
**Files:** `ansible/playbooks/safbox.yml`, `ansible/playbooks/seal.yml`,
roles `platform`, `base`, `tools`, `seal`, `verify/inspec-safbox/`,
`verify/threshold.yml`, `scripts/validate.sh`, `ansible/requirements.yml`.
(Amended 2026-10-11: originally `base`, `container_runtime`, `firstboot`,
`safbox_cli`, and an in-image `selftest` with `verify.yml`.)
**Acceptance criteria:**
- [ ] Playbook runs from the runner against the Packer VM via the `ansible`
      provisioner; second run reports zero changes.
- [ ] podman and Quadlet directories present; a trivial Quadlet unit starts on
      boot of a clone.
- [ ] `safbox-firstboot.service` runs once on first boot of a clone, creates
      `/etc/safbox/`, and does not run again.
- [ ] Seal removes the build user's authorized key and sudoers drop-in and
      deletes the account, removes SSH host keys, `machine-id`, cloud-init
      state, shell history, logs, `/root/*ks*.cfg`, `/var/log/anaconda`, and
      the installer's NetworkManager profile; drops the `unsealed` tag; a
      clone regenerates host keys and machine-id.
- [ ] The validation profile runs from the build runner against the build
      VM before the seal and gates the build through `saf validate
      threshold`; it asserts FIPS (kernel flag, crypto policy, OpenSSL
      provider), Secure Boot, qemu-guest-agent's default RPC block list
      intact, and records distribution and microarchitecture level. The
      seal asserts its own post-conditions. A clone passes the same profile
      as the deploy user.
- [ ] `ansible-lint` and `yamllint` clean.
**Verification:** `packer build`; `scripts/clone-and-ssh.sh` (runs
`scripts/validate.sh` against the clone).

#### Phase 3: Tooling roles (blocked by Phase 2)
**Files:** the `tools` role (one switchable group per tool: CINC Auditor
already exists as `safbox-tools-1`; SAF CLI, Ansible, Packer added here);
`group_vars/all/main.yml`; `docs/third-party.md` updated for Packer.
(Amended 2026-10-11: originally four roles `cinc_auditor`, `saf_cli`,
`ansible_tooling`, `packer_tool`.)
**Acceptance criteria:**
- [ ] `cinc-auditor`, `saf`, `ansible`, `packer` present at pinned versions;
      `safbox status` prints them.
- [ ] Ansible collections required by Lockdown playbooks installed and pinned.
- [ ] The Packer group is switchable like every group (`safbox_tools_<n>`).
- [ ] The role's `vars/RedHat.yml` and `vars/Debian.yml` cover every tool,
      the latter untested but present.
- [ ] Every installed tool is exercised once under FIPS enforcement (a
      trivial invocation that performs TLS or hashing) and the result is
      recorded as HDF by `verify/el10-fips-exercise`; failures become
      tracked issues, not silent gaps.
**Verification:** validation profile extended with version checks.

#### Phase 4: Content manifest and updater (blocked by Phase 3)
**Files:** `content/manifest.yml`, role `content`, `safbox content`
subcommands.
**Acceptance criteria:**
- [ ] Manifest seeded from the saf-site content data for, at minimum: RHEL 8,
      9, and 10 STIG, Ubuntu 20.04, 22.04, 24.04 STIG, Windows 10 and 11 STIG,
      Windows Server 2019 and 2022 STIG, Rocky 9 STIG-ready, Oracle Linux 8
      STIG profiles; and Ansible Lockdown roles for RHEL 8, 9, and 10, Ubuntu
      20.04, 22.04, 24.04, Windows Server 2019, 2022, and Windows 11. The
      RHEL 10 entries are the same pins the appliance's own hardening and
      overlay use. Final list confirmed by the decider before the card
      closes.
- [ ] Each entry pinned to a tag or commit with a checksum; vendored under
      `/opt/safbox/content/{profiles,playbooks}/`.
- [ ] `safbox content list|verify|status|update` work; `update` is a no-op
      offline with a clear message.
- [ ] One profile executes against localhost with CINC Auditor and produces
      HDF the SAF CLI can summarize.
**Verification:** validation profile asserts manifest and checksums; smoke scan.

#### Phase 5: Heimdall (blocked by Phase 2)
**Files:** role `heimdall` with Quadlet units for postgres and Heimdall, a
first-boot hook generating `DATABASE_PASSWORD`, `JWT_SECRET`,
`API_KEY_SECRET`; `versions.yml` image tags.
**Acceptance criteria:**
- [ ] On a clone, Heimdall is reachable through the proxy after first boot; a
      user can register, log in, and upload an HDF file.
- [ ] Secrets exist only in `/etc/safbox/heimdall.env`, mode 600, created on
      first boot, absent from the template.
- [ ] Units carry memory limits and restart policy; data lives in a named
      volume.
- [ ] Heimdall runs under FIPS enforcement, via the upstream fix or a pinned
      working build; if neither exists yet, the card closes with Heimdall
      documented as unavailable on this image and a tracked upstream link.
**Verification:** scripted upload via the Heimdall API against the clone.

#### Phase 6: Vulcan (blocked by Phase 2, parallel to Phase 5)
**Files:** role `vulcan` with Quadlet units for postgres and Vulcan; first-boot
hook generating `POSTGRES_PASSWORD`, `SECRET_KEY_BASE`, `CIPHER_PASSWORD`,
`CIPHER_SALT`; local login enabled, first user admin.
**Acceptance criteria:**
- [ ] On a clone, Vulcan is reachable through the proxy; the first registered
      user is admin and can create a project.
- [ ] Same secret and unit standards as Phase 5.
**Verification:** scripted registration and project creation on the clone.

#### Phase 7: STIG hardening with documented deviations (blocked by 3, 4)
**Files:** role `hardening` wrapping the pinned Ansible Lockdown STIG role,
`ansible/roles/hardening/vars/deviations.yml`, the STIG overlay profile
`verify/safbox-rhel10-stig-overlay/` (created early for the encryption-at-rest
deviation; depends on the pinned MITRE STIG baseline; already included by
the `verify/inspec-safbox` wrapper in both gates), `verify/thresholds/`
updated: the STIG control lists locked at the pre-hardening state are
regenerated from the hardened result with `scripts/lock-stig-threshold.sh`.
**Acceptance criteria:**
- [ ] Lockdown role and MITRE baseline for the base release pinned in the
      manifest at matching STIG releases.
- [ ] `deviations.yml` lists each excluded STIG ID with justification; the
      hardening role disables exactly those rules and the overlay marks
      exactly those controls Not Applicable with the same text. A check fails
      the build if the two sets differ.
- [ ] Hardening runs after all other roles and before validation and the seal; the
      Packer SSH session survives it.
- [ ] Validation passes `verify/thresholds/` on a clean build; the remaining
      failures, if any, are listed and justified in the deploy guide.
- [ ] Heimdall, Vulcan, podman, and the proxy still work on a hardened clone.
**Verification:** `packer build`; overlay profile result summarized with
`saf summary`; deviation-set consistency check in `scripts/deviations-check.sh`.

**Outcomes (amended 2026-10-14):**
- *Three records, kept apart.* `deviations.yml` holds only owner-approved
  deviations (N/A in the overlay, same text). Rules switched off only
  because their Lockdown task errors go in
  `ansible/roles/hardening/vars/not_applied.yml`: no reason code, no
  overlay override, and the control's actual result is locked as it is.
  Baseline content defects that are not deviations (a control that
  misreports) go in `verify/safbox-rhel10-stig-overlay/known-defects.yml`,
  with the upstream issue once filed. `docs/deviations.md` is generated
  from all three plus the release threshold's failing lists, each failure
  marked known defect, task failed, or not yet triaged.
- *One firewall zone.* `safbox_firewall_zone` (`drop` with hardening,
  `public` without) feeds Lockdown's zone and every role's firewalld task,
  because hardening moves the interface into Lockdown's zone.
- *Build and release STIG lists differ.* The build VM is not rebooted
  after hardening (a reboot would run first boot inside the template), so
  settings that take effect at boot fail in the build context and pass on
  a clone.
- *Idempotence tolerance.* The pinned Lockdown release reports one change
  on every run (an unconditional reboot warning). Against the "second run
  is a no-op" standard, `tests/ansible/idempotence.sh` tolerates exactly
  that one named task and nothing else, until card safbox-m5f.33 gets it
  fixed upstream and removes the tolerance.

#### Phase 8: Proxy, landing page, and release gate (blocked by 5, 6, 7)
**Files:** role `proxy` (nginx Quadlet, self-signed cert at first boot,
landing page template), `safbox services`, final `verify/thresholds/`,
`deploy/terraform/proxmox/` (provider pin, variables, clone from template,
cloud-init user data, outputs), `docs/deploy.md`, `docs/rebuild.md`.
**Acceptance criteria:**
- [ ] HTTPS landing page on 443 shows service status and links; Heimdall and
      Vulcan on their configured ports behind TLS.
- [ ] Firewall allows only SSH and proxy ports.
- [ ] Full build on the reference footprint passes validation; a reduced
      build on a constrained host passes with Vulcan disabled.
- [ ] `terraform apply` in `deploy/terraform/proxmox/` deploys a SAFBox from
      the template with a cloud-init user and key and outputs its address;
      `terraform destroy` removes it. Site values come from a git-ignored
      tfvars file with a committed example.
- [ ] Both guides complete enough for a stranger to deploy and to rebuild.
**Verification:** full `packer build`, clone, and a documented manual
walkthrough of both guides.

**Outcomes (proposed 2026-10-14, for owner review):**
- *Landing page status from a timer, through SSI.* The landing page is a
  static page the proxy role renders; nginx includes one status file per
  service with server-side includes. A sandboxed oneshot service without
  capabilities writes the files from `safbox services` every 30 seconds,
  run by a systemd timer. No status daemon and no request path to systemd;
  the status may be 30 seconds old, and the page says so.
- *`safbox services` reads a registry.* Each service role registers its
  service (label and units) in `/usr/local/share/safbox/services.d/`, so
  the command and the landing page cover whichever services an image ships.
- *The firewall allows SSH and the proxy ports only, exactly.*
  `safbox_firewall_services` (`[ssh]`) is the one list of zone services;
  Lockdown's whitelist derives from it, dropping the `dns` and `ntp` it
  adds by default (they admit inbound queries to servers SAFBox does not
  run; the box's own client traffic returns as related), and the roles
  remove anything else. STIG results are unchanged.
- *Deployment module.* `deploy/terraform/proxmox/` uses `bpg/proxmox`
  pinned exactly, with its lock file committed (a downloaded artifact
  pinned by version and checksum), and sets the template's firmware
  explicitly because the provider applies its own defaults to a clone. The
  platform-discipline test allows `deploy/` as the install layer's mirror.

#### Phase 9 and later (not v1)
- `qemu` source producing qcow2 for distribution, with OVA and cloud image
  conversion. GitHub-hosted Ubuntu runners expose KVM, so this can run in CI
  without self-hosted hardware.
- Hardening the nginx proxy against its CIS benchmark with the SAF nginx
  profile added as an overlay of its own, alongside the STIG overlay.
- `site_config` role, driven by cloud-init user-data or a `safbox site`
  subcommand, covering package mirror, corporate proxy, DNS, NTP, routing,
  and CA bundles, so a deployed appliance can be adopted into the local
  network without hand edits. Design question to settle then: which of these
  belong in cloud-init natively and which need the role.
- Ubuntu LTS source and autoinstall; Debian variables exercised; Ubuntu
  STIG and FIPS story decided at that time.
- vSphere, AWS, Azure Packer sources and the matching Terraform deploy
  modules.
- Optional `k3s` role and Helm deployment profile.
- Image signing, SBOM, provenance; STIG-hardening the appliance itself.

### Decision: base release and benchmark
v1 is **Rocky Linux 10** hardened to the **DISA RHEL 10 STIG**. The
hardening role pins the Ansible Lockdown RHEL10-STIG role and the overlay
profile pins the MITRE RHEL 10 STIG baseline, both at the same STIG release.
Deviations carry one of three reason codes: `usability` (deliberately
relaxed for the non-expert audience, for example account lockout),
`content-defect` (an upstream role or profile bug, with the issue link, to be
retired when fixed), and `deploy-time` (a requirement only the consumer's
environment can satisfy, such as a site CA or syslog target). The FIPS
requirement is expected to pass, not to be deviated.

When Ubuntu is added as the second base, its STIG availability and its FIPS
story (Ubuntu Pro entitlement) are decided in that phase, under this ADR.

### Decision: encryption at rest
(Amended 2026-10-12.) SAFBox does not encrypt at the operating-system level,
and in-image encryption is not planned. A distributable template cannot hold
a per-deployment secret: any LUKS keyslot that lets the template boot
unattended is shared by every copy. RHEL-10-000510 (SV-280935) therefore
cannot be implemented as written inside a SAFBox VM, whatever documentation
the deploying site holds; data at rest is protected by the layer beneath the
guest (the hypervisor datastore, storage array, or cloud volume service).

The STIG overlay (`verify/safbox-rhel10-stig-overlay`) sets SV-280935 Not
Applicable itself, following the SAF overlay convention: impact 0.0, a
`justification` description giving the reason above, and a deliberate
`describe ... skip`. It does not set the baseline's `data_at_rest_exempt`
input, which records a documented organisational exemption from the
requirement, a different claim from "cannot be implemented on this device".
(Amended 2026-10-13 by the owner.) The requirement joins `deviations.yml`
when Phase 7 creates it.

### Verification Strategy
- **Static:** `packer fmt -check`, `packer validate`, `ansible-lint`,
  `yamllint`, `gitleaks`, platform-discipline grep. Runs in GitHub Actions on
  every push; no hypervisor needed.
- **Build:** `packer build` from a workstation against a Proxmox target for
  now; later from a self-hosted runner or the `qemu` lane.
- **Image:** the `verify/inspec-safbox` wrapper (the infrastructure
  controls and the STIG overlay over the base OS baseline with deviations
  marked Not Applicable) runs from the build runner before the seal, gated
  by the build threshold, every build; seal self-assertions every build.
- **Release:** a booted clone passes the same wrapper from outside, gated
  by the release threshold, before an image is published.
- **On-box exercises:** every test that talks to the box over SSH is an
  InSpec profile run from the build runner with its own threshold, so its
  results are HDF. `verify/el10-fips-exercise` runs each tool doing TLS or
  hashing under FIPS enforcement, with each tool whose crypto bypasses the
  system FIPS provider recorded as a failing low-severity finding that the
  threshold names; `verify/el10-firstboot` exercises the first-boot runner
  and secrets library in a scratch tree it removes. Neither is in the
  wrapper: one needs outbound HTTPS, the other writes files. Local tooling
  (lint, Packer validate, kickstart lint, repository static checks, the
  playbook idempotence run) stays shell. (Amended 2026-10-12 by the owner.)
- **Deployment:** clone the template via cloud-init; InSpec checks run over
  SSH (the release-gate wrapper and the on-box exercise profiles) for SSH
  access, first-boot completion, service health, Heimdall upload, Vulcan
  registration.
- **Edge cases:** second Ansible run is a no-op; clone of a clone still gets
  fresh secrets and host keys; offline `safbox content update` fails cleanly;
  reduced-footprint build with services disabled; template retains no
  secrets; Alma and Rocky builds from the same inputs differ only in
  distribution branding, which the build record reports.

### CI and runner strategy
Static checks run on GitHub-hosted runners from day one. Image builds need a
hypervisor: a workstation against a Proxmox target for now, a self-hosted
runner later, and a KVM-capable hosted runner for the `qemu` distribution lane
in Phase 9. Any Proxmox account used to build must be least-privilege: a pool
that authorizes creation, optional reserved VM IDs as a ceiling, one storage
for disks, one for ISOs, one bridge, one node. Build and deploy tooling must
name the pool on every create or clone.
The concrete node, pool, IDs, and storage names are never committed; they live
in the builder's local variables file.
