# Rebuilding SAFBox

This guide covers producing the SAFBox template yourself. It assumes a
Proxmox VE 8 or 9 cluster and a workstation with Packer.

## Base image and firmware

- **Release base:** Rocky Linux 10. Requires an x86-64-v3 capable host (AVX2).
- **Development base:** AlmaLinux 10 x86_64_v2, for build hosts whose CPUs
  predate AVX2. Same kickstart, same STIG content, same appliance layer; only
  the ISO changes. Images built from it are development artifacts, and the
  build record and `safbox status` show which distribution an image came
  from.
- **Firmware:** UEFI (OVMF, q35) with Secure Boot keys pre-enrolled. RHEL 10
  deprecates legacy BIOS installation.
- **FIPS:** enabled at installation (`fips=1` on the installer command line
  and carried onto the installed bootloader). It cannot be turned on later on
  RHEL 10, and it is never turned off. Use RSA or ECDSA SSH keys; Ed25519 may
  be rejected under the FIPS policy.
- **Headless by default.** The `environment_group` variable selects the
  kickstart environment. `minimal-environment` installs from the minimal ISO.
  A desktop (`graphical-server-environment`) needs the full DVD ISO or a
  reachable package mirror; the minimal ISO carries no GUI packages.
- **Fallback:** if the RHEL 10 STIG content proves too immature, Rocky Linux 9
  is the recorded fallback (ADR-0001, Alternative I). It is a different
  kickstart version and different content pins, not a flag.

## Partition layout

The kickstart creates separate filesystems for `/home`, `/tmp`, `/var`,
`/var/tmp`, `/var/log`, and `/var/log/audit`, as the RHEL STIG requires, plus
`/boot`, `/boot/efi`, and swap. Partitioning cannot change after install, so
this is decided in the install layer. The fixed portion is about 32 GiB;
`/var` takes the rest because container images live there. Give the disk at
least 40G.

## Build host

A Proxmox node with an x86-64-v3 CPU (AVX2, roughly 2013 or newer), room for
a 4 vCPU, 8 GiB, 60 GiB VM, and the DVD or minimal ISO on its ISO storage.
Timeouts and waits are variables; raise them on a slow host before
suspecting the pipeline.

Older x86-64-v2 hardware can build from the AlmaLinux `x86_64_v2` ISO with a
few site overrides (CPU model, and third-party packages built for v3); see
"Site overrides" below.

## Hypervisor prerequisites

What the human has to set up on the hypervisor before a build can run is
target-specific. For Proxmox, follow [docs/guides/proxmox/build.md](guides/proxmox/build.md):
ISO upload, the least-privilege API token, pool and ACLs, and the variables
file. Other targets get their own guide alongside their Packer source.

## Workstation prerequisites

