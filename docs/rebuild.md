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
  VM from here, and the clone test uses them as the release gate. The
  static suite needs the SAF CLI too (`tests/verify/thresholds.sh`)
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

Each run writes a timestamped log under `.build/logs/`, and `last.log` in the
repository root points at the newest one, so `tail -F last.log` follows the
current build (and the next one, without restarting `tail`).

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

1. **During the build**, before the seal, `scripts/validate.sh` runs the
   `verify/inspec-safbox` profile from your workstation against the build
   VM over SSH with the inputs in `verify/inputs/build.yml`, and
   `saf validate threshold` against `verify/thresholds/build.yml` decides
   whether the build continues. Nothing is installed on the image for
   this. Results land in `.build/validate-build-<timestamp>.json`, readable
   in Heimdall.
2. **At the end of the seal**, the seal's own final script asserts that the
   build user, its sudo rule, host keys, machine identity, cloud-init
   instance state, installer residue, first-boot secrets, and build-VM
   network profiles are all gone. Nothing outside can log in afterwards, so
   the seal checks itself; any miss fails the build.
3. **Before publishing an image** (the release gate), a clone is booted and
   the same profile runs against it from outside as the deploy user, with
   `verify/inputs/release.yml` and `verify/thresholds/release.yml`, which
   also proves what only a first boot does: fresh host keys and machine
   identity, the consumer's cloud-init user, first boot running once.

### The profiles

`verify/inspec-safbox` is a wrapper: it holds no controls of its own and
includes every child profile whole.

| Profile | Holds | Runs on |
|---|---|---|
| `verify/el10-infrastructure` | the SAFBox infrastructure controls (`safbox-*`), impact 1.0 except documented findings (low, tagged `finding`) | redhat family, release 10.* |
| `verify/safbox-rhel10-stig-overlay` | the pinned MITRE RHEL 10 STIG baseline with SAFBox's deviations marked | redhat family, release 10.* (the baseline's) |

Each child declares the platforms it supports, and CINC Auditor skips a
child that does not match the target, so one scan of the wrapper is right
for any image. A later OS family adds its own children (an infrastructure
profile and a STIG overlay for that OS) to the wrapper's `depends` and
`controls/children.rb`. Each child also runs alone, for example while
developing a control:

```
scripts/validate.sh <user@host> <key> infra-only verify/el10-infrastructure \
  verify/thresholds/build.yml verify/inputs/build.yml
```

(the threshold then fails on the missing STIG results, but the results
file is written first). The wrapper fetches the overlay's pinned baseline
from GitHub on each scan, so the workstation needs network access.

### `scripts/validate.sh`

```
scripts/validate.sh [--site-inputs FILE] [--site-threshold FILE] [--ssh-config FILE] \
  <user@host[:port]> <private-key> <label> <profile> <threshold> <inputs-file>
```

The inputs file goes to CINC Auditor with `--input-file`; every child
reads the inputs it declares from it. Inputs never go on the command line,
so a result is reproducible from tracked files plus the site files named.
`--site-inputs` is layered after the tracked inputs file (its values win);
`--site-threshold` replaces the tracked threshold.

`--ssh-config` names the SSH client config CINC Auditor reads instead of
its defaults, `~/.ssh/config` and `/etc/ssh/ssh_config` (with the files
that one includes); `/dev/null` reads none. Leave it unset unless you need
it: the defaults are what carry a `ProxyJump` or bastion you use to reach
the build network. Use it when the runner's default config cannot be read
or used: CINC Auditor's SSH library, unlike OpenSSH, stops with
`Permission denied @ rb_sysopen - /etc/ssh/ssh_config` on a default file it
cannot open, as inside a sandboxed agent session. The build gate takes it
from the Packer variable `build_gate_ssh_config_file`, the release gate
from `SAFBOX_SSH_CONFIG` for `scripts/clone-and-ssh.sh`.

### The thresholds

Every infrastructure control is impact 1.0, the SAF CLI's critical
severity, and no STIG control is (a CAT I finding is 0.7, high). Each
threshold therefore lists, under `passed.critical.controls`, exactly the
infrastructure controls a repository-default image passes in that context,
and holds `failed.critical.max: 0` and `error.total.max: 0`. The list is an
exact set: a control that fails, is skipped, is missing, or passes without
being listed fails the gate.

