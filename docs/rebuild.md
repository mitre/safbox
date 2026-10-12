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
- Ansible on the workstation (`pipx install ansible`); the build runs the
  appliance playbooks from here against the build VM, and installs the
  pinned collections from `ansible/requirements.yml` itself
- CINC Auditor and the SAF CLI on the workstation; the build validates the
  VM from here, and the clone test uses them as the release gate
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
`unsealed`.

## How a build is validated

Three checks, at three moments:

1. **During the build**, before the seal, `scripts/validate.sh` runs the
   `verify/inspec-safbox` profile from your workstation against the build
   VM over SSH, and `saf validate threshold` against `verify/threshold.yml`
   decides whether the build continues. Nothing is installed on the image for
   this. Results land in `.build/validate-build-<timestamp>.json`, readable
   in Heimdall.
2. **At the end of the seal**, the seal's own final script asserts that the
   build user, its sudo rule, host keys, machine identity, cloud-init
   instance state, installer residue, first-boot secrets, and build-VM
   network profiles are all gone. Nothing outside can log in afterwards, so
   the seal checks itself; any miss fails the build.
3. **Before publishing an image** (the release gate), a clone is booted and
   the same profile runs against it from outside as the deploy user, which
   also proves what only a first boot does: fresh host keys and machine
   identity, the consumer's cloud-init user, first boot running once.

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

Every task group in the `platform`, `base`, and `tools` roles is a block
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

## Continuous integration

`.github/workflows/static.yml` runs on every push and pull request on
GitHub-hosted runners. It needs no hypervisor and no credentials.

- **secret scan:** gitleaks over the full history with `.gitleaks.toml`,
  which adds rules for Proxmox API token secrets to the defaults, then
  `tests/secrets/gitleaks-rules.sh`, which proves those rules catch a
  generated fake token and pass the repository's placeholders.
- **static checks:** `pre-commit run --all-files`, `tests/packer/validate.sh`,
  `tests/kickstart/ks-lint.sh`, `tests/ansible/lint.sh` (including the
  validation profile check, which needs CINC Auditor) and
  `tests/platform-discipline.sh`.

Every input is pinned: actions by commit SHA, gitleaks and CINC Auditor by
version and sha256, the Packer CLI by version (its plugins by
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