- Packer 1.12 or newer; plugins are pinned and installed by `packer init`
- Ansible on the workstation (`pipx install --include-deps ansible==14.5.0`;
  see the Proxmox guide's Prerequisites for which Ansible); the build runs the
  appliance playbooks from here against the build VM, and installs the
  pinned collections from `ansible/requirements.yml` itself
- CINC Auditor and the SAF CLI on the workstation; the build validates the
  VM from here, and the clone test uses them as the release gate.
- `pipx install pykickstart` for the kickstart lint. The versions the
  static suite is verified with are pinned in `tests/requirements.txt`
- `pre-commit install` after cloning (gitleaks, shellcheck, packer fmt,
  kickstart lint). If you also use beads, `bd init` sets `core.hooksPath`
  to `.beads/hooks` and `pre-commit install` refuses to run. Unset the
  option, install, set it back, and append a chain to the beads shim:

  ```
  git config --unset core.hooksPath && pre-commit install && git config core.hooksPath "$PWD/.beads/hooks"
  cat >> .beads/hooks/pre-commit <<'EOF'
  if [ -x "$(git rev-parse --show-toplevel)/.git/hooks/pre-commit" ]; then
    "$(git rev-parse --show-toplevel)/.git/hooks/pre-commit" "$@" || exit $?
  fi
  EOF
  ```

  Prove it with a staged file containing a fake AWS key: the commit must be
  refused.
- A `0600` file with the token, by default `~/.config/proxmox/packer.env`:

```
PROXMOX_URL=https://<host>:8006/api2/json
PROXMOX_USERNAME=<user>@pve!<token-name>   # the token ID
PROXMOX_TOKEN=<token-secret>              # the UUID printed at creation
```

Never put credentials in a vars file.

## Site variables

Copy `packer/example.pkrvars.hcl` to `packer/local.auto.pkrvars.hcl` (ignored
by git) and set your node, pool, VM ID, ISO, storage, and bridge. Reduce
`vm_cores`, `vm_memory`, and `vm_disk_size` for a small host; the reference
footprint is 4 vCPU, 8 GiB, 60G. If your workstation has several network
interfaces, set `http_interface` to the one that faces Proxmox, because the
VM fetches its kickstart from a temporary HTTP server on the workstation.

## Site overrides

The repository describes the normal case. Anything particular to your site
goes in two git-ignored files:

- `packer/local.auto.pkrvars.hcl` for Packer variables (node, pool, storage,
  ISO, CPU model, resources).
- `ansible/local.yml` for Ansible variables. Pass it to every playbook by
  adding `"@<absolute path>/ansible/local.yml"` to `ansible_extra_vars` in
  the Packer file, or `-e @ansible/local.yml` when running a playbook by
  hand. Values there replace the project's defaults in
  `ansible/group_vars/all/main.yml`.

Example: on x86-64-v2 hardware, set `cpu_type = "x86-64-v2-AES"` in the
Packer file, and in `ansible/local.yml` replace `safbox_tool_cinc_auditor`
with CINC's el9 build (its el10 build requires x86-64-v3).

## Kickstart delivery and locked-down networks

During the install the VM fetches its kickstart over plain HTTP. By default
Packer runs a temporary, unauthenticated web server on the workstation and
the kickstart URL points at it, so the **VM's network must be able to reach
the workstation**, and anyone on that segment could answer in its place.
Being able to reach the Proxmox API is not enough, and the segment is
trusted. Set `http_bind_address` so the server listens on the build-facing
address only. For release builds, host the rendered kickstart over HTTPS and
set `kickstart_url` (Anaconda verifies the certificate), or use the ISO
route below. In a segmented environment
where the build VLAN cannot route back to wherever Packer runs, you have
three options:

1. **Run Packer from a host on the VM's network**, such as a jump host or a
   self-hosted CI runner in that segment. No configuration change.
2. **Host the kickstart yourself.** Render it, put it on any internal web
   server the VM can reach, and set `kickstart_url` in your local vars. The
   build then never relies on the workstation's HTTP server. The rendered
   kickstart contains the build user's public key but no secret.
3. **Kickstart on a second CD.** Anaconda loads `ks.cfg` from any volume
   labelled `OEMDRV` without a kernel argument. Packer can build and attach
   such an ISO, but on Proxmox that means uploading it to an ISO storage,
   which needs the `Datastore.AllocateTemplate` privilege the least-privilege
   token deliberately lacks. Grant it on a dedicated ISO storage if you take
   this route. Not implemented in v1.

## Build

```
tests/packer/validate.sh         # fmt, init, validate with the example vars
tests/kickstart/ks-lint.sh       # render and lint the kickstart
scripts/build.sh                 # mints an ephemeral build key, runs packer
```

Each run keeps its log, key pair and Packer debug log in its own
`.build/runs/<run id>/`, and `last.log` in the repository root points at the
newest run's log, so `tail -F last.log` follows the current build (and the
next one, without restarting `tail`). To run builds in parallel, see
"Running builds in parallel" in the
[Proxmox guide](guides/proxmox/build.md#running-builds-in-parallel).

The build types a short GRUB edit at the ISO menu, serves the kickstart,
waits through the install and reboot, confirms FIPS, Secure Boot, and the
guest agent over SSH, runs the appliance playbook, validates the VM from this
machine (`scripts/validate.sh`: CINC Auditor over SSH, then the SAF CLI
threshold), seals the image (deletes the build user, scrubs host identity and
installer residue, asserts the seal's own post-conditions), and converts the VM to a
template. Set `seal = false` in your local vars for a development build: the
development seal still records the build and scrubs machine identity,
cloud-init state and installer residue, but keeps the build user, its key,
the SSH host keys and the logs for inspection. Such a template is tagged
`unsealed`. It is also not verified: the seal's post-conditions (no build
user, host keys, machine identity, installer residue, first-boot secrets,
network profiles, root's tool residue, or files left in `/tmp` and
`/var/tmp`) run only in the full seal, so a development template can carry
leftovers a full seal would refuse.

## How a build is validated

Three checks, at three moments:

1. **During the build**, before the seal, `scripts/validate.sh` scans the
   build VM from your workstation over SSH in the `build` context, and the
   SAF CLI thresholds decide whether the build continues. Nothing is
   installed on the image for this.
2. **At the end of the seal**, the seal's own final script asserts that the
   build user, its sudo rule, host keys, machine identity, cloud-init
   instance state, installer residue, first-boot secrets, and build-VM
   network profiles are all gone. Nothing outside can log in afterwards, so
   the seal checks itself; any miss fails the build.
3. **Before publishing an image** (the release gate), a clone is booted and
   scanned from outside as the deploy user in the `release` context, which
   also proves what only a first boot does: the secrets, the certificate and
   the running services.

### The profiles

Two InSpec profiles live in `verify/profiles/`:

| Profile | Checks |
|---|---|
| `verify/profiles/safbox` | the appliance itself: OS, FIPS mode, Secure Boot, accounts, the hardening record, the tools at their pinned versions, Heimdall, Vulcan and the TLS proxy, and on a clone the seal and first boot |
| `verify/profiles/safbox-rhel10-stig-overlay` | the pinned MITRE RHEL 10 STIG baseline, with SAFBox's deviations marked Not Applicable |

`verify/profiles/safbox` is plain InSpec: `package`, `service`, `port`,
`file`, `http`, `parse_config_file` and the like, one control per thing
an operator cares about, grouped in `os.rb`, `accounts.rb`, `hardening.rb`,
`tools.rb`, `services.rb` and `sealed.rb`. Its inputs, with defaults in its
`inspec.yml`, are what a site varies: which tools and services the image
ships (`expected_tools`, `expected_services`), the CA roots it trusts
(`trusted_roots`), the pinned versions, and `deployed`, which is true on a
clone and false on the build VM (`verify/inputs/build.yml`). A control that
does not apply (a service switched off, a clone-only control on the build
VM) is Not Applicable and does not count. Pin changes in
`ansible/group_vars/all/main.yml` need the matching input default changed
too.

The overlay fetches its pinned baseline from GitHub on each scan, so the
workstation needs network access.

### `scripts/validate.sh`

```
scripts/validate.sh [--site-inputs FILE] [--ssh-config FILE] \
  <user@host[:port]> <private-key> <build|release> [label]
```

It scans both profiles and checks each against its threshold. Results land
in `.build/validate-<label>-<profile>-<timestamp>.json`, readable in
Heimdall. `--site-inputs` is layered after the context's inputs (its values
win); `--ssh-config /dev/null` stops CINC Auditor reading an SSH client
config it cannot use.