- **build** (the build VM before the seal): every control except those
  that need a sealed, deployed clone (`safbox-build-info-1`,
  `safbox-seal-1`, `safbox-seal-2`, `safbox-firstboot-2`, and the
  running-service controls `safbox-heimdall-3`, `safbox-vulcan-3`,
  `safbox-proxy-2`, `-3` and `-6`). The service units and their absent
  secrets are checked here (`safbox-heimdall-1` and `-2`, `safbox-vulcan-1`
  and `-2`, `safbox-proxy-1`, `-4` and `-5`).
- **release** (a deployed clone of a full-sealed template): those as well.
- `safbox-podman-2` (the smoke-test Quadlet unit) is in neither: it skips
  unless the build opts in with `safbox_example_quadlet_enabled=true`.

**Documented findings.** A known weakness SAFBox ships with is recorded as
an infrastructure control of low impact (0.1 to 0.39) with a `finding` tag,
which fails on every image it applies to; it is never waived or skipped.
Being low, it is not in the critical bucket: it sits in
`failed.low.controls` with the STIG controls, where
`scripts/lock-stig-threshold.sh` puts it, and `tests/verify/thresholds.sh`
requires it there in each context where it applies. The current findings
are crypto inside the service containers that does not go through a FIPS
provider (see "Services on the box").

STIG controls are held at their documented state until Phase 7 hardens
the image: for each of high, medium and low, `passed.<sev>.controls` and
`failed.<sev>.controls` list exactly which STIG controls pass and which
fail in that context. Any control that changes status fails the gate,
whether it got better or worse. To change the documented state on
purpose, scan, then regenerate the lists and review the diff:

```
scripts/lock-stig-threshold.sh <build|release> .build/validate-<label>-<timestamp>.json
```

The script keeps the infrastructure clauses and records the results file
it used in the threshold's comments. Known weaknesses stay visible as
findings: no baseline control is ever skipped to pass a threshold, and the
critical and error clauses are never loosened.

`tests/verify/thresholds.sh` (part of `tests/ansible/lint.sh`) fails when a
threshold's critical list differs from the controls whose `only_if`
conditions hold for that context's inputs, so adding or re-gating a control
means updating the thresholds in the same change.

Limits of the scheme: the SAF CLI counts controls, not tests within them,
so a control passes or fails as a whole. The STIG lists cover passing and
failing controls only, so a control moving between skipped and Not
Applicable goes unnoticed. The critical list depends
on the inputs and on build options; a site that changes either must supply
its own threshold.

### Site inputs and thresholds

A site that builds a different image than the repository default (a tools
group switched off, a pin overridden, a platform without a guest-agent
channel) names two files of its own. Keep them in `verify/local/`, which
is git-ignored, and never commit them:

- an inputs file layered after the tracked one, for example
  `verify/local/build-inputs.yml`:

  ```
  ---
  expected_tools: [cinc-auditor, saf-cli, ansible]
  ```

- a threshold that replaces the tracked one, for example
  `verify/local/build-threshold.yml`: a copy of
  `verify/thresholds/build.yml` with the controls that no longer apply
  (here `safbox-tools-4`) removed from `passed.critical.controls`. A
  switched-off tools group drops only its own control; the STIG lists
  stay as they are unless the change moves a STIG control, in which case
  scan and regenerate them in your copy.

Name them to the build in `packer/local.auto.pkrvars.hcl`:

```
build_gate_site_inputs_file    = "verify/local/build-inputs.yml"
build_gate_site_threshold_file = "verify/local/build-threshold.yml"
```

and to the release gate with `SAFBOX_SITE_INPUTS` and
`SAFBOX_SITE_THRESHOLD` (release-context copies,
`verify/local/release-inputs.yml` and `verify/local/release-threshold.yml`).
Relative paths in the Packer variables resolve against the repository root
(`scripts/build.sh` runs from there); the `SAFBOX_SITE_*` paths resolve
against the directory you run `scripts/clone-and-ssh.sh` from, so give
absolute paths or run it from the repository root. The same holds for
`build_gate_ssh_config_file` and `SAFBOX_SSH_CONFIG`, which name the SSH
client config both gates read (see `scripts/validate.sh` below); unlike
the site files they describe the runner, not the image, so they usually
stay unset.