### The thresholds

`verify/thresholds/` holds three short SAF CLI threshold files, written by
hand:

- `safbox.yml`, for the safbox profile in both contexts: a compliance
  percentage and no errors.
- `stig-build.yml` and `stig-release.yml`, for the overlay: a compliance
  percentage taken from a real scan in that context, rounded down, no
  failed control of critical severity and no errors. The build VM has not
  rebooted since hardening, so some settings apply only on a clone and the
  build percentage is lower.

A comment in each file says which scan its percentage came from. When the
image gets better, raise the percentage by hand from a new scan.

### Site inputs

A site that builds a different image than the repository default (a tool
or service switched off, a pin overridden) writes an inputs file in
`verify/local/`, which is git-ignored, for example
`verify/local/inputs.yml`:

```
---
expected_tools: [cinc-auditor, saf-cli, ansible]
```

and names it to the build in `packer/local.auto.pkrvars.hcl`
(`build_gate_site_inputs_file = "verify/local/inputs.yml"`) and to the
release gate with `SAFBOX_SITE_INPUTS`. The controls of a switched-off tool
or service become Not Applicable, so the thresholds need no change.

## Prove the template (release gate)

```
SAFBOX_NODE=<node> SAFBOX_POOL=<pool> scripts/clone-and-ssh.sh <template-vmid> <clone-vmid>
```

Clones the template through the API into the pool, injects a cloud-init
user and an RSA key, boots it, learns the IP from the guest agent, logs in
as that user, asserts FIPS mode is on and cloud-init applied the clone's
hostname, then runs `scripts/validate.sh` against the clone. Set
`SAFBOX_CA_FILE` to the cluster CA, or `SAFBOX_INSECURE_TLS=1` for a
throwaway lab. Pass `--keep` as a third argument to leave the clone running;
set `SAFBOX_SKIP_VALIDATE=1` to stop after the SSH check. The clone is only
ever destroyed if it carries this run's ID. A template built with
`seal = false` is unsealed and not distributable; see the Proxmox guide.

## Choosing what the appliance layer does

Every task group in the `platform`, `site_config`, `base`, `tools` and
`services` roles is a block tagged `safbox-<role>-<n>` with a switch
`safbox_<role>_<n>` (default on), in the style of Ansible Lockdown (a
hyphen for the underscore in the tag: `safbox-site-config-1`, switch
`safbox_site_config_1`). The switches and a one-line description of each
group are listed in `ansible/group_vars/all/main.yml`.

- Turn a group off for every build by setting its switch to `false` in
  `ansible/local.yml` (site overrides, git-ignored).
- Run or skip groups for one invocation with `--tags` / `--skip-tags`, for
  example against an existing host, from the repository root
  (`ANSIBLE_CONFIG` names the project's configuration, which finds the
  roles):
  `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i <host>, -u <user> ansible/playbooks/safbox.yml -e @ansible/local.yml --tags safbox-platform-3`
- The `seal` role's groups are tagged (`safbox-seal-<n>`) but have no
  switch: a partially sealed image carries build identity, so the seal runs
  whole. The one exception is the development seal (`seal = false`), which
  stops before the final group and marks the template `unsealed`.