### On-box exercise profiles

Every test that talks to the box is an InSpec profile, so its results are
HDF: viewable in Heimdall and gated by a SAF CLI threshold. Two profiles
exercise the box rather than inspect it, so they are not in the
`verify/inspec-safbox` wrapper and run alone, each with its own threshold
and inputs file:

| Profile | Exercises | Why it runs alone |
|---|---|---|
| `verify/el10-fips-exercise` | each tool doing TLS or hashing under FIPS enforcement (see "Tools on the box") | needs outbound HTTPS from the box |
| `verify/el10-firstboot` | the first-boot runner and secrets library | writes files on the box |

```
scripts/validate.sh <user@host> <key> firstboot verify/el10-firstboot \
  verify/thresholds/firstboot.yml verify/inputs/firstboot.yml
```

Run them against a build VM or clone the playbook was applied to, after
changing a tool or the `base` role. Each control works in its own scratch
directory under `/root` and removes it, then asserts it is gone, so the
target is left as found. The first-boot controls call the runner directly
with every path pointed into that directory, never `/etc/safbox` or
`/var/lib/safbox`. `tests/verify/onbox.sh` (part of `tests/ansible/lint.sh`)
checks both profiles statically and runs the FIPS threshold against a
recorded result.

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

Every task group in the `platform`, `base`, `tools`, `heimdall`, `vulcan`
and `proxy` roles is a block
tagged `safbox-<role>-<n>` with a switch `safbox_<role>_<n>` (default on),
in the style of Ansible Lockdown. The switches and a one-line description of
each group are listed in `ansible/group_vars/all/main.yml`.

- Turn a group off for every build by setting its switch to `false` in
  `ansible/local.yml` (site overrides, git-ignored).
- Run or skip groups for one invocation with `--tags` / `--skip-tags`, for
  example against an existing host:
  `ansible-playbook -i <host>, -u <user> ansible/playbooks/safbox.yml -e @ansible/local.yml --tags safbox-platform-3`
- The `seal` role's groups are tagged (`safbox-seal-<n>`) but have no
  switch: a partially sealed image carries build identity, so the seal runs
  whole. The one exception is the development seal (`seal = false`), which
  stops before the final group and marks the template `unsealed`.
- Each `tools` group (CINC Auditor, SAF CLI, Ansible with the Lockdown
  collections, Packer) has a validation control `safbox-tools-<n>`. The
  profile's `expected_tools` input lists the tools the image ships (default
  `cinc-auditor`, `saf-cli`, `ansible`, `packer`); a tool expected but
  missing fails its control. When you switch a tools group off, drop its
  tool from that input in a site inputs file and its control from the
  threshold in a site threshold file, and name both to the build and the
  release gate (see "Site inputs and thresholds" above). For the FIPS
  exercise (see "Tools on the box"), use the same site inputs file and a
  copy of `verify/thresholds/fips-exercise.yml` without the tool's two
  controls. A distributor who does not
  want to ship Packer's Business Source License sets `safbox_tools_4:
  false`; see `docs/third-party.md`.
- Each service is its own role with one group: `safbox_heimdall_1`,
  `safbox_vulcan_1`, `safbox_proxy_1`. A host short of memory runs Heimdall
  alone with `safbox_vulcan_1: false`; the proxy then serves Heimdall only
  and closes Vulcan's port. The profile's `expected_services` input lists
  the services the image ships (default `heimdall`, `vulcan`, `proxy`):
  drop a switched-off service there in a site inputs file, and its
  controls (`safbox-vulcan-*`, and `safbox-proxy-3` for Vulcan's proxy
  port) from a site threshold, as for a tools group.

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
installed. What SAFBox does not apply is listed in
[docs/deviations.md](deviations.md), generated from two files in
`ansible/roles/hardening/vars/`:

- `deviations.yml`: requirements deliberately not applied, each with a
  reason code (`usability`, `content-defect` with its upstream issue,
  `deploy-time`) and a justification. The hardening role switches each off
  through the Lockdown role's per-rule variable (`rhel10stig_<digits of the
  RHEL-10 ID>`), and the STIG overlay marks each Not Applicable with the same
  justification. Every new entry is an owner decision.
- `not_applied.yml`: rules switched off only because their Lockdown task
  errors on SAFBox. They are not deviations: the overlay leaves them alone,
  the baseline control still runs, and the locked STIG lists record its
  result as it is (each entry notes whether that is a pass, a fail or a
  skip, and why).

`scripts/deviations-check.sh` fails if the deviations and the overlay's Not
Applicable overrides differ, or if `docs/deviations.md` is stale; it runs in
`tests/ansible/lint.sh` and as the first step of every build. After changing
either file, or relocking a threshold, run `scripts/deviations-doc.sh` to
regenerate the guide: it also lists every STIG control that still fails on a
deployed clone (from `verify/thresholds/release.yml`), with its title and
whether it is a known baseline defect
(`verify/safbox-rhel10-stig-overlay/known-defects.yml`), a rule whose task
failed, or not yet triaged. The titles come from
`verify/safbox-rhel10-stig-overlay/baseline-titles.yml`, generated from the
pinned baseline by `scripts/baseline-titles.sh` (network needed) so the
guide is built offline; rerun it whenever the overlay's baseline ref
changes (`tests/verify/overlay.sh` fails while it is stale).

Lockdown's own variables are the knobs for everything else: set any
`rhel10stig_*` value in `ansible/local.yml` (a rule switch to `false`, a
banner text, a time server). A site that changes what is applied supplies
its own threshold (see "Site inputs and thresholds"); switching the whole
group off (`safbox_hardening_1: false`) also needs `hardening_expected:
false` in the site inputs. Hardening does not reboot the build VM, because
a reboot would run the first-boot unit inside the template; kernel
arguments and some other settings take effect when a clone first boots, so
the build threshold's STIG lists differ from the release threshold's.

Known upstream defect: the pinned Lockdown release ends every run with
`POST | Warning a reboot required but skip option set`, a task marked
`changed_when: true`, so a second playbook run reports `changed=1`.
`tests/ansible/idempotence.sh` tolerates exactly that task, matched by its
name; any other change fails the check. The tolerance goes when a fixed
Lockdown release is pinned.

The login banner is a site setting: SAFBox ships a short placeholder
(`safbox_logon_banner` in `ansible/group_vars/all/main.yml`). A site sets
its own text there in `ansible/local.yml`, and the same text for the STIG
overlay's `banner_message_text_cli`, `_ral` and `_gui` inputs in its site
inputs file.

Remote logging is off by default: `safbox_remote_log_server` is empty, the
hardening role switches off the forwarding rule (RHEL-10-200642), and the
overlay marks SV-280985 Not Applicable as a deploy-time deviation. A site
that has a log server sets `safbox_remote_log_server` (and, if needed,
`safbox_remote_log_port` and `safbox_remote_log_protocol`, tcp or udp) in
`ansible/local.yml`, and the overlay input `remote_log_server` to the same
server in its site inputs file. The hardening then writes
`/etc/rsyslog.d/99-forwarding.conf` for that server, SV-280985 is evaluated,
and the site supplies a threshold that expects it.

USBGuard is enabled with no rules, so USB devices are blocked
until a site allows them; see [docs/deviations.md](deviations.md).

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
interface is not in. `tests/ansible/structure.sh` fails if Lockdown's zone
or any role's firewalld task stops using `safbox_firewall_zone`.

## Tools on the box

The `tools` role installs each tool at the version pinned in
`ansible/group_vars/all/main.yml`; `safbox status` on the box prints them.
To change a pin, update the version there (and, for a downloaded
artifact, its sha256), and
the matching expected-version input default in
`verify/el10-infrastructure/inspec.yml` (`tests/ansible/pins.sh` fails
while they differ). A site that overrides a pin in `ansible/local.yml` sets
the matching input in its site inputs file, for example
`packer_version: <version>`. CINC Auditor's control compares the version
only, so a different build of the same version (the el9 release on
x86-64-v2 hardware) needs no input. The SAF CLI (from npm) and the
Ansible collections (from Galaxy) are pinned at the root: their versions
are exact, and the package manager resolves their dependencies when the
image is built, so two builds from the same tag can carry different
releases of those dependencies.

FIPS is not a toggle, so every tool must work under FIPS enforcement. After
changing a tool, run the FIPS exercise profile against a FIPS-mode build VM
or clone (see "On-box exercise profiles" above):

```
scripts/validate.sh <user@host> <key> fips-exercise verify/el10-fips-exercise \
  verify/thresholds/fips-exercise.yml verify/inputs/fips-exercise.yml