- Each `tools` group (CINC Auditor, SAF CLI, Ansible with the Lockdown
  collections, Packer) has a validation control `safbox-tools-<n>`. The
  profile's `expected_tools` input lists the tools the image ships (default
  `cinc-auditor`, `saf-cli`, `ansible`, `packer`); a tool expected but
  missing fails its control. When you switch a tools group off, drop its
  tool from that input in a site inputs file (see "Site inputs" above);
  its control is then Not Applicable. A distributor who does not
  want to ship Packer's Business Source License sets `safbox_tools_4:
  false`; see `docs/third-party.md`.
- The `services` role holds every long-running service, one task group and
  one task file each: `safbox_services_1` Heimdall (`tasks/heimdall.yml`),
  `safbox_services_2` Vulcan (`tasks/vulcan.yml`), `safbox_services_3` the
  TLS proxy (`tasks/proxy.yml`). A host short of memory runs Heimdall alone
  with `safbox_services_2: false`; the proxy then serves Heimdall only and
  closes Vulcan's port. The profile's `expected_services` input lists
  the services the image ships (default `heimdall`, `vulcan`, `proxy`):
  drop a switched-off service there in a site inputs file, as for a tools
  group.
- `safbox_site_config_1` installs the site's CA bundles, the DoD PKI bundle
  by default; see "Site CA bundles" below.

### Migrating from the per-service roles

Heimdall, Vulcan and the TLS proxy were once three roles (`heimdall`,
`vulcan`, `proxy`), each with one switch. They are now the task groups of
the `services` role. The old switches are not read any more, so a site that
set one in `ansible/local.yml` must rename it, or the service it had
switched off is built again:

| Old switch | New switch | Old tag | New tag |
|---|---|---|---|
| `safbox_heimdall_1` | `safbox_services_1` | `safbox-heimdall-1` | `safbox-services-1` |
| `safbox_vulcan_1` | `safbox_services_2` | `safbox-vulcan-1` | `safbox-services-2` |
| `safbox_proxy_1` | `safbox_services_3` | `safbox-proxy-1` | `safbox-services-3` |

Rename the tags the same way in any `--tags` or `--skip-tags` you pass.
The role's own variables now carry the role's name as a prefix
(`heimdall_memory` is `services_heimdall_memory`, `vulcan_settings` is
`services_vulcan_settings`, `proxy_tls_dir` is `services_proxy_tls_dir`,
and so on for every `heimdall_*`, `vulcan_*` and `proxy_*` variable in
`ansible/roles/services/defaults/main.yml`); rename any you override in
`ansible/local.yml`, which otherwise has no effect.

The validation controls of the services keep their names
(`safbox-heimdall-*`, `safbox-vulcan-*`, `safbox-proxy-*`). A control
never shares its name with the tag of a task group it does not check (the
`hardening` and `tools` controls are named after their groups because they
check exactly what those groups do), so the controls that had a group's
name are renamed:

| Old control | New control | Checks |
|---|---|---|
| `safbox-services-1` | `safbox-system-1` | the guest agent, cloud-init and sshd enabled, sshd running |
| `safbox-services-2` | `safbox-system-1` | chrony and firewalld running, SSH allowed (merged into `safbox-system-1`) |
| `safbox-services-3` | `safbox-system-3` | the journal kept on disk |
| `safbox-platform-1` | `safbox-os-1` | the operating system is one the appliance supports |
| `safbox-platform-2` | `safbox-os-2` | the CPU supports the image's x86-64 level |
| `safbox-seal-1` | `safbox-sealed-1` | the build user, its key and its sudo rule are gone |
| `safbox-seal-2` | `safbox-sealed-2` | no installer residue |


## Site CA bundles

The `site_config` role adds CA certificates to the system trust store, so
the box, its tools, and the Heimdall and Vulcan containers trust servers
those CAs sign. It runs right after `platform`, so the roles after it
(the tools downloads, the container image pulls) already use the new
store; `platform`'s own package installs, and the role's install of
OpenSSL and unzip, use the store the box had before. No certificate is
kept in the repository: each bundle is downloaded by the box or copied
from your workstation when the role runs.

**DoD PKI, on by default.** The DoD root and issuing CAs (DoD Root CA 3 to
6 and their subordinates) come from DISA's public PKI library at a pinned
URL, checked against a pinned sha256 (`safbox_trust_bundle_dod`), and the
default list trusts them:

```
safbox_trust_bundles:
  - "{{ safbox_trust_bundle_dod }}"
```

To build or run without them, set the list to `[]` (or to your own
bundles only) in `ansible/local.yml`. The role then removes any DoD anchor
a previous run installed.

**Network at build.** Because the DoD bundle is on by default, every build
and every run of this group downloads it from `dl.dod.cyber.mil`, so the
build VM (or the box) needs outbound HTTPS to that host. On a network
without it, give the same file as a local path instead: download the zip
once on a connected machine, check it with `sha256sum` against the pin,
carry it to the machine that runs Ansible, and put in `ansible/local.yml`:

```
safbox_trust_bundles:
  - name: dod
    path: /absolute/path/to/unclass-certificates_pkcs7_DoD.zip
    sha256: "{{ safbox_trust_bundle_dod.sha256 }}"
    format: "{{ safbox_trust_bundle_dod.format }}"
    member: "{{ safbox_trust_bundle_dod.member }}"
```

The role copies it to the box and checks the same sha256, so the result is
identical to the download.

**When DISA releases a new bundle.** DISA replaces the file behind the
pinned URL with each release. The download then no longer matches the pin
and, with the DoD bundle on by default, every build and every run of this
group fails rather than trust content nobody reviewed, until the pin is
updated as the comment above `safbox_trust_bundle_dod` describes (DISA's
signed manifest inside the zip, then the version, sha256 and member, and
the root fingerprints of the profile's `trust_bundle_anchors` input). A
site that cannot wait can build from a local copy of the pinned release as
above, or remove the DoD bundle.

**Your own bundle.** Add an entry beside the DoD one (or instead of it):

```
safbox_trust_bundles:
  - "{{ safbox_trust_bundle_dod }}"
  - name: example-org           # lowercase letters, digits, hyphens
    path: /home/me/pki/example-org-ca.pem   # absolute, on the machine running Ansible
    sha256: <sha256sum of that file>
    format: pem                 # pem, der, pkcs7-der or pkcs7-pem
```

or `url: https://...` instead of `path` for a file the box downloads, and
`member: <path inside the zip>` (relative, without `..`) when the file is
a zip archive, as DISA's is. Every entry needs its sha256: a download or
file that does not match fails the run, and nothing from any bundle is
trusted. A malformed entry (an unknown format or key, both or neither of
`url` and `path`, a relative `path`, two bundles with one name) is refused
before anything is fetched.