```

For each tool, `safbox-fips-exercise-<n>` (impact 1.0) runs it once doing
TLS or SHA-256 hashing, and `safbox-fips-provider-<n>` (low) checks that
its cryptography goes through the system OpenSSL FIPS provider. Every
control first asserts FIPS enforcement (`fips_enabled=1`, the FIPS crypto
policy, the OpenSSL FIPS provider active), so a host without it fails.
Two provider controls fail by design, each a known finding tagged with its
issue: CINC Auditor's embedded OpenSSL and Packer's Go crypto. The
threshold names exactly those two, so a new finding, a fixed one, or a
tool that stops working fails it. A failing exercise is a tool that
cannot ship on a FIPS image as it stands. The box needs outbound HTTPS to
`fips_exercise_url` (`verify/inputs/fips-exercise.yml`); on a restricted
network, name a reachable endpoint in a site inputs file.

One known failure is outside the exercise: under FIPS enforcement,
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

The `heimdall` and `vulcan` roles run each application and its PostgreSQL
as a podman pod of Quadlet units, in the service shape of the
application's upstream `docker-compose.yml` (each unit file cites the
compose service it reproduces). The `proxy` role runs one nginx container
that terminates TLS for both. Images are pinned by digest in
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
(`vulcan_settings` in the vulcan role's defaults).

**Footprint.** Measured on a 2 vCPU, 4 GiB development clone with both
applications idle after the service tests: about 750 MB in the containers
(Heimdall 290 MB, Vulcan 280 MB, the databases 75 and 80 MB, nginx 25 MB),
2.5 GiB of the host's memory still available. The container memory limits
(`heimdall_memory`, `vulcan_memory`, 1g; the databases 512m; nginx 512m)
sum to under 4 GiB.

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
reason: Alpine's OpenSSL has no FIPS provider. Three
weaknesses remain and are recorded as findings (`safbox-heimdall-4`,
`safbox-heimdall-5`, `safbox-vulcan-4`): Heimdall hashes passwords and API
keys with bcrypt in pure JavaScript, outside any FIPS provider (the finding
counts both, though a fresh box has no API key until a user creates one;
upstream [mitre/heimdall2#4145](https://github.com/mitre/heimdall2/issues/4145),
draft fix [#4850](https://github.com/mitre/heimdall2/pull/4850)), and both
upstream PostgreSQL images (Debian and Alpine) have no OpenSSL FIPS
provider at all.

## Continuous integration

`.github/workflows/static.yml` runs on every push and pull request on
GitHub-hosted runners. It needs no hypervisor and no credentials.

- **secret scan:** gitleaks over the full history with `.gitleaks.toml`,
  which adds rules for Proxmox API token secrets to the defaults, then
  `tests/secrets/gitleaks-rules.sh`, which proves those rules catch a
  generated fake token and pass the repository's placeholders.
- **static checks:** `pre-commit run --all-files`, `tests/packer/validate.sh`,
  `tests/kickstart/ks-lint.sh`, `tests/ansible/lint.sh` (including the
  validation profile checks, which need CINC Auditor, and the threshold
  checks, which need the SAF CLI) and
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
ssh -i .build/build_key root@<installer-ip>
less /tmp/anaconda.log /tmp/storage.log /tmp/packaging.log
```

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