**What the role does.** It reads each bundle with OpenSSL, writes one
anchor file per certificate (`safbox-<bundle>-<id>.pem` in
`/etc/pki/ca-trust/source/anchors`; one per certificate because the
Debian family's mechanism needs it), runs `update-ca-trust`, and removes
the anchors of any certificate no longer configured, so dropping a bundle
from the list untrusts it. Before installing anything it verifies every
certificate under the system crypto policy (`openssl verify` at the
policy's security level, each signature checked, a root's own included,
expiry not judged): a root the FIPS policy would refuse in use, such as a
SHA-1 signature, an RSA key shorter than 2048 bits or an elliptic curve
FIPS mode does not offer, fails the run and is named, rather than trusted
on paper and rejected silently later. Every certificate of the DoD bundle
passes on a FIPS-mode SAFBox.

**Containers.** Heimdall and Vulcan mount the host's extracted trust store
(`/etc/pki/ca-trust/extracted`) read-only where their Red Hat UBI images
read their own, so their Node.js and Ruby trust exactly what the host
trusts. When the store changes on a running box, the role restarts
`heimdall.service` and `vulcan.service`, which read it at start.

SELinux labels the host's certificate files `cert_t`, which a container
(`container_t`) may not read; the `platform` role turns on the
container-selinux boolean `container_read_certs` to allow it. The boolean
is host-wide: it lets every container read every `cert_t` file mounted
into it, and `cert_t` covers private keys too (`/etc/pki/tls/private`,
for example), so a future unit that mounted such a directory would expose
those keys to its container without any SELinux denial. SAFBox accepts
this because a container reaches only what its unit mounts, the units are
the appliance's own (reviewed here, checked by the validation profile),
the only `cert_t` path any of them mounts is the public extracted store,
and the proxy's private key lives in `/etc/safbox/tls`, labelled for its
container alone. The alternative, relabelling the store for containers,
would change the label the host's own programs rely on. Mount nothing
else under `/etc/pki` into a container.

**At build or on a deployed box.** The list in effect at build (the
default, or `ansible/local.yml` named to the build, see "Site overrides")
is baked into the image. On a box that is already deployed, apply only
this group from the repository root on your workstation, with the same
`ansible/local.yml` if you use one (drop `-e @ansible/local.yml` for the
repository defaults; `ANSIBLE_CONFIG` names the project's configuration,
which finds the roles):

```
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i <box>, -u <user> --private-key <key> \
  ansible/playbooks/safbox.yml -e @ansible/local.yml --tags safbox-site-config-1
```

A second run changes nothing.

**Validation.** `safbox-trust-1` checks that the CA roots named in the
input `trusted_roots` (by default the four DoD roots, by label, as `trust
list` shows them) are in the system trust store. A site that changes the
list names its roots in its site inputs file, for the build gate and the
release gate alike: `trusted_roots: []` without the DoD bundle, or the
labels of its own roots.

## STIG hardening and deviations

The `hardening` role is the last role of the appliance play. It applies the
DISA RHEL 10 STIG with the Ansible Lockdown RHEL10-STIG role, pinned in
`ansible/group_vars/all/main.yml` (`safbox_hardening_lockdown`: release,
the commit its tag names, and the STIG release) and installed on the build
runner from `ansible/requirements.yml` by that commit. The build installs it
itself; to run the playbook by hand, install it first from the `ansible/`
directory:

```
ansible-galaxy install -r requirements.yml   # roles go to ansible/galaxy_roles/ (git-ignored)
```

The role refuses to run if another version of the Lockdown role is
installed.

**The deviation record is the STIG overlay.** Each requirement SAFBox
deliberately does not apply is a Not Applicable override, with its
justification, in
`verify/profiles/safbox-rhel10-stig-overlay/controls/overlay.rb`; a scan's
results carry the same text, readable in Heimdall. The hardening role
switches the matching Lockdown rule off in the Lockdown section of
`ansible/group_vars/all/main.yml`, one `rhel10stig_<n>: false` per
line with a one-line comment. A few lines there are not deviations: their
Lockdown task fails on SAFBox, so the rule is off, and the baseline control
still runs and reports what it finds. To add a deviation, add the override
to the overlay and the switch to group_vars; every new deviation is an
owner decision.

Lockdown's own variables are the knobs for everything else: set any
`rhel10stig_*` value in `ansible/local.yml` (a rule switch to `false`, a
banner text, a time server). Hardening does not reboot the build VM,
because a reboot would run the first-boot unit inside the template; kernel
arguments and some other settings take effect when a clone first boots, so
the build STIG threshold is lower than the release one.

Known upstream defect: the pinned Lockdown release ends every run with
`POST | Warning a reboot required but skip option set`, a task marked
`changed_when: true`, so a second playbook run reports `changed=1`.
`tests/ansible/idempotence.sh` tolerates exactly that task, matched by its
name; any other change fails the check. The tolerance goes when a fixed
Lockdown release is pinned.

Known failure from the Vulcan image: SV-281045 (RHEL-10-400140,
world-writable directories must be owned by a system account) fails on
every SAFBox that ships Vulcan, and passes without it. The baseline runs
`find <every /etc/fstab mount point> -xdev -type d -perm -0002 -uid +999`,
and podman keeps image layers in `/var/lib/containers/storage` on `/var`,
so directories inside a pulled image are scanned like any host directory.
The pinned `mitre/vulcan` 2.4.1 image ships four gem directories with mode
0777, owned by uid 1000, all in the layer its `COPY /usr/local /usr/local`
step creates:

```
/usr/local/bundle/ruby/3.4.0/gems/faraday-2.14.3/spec/faraday/adapter
/usr/local/bundle/ruby/3.4.0/gems/fuzzyurl-0.9.0/lib/fuzzyurl
/usr/local/bundle/ruby/3.4.0/gems/globalid-1.4.0/lib/global_id/uri
/usr/local/bundle/ruby/3.4.0/gems/reline-0.7.0/lib/reline/io
```

On the box they appear as
`/var/lib/containers/storage/overlay/<layer>/diff/usr/local/bundle/...`.
The gem archives are not the cause: none of them contains a directory
entry, and every file in them is 0644. The cause is a race during the
image build's `bundle install`. Bundler installs gems in parallel threads;
RubyGems reads the umask with `File.umask` for every file it extracts, and
Ruby implements that read as `umask(0)` followed by restoring the old
value, so for an instant the whole process has umask 0. A directory
another thread creates in that instant gets mode 0777, and nothing in the
image build removes the other-write bit afterwards. Which directories are
hit varies from build to build (Vulcan's next release, 2.4.2, has two
different ones), so the fix belongs in the image build, not in any gem.
Changing modes inside `/var/lib/containers/storage` is not a fix: it alters
pulled layers behind podman's back, so the digest no longer describes what
runs.

The login banner is a site setting: SAFBox ships "Welcome to SAFBox!", a
greeting rather than a legal notice, since it cannot know whether a site
monitors the box (`safbox_logon_banner` in
`ansible/group_vars/all/main.yml`). It is not the DoD Notice and Consent
Banner the STIG requires; the STIG banner controls check for SAFBox's text
instead of the DoD notice. A site that needs a notice, a DoD site included,
sets its own text there in `ansible/local.yml`, and the same text for the
STIG overlay's `banner_message_text_cli`, `_ral` and `_gui` inputs in its
site inputs file.

Remote logging is off by default: `safbox_remote_log_server` is empty, the
hardening role switches off the forwarding rule (RHEL-10-200642), and the
overlay marks SV-280985 Not Applicable as a deploy-time deviation. A site
that has a log server sets `safbox_remote_log_server` (and, if needed,
`safbox_remote_log_port` and `safbox_remote_log_protocol`, tcp or udp) in
`ansible/local.yml`, and the overlay input `remote_log_server` to the same
server in its site inputs file. The hardening then writes
`/etc/rsyslog.d/99-forwarding.conf` for that server and SV-280985 is
evaluated.

USBGuard is enabled with no rules, so USB devices are blocked until a site
allows them.

### The firewall zone

`safbox_firewall_zone` in `ansible/group_vars/all/main.yml` is the one
firewalld zone every role opens ports in: the platform role's base services
(group `safbox-platform-3`) and the proxy's HTTPS ports. With hardening on
it is `drop`, because Lockdown's rule RHEL-10-200532 (SV-280957, a
deny-all firewall) moves the network interface into Lockdown's zone and
makes it the default; `rhel10stig_custom_firewall_zone` is set from
`safbox_firewall_zone`, so the two cannot differ. With hardening off
(`safbox_hardening_1: false`) it is the distribution default, `public`.
A site that switches Lockdown's zone rule off (`rhel10stig_200532: false`)
while hardening stays on keeps the interface where it was, so it must also
set `safbox_firewall_zone` to that zone (usually `public`) in
`ansible/local.yml`; otherwise the proxy's ports open in a zone the
interface is not in.

## Tools on the box

The `tools` role installs each tool at the version pinned in
`ansible/group_vars/all/main.yml`; `safbox status` on the box prints them.
To change a pin, update the version there (and, for a downloaded
artifact, its sha256), and
the matching expected-version input default in
`verify/profiles/safbox/inspec.yml`. A site that overrides a pin in `ansible/local.yml` sets
the matching input in its site inputs file, for example
`packer_version: <version>`. CINC Auditor's control compares the version
only, so a different build of the same version (the el9 release on
x86-64-v2 hardware) needs no input. The SAF CLI (from npm) and the
Ansible collections (from Galaxy) are pinned at the root: their versions
are exact, and the package manager resolves their dependencies when the
image is built, so two builds from the same tag can carry different
releases of those dependencies.

FIPS is not a toggle, so every tool must work under FIPS enforcement. After
changing a tool, try it on a FIPS-mode build VM or clone. Known gaps: CINC
Auditor carries its own OpenSSL and Packer uses Go's crypto, neither through
the system FIPS provider.

One known failure: under FIPS enforcement,
`saf convert jfrog_xray2hdf` fails on a JFrog Xray report in which any
finding's `id` is empty. The converter (`@mitre/hdf-converters` 2.14.0,
bundled in SAF CLI 1.7.0) makes such a finding's control ID from an MD5
hash of its summary, and Node.js refuses MD5 in FIPS mode
(`ERR_OSSL_EVP_UNSUPPORTED`). The SAF CLI prints the error, writes no
output file, and still exits 0, so check that the output file exists.
Reports in which every finding has an `id` convert normally. Re-enabling
MD5 for Node.js would take the tool out of FIPS mode, so the box offers
no workaround: convert such a report on a host without FIPS enforcement
until the converter is fixed upstream. Heimdall's upload is not affected:
it converts the report in the browser, not on the box.

## Services on the box

The `services` role runs each application and its PostgreSQL as a podman
pod of Quadlet units (`tasks/heimdall.yml`, `tasks/vulcan.yml`), in the
service shape of the application's upstream `docker-compose.yml` (each unit
file cites the compose service it reproduces), and one nginx container that
terminates TLS for both (`tasks/proxy.yml`). Images are pinned by digest in
`ansible/group_vars/all/main.yml` and pulled at build, so a clone starts
offline.

| Service | Pod publishes (loopback only) | Browser URL |
|---|---|---|
| Heimdall | `127.0.0.1:3000` | `https://<box>:8443/` |
| Vulcan | `127.0.0.1:3001` | `https://<box>:9443/` |

The ports are `safbox_<service>_loopback_port` and
`safbox_<service>_https_port` in group_vars. Port 443 is reserved for the
landing page, nothing listens on 80, and the firewall opens exactly the
HTTPS ports of the services the image ships. Each pod has its own podman
network, so neither database is reachable from the other pod or from the
network.

**First boot.** The units are installed and enabled at build but start only
once their secrets exist (`ConditionPathExists`, ordered after
`safbox-firstboot.service`). First boot runs one hook per service, the only
place its secrets are generated:

- `20-heimdall.sh` writes `/etc/safbox/heimdall.env` (`DATABASE_PASSWORD`,
  `JWT_SECRET`, `API_KEY_SECRET`) and `/etc/safbox/heimdall-db.env`;
- `30-vulcan.sh` writes `/etc/safbox/vulcan.env` (`POSTGRES_PASSWORD`,
  `SECRET_KEY_BASE`, `CIPHER_PASSWORD`, `CIPHER_SALT`) and
  `/etc/safbox/vulcan-db.env`;
- `40-proxy.sh` writes a self-signed certificate for the host name and its
  addresses to `/etc/safbox/tls/safbox.crt` and its RSA 3072 key to
  `safbox.key` (root only).

All of them are root-owned and mode 0600 (the certificate 0644), use the
same random strength as the upstream setup scripts, and never overwrite an
existing value. The seal removes and then asserts the absence of every
`/etc/safbox/*.env` file and of `/etc/safbox/tls`, so the template holds
none.

**Your own certificate.** Replace both files in `/etc/safbox/tls/` with your
certificate (PEM, with any intermediates after it) and unencrypted key,
owned by root, the key mode 0600, then `systemctl restart
safbox-proxy.service`. To regenerate the self-signed one after the host's
name or address changes, delete both files, run
`/etc/safbox/firstboot.d/40-proxy.sh` as root, and restart the proxy.

**Accounts.** Heimdall creates an administrator `admin@heimdall.local` with a
random password on its first start, and prints that password in its log
(`journalctl -u heimdall.service`); change it at first login. Anyone may
register. In Vulcan, local login and registration are on and the first
registered user becomes administrator: register before handing the
appliance out. OIDC, LDAP and SMTP are site settings
(`services_vulcan_settings` in the services role's defaults).

**Footprint.** Measured on a 2 vCPU, 4 GiB development clone with both
applications idle after the service tests: about 750 MB in the containers
(Heimdall 290 MB, Vulcan 280 MB, the databases 75 and 80 MB, nginx 25 MB),
2.5 GiB of the host's memory still available. The container memory limits
(`services_heimdall_memory`, `services_vulcan_memory`, 1g; the databases
512m; nginx 512m) sum to under 4 GiB.

**Applying the roles to a box that has already booted.** The first-boot
runner does nothing once `/var/lib/safbox/firstboot.done` exists, so on
such a box run it over the new hooks with its marker in a scratch
directory, which leaves the box's own marker alone, then start the
services (or reboot):

```
sudo env SAFBOX_STATE_DIR="$(sudo mktemp -d)" /usr/local/sbin/safbox-firstboot
sudo systemctl start heimdall.service vulcan.service safbox-proxy.service
```

**Testing.** The release gate's controls check the units, secrets,
loopback-only ports, TLS on each port and the firewall from a shell on the
box. Two tests act as a browser would, from your workstation over HTTPS
only: they check the proxy's TLS (TLS 1.3 negotiated; TLS 1.0, 1.1 and
ChaCha20 refused), load each application's page with its scripts and
stylesheets, and drive the API. Both create accounts and data, so run them
against a clone:

```
tests/services/heimdall-upload.sh <box>    # register, log in, upload an HDF file
tests/services/vulcan-register.sh <box>    # first user is admin, create a project
```

They need curl, jq and OpenSSL 3 (`OPENSSL=/path/to/openssl` where the
system `openssl` is LibreSSL, as on macOS).

**FIPS.** Each container carries its own userspace crypto. Heimdall, Vulcan
and the proxy are built on Red Hat UBI 9, whose OpenSSL loads its FIPS
provider on a FIPS host (MD5 is refused inside them), and podman gives
them the host's FIPS crypto policy, which the proxy's TLS follows. Their
FIPS module is the RHEL 9 one inside each image, not the host's RHEL 10
module; that is documented here rather than recorded as a finding, because
the containers run a FIPS provider under the host's policy. The proxy uses
`ubi9/nginx-126` rather than upstream Heimdall's `nginx:alpine` for this
reason: Alpine's OpenSSL has no FIPS provider. Each application container
mounts the host's CA trust store read-only, so it trusts the same CAs as the
host, a site's own included (see "Site CA bundles"). Two weaknesses
remain. Both upstream PostgreSQL images (Debian and Alpine) have no OpenSSL
FIPS provider at all, so `safbox-heimdall-5` and `safbox-vulcan-4` fail.
Heimdall hashes passwords and API keys with bcrypt in pure JavaScript,
outside any FIPS provider (upstream
[mitre/heimdall2#4145](https://github.com/mitre/heimdall2/issues/4145),
draft fix [#4850](https://github.com/mitre/heimdall2/pull/4850)).

## Continuous integration

`.github/workflows/static.yml` runs on every push and pull request on
GitHub-hosted runners. It needs no hypervisor and no credentials.

- **secret scan:** gitleaks over the full history with `.gitleaks.toml`,
  which adds rules for Proxmox API token secrets to the defaults, then
  `tests/secrets/gitleaks-rules.sh`, which proves those rules catch a
  generated fake token and pass the repository's placeholders.
- **static checks:** `pre-commit run --all-files`, the `build.sh` tests in
  `tests/scripts/`, `tests/kickstart/ks-lint.sh`, `tests/ansible/lint.sh`
  (yamllint, ansible-lint, the playbook syntax check, shellcheck,
  `tests/packer/validate.sh` and `cinc-auditor check` on both profiles) and
  `tests/platform-discipline.sh`.

Every input is pinned: actions by commit SHA, gitleaks and CINC Auditor by
version and sha256, the SAF CLI by version (the appliance's own pin), the Packer CLI by version (its plugins by
`packer/build.pkr.hcl`), the Python tools in `tests/requirements.txt`, and
the pre-commit hooks by commit SHA. To run the same suite locally, install
`tests/requirements.txt` into a virtual environment, or run the workflow
under [act](https://github.com/nektos/act).

## Inspecting a stuck install

Set `installer_ssh = true` in your local vars for a development build. The
installer then boots with `inst.sshd`, and the kickstart's `sshpw` line lets
the runner SSH into the Anaconda environment as root with the ephemeral build
key while an install is wedged:

```
ssh -i .build/runs/<run id>/build_key root@<installer-ip>
less /tmp/anaconda.log /tmp/storage.log /tmp/packaging.log
```

`<run id>` is the stuck build's run directory, from its first line
(`build log: ...`). `.build/runs/latest` is only that run if no other build
started after it.

The installer's IP is whatever DHCP handed the VM's MAC; the guest agent is
not running yet, so read the MAC from the VM's hardware tab and look it up
in your DHCP leases or ARP table. Nothing from `sshpw` reaches the installed
system. Leave the option off for release builds.

## First boot of a clone takes a while

Proxmox's generated cloud-init user data sets `package_upgrade: true` by
default, so a clone's first boot can run a full `dnf upgrade` before
cloud-init reports done. On a small host that is five minutes or more
between "the guest agent has an address" and "the deploy user can log in",
and on a disconnected network it hangs. The clone test passes `ciupgrade=0`
(qemu-server 8.1 and later) to turn it off; do the same in any deployment
tooling, and expect an appliance to be patched deliberately, not on boot.

## Troubleshooting

- *Console never leaves the firmware splash ("Start boot option"), the VM
  reads about 5 MiB and then one vCPU spins, keystrokes do nothing:* the ISO
  was built for a newer microarchitecture than the host offers. The standard
  `x86_64` ISOs of the RHEL 10 family require x86-64-v3 (AVX2); GRUB itself
  faults silently on an older CPU. Use the `x86_64_v2` AlmaLinux ISO on such
  hosts and check with `/lib64/ld-linux-x86-64.so.2 --help` on the node. Not
  a Secure Boot or CD-ROM bus problem; both were ruled out.
- *Installer stops at the text-mode summary menu even though the kickstart
  was fetched; `/tmp/packaging.log` says "Found no CD-ROM":* the kickstart
  named `cdrom` as the source and the ISO's `.discinfo` architecture line
  does not match what the installer reports. AlmaLinux `x86_64_v2` ISOs say
  `x86_64_v2` there. The shipped kickstart names no source so Anaconda uses
  the boot media's install tree instead; keep it that way.
- *Install finishes but the guest agent appears only after many minutes and
  sshd never listens:* the VM is starved of entropy. A named CPU model such
  as `x86-64-v2-AES` exposes no hardware random number generator, and a FIPS
  system blocks host-key generation and the random seed until the kernel
  generator is seeded. The Packer source attaches a virtio-rng device fed
  from the host's `/dev/urandom` for this reason; make sure any custom source
  or deployment tooling keeps one.
- *Stuck at the GRUB menu:* the `boot_command` assumes the ISO's "Install"
  entry sits one line above the default. Watch the console once; adjust
  `boot_command` in your local vars if the menu differs.
- *Install never fetches the kickstart:* the VM cannot reach the workstation.
  Set `http_interface`, and check that nothing on the workstation firewalls
  Packer's ephemeral HTTP port.
- *SSH times out after install:* the guest agent is not running, so Packer
  never learned the IP. Check `/root/ks-post.log` on the VM console.
