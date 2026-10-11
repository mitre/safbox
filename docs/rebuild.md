# Rebuilding SAFBox

This guide covers producing the SAFBox template yourself. It assumes a
Proxmox VE 8 or 9 cluster and a workstation with Packer.

## Base image and firmware

- **Release base:** Rocky Linux 10. Requires an x86-64-v3 capable host (AVX2).
- **Development base:** AlmaLinux 10 x86_64_v2, for build hosts whose CPUs
  predate AVX2. Same kickstart, same STIG content, same appliance layer; only
  the ISO changes. Images built from it are development artifacts, and the
  self-test records which distribution an image came from.
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

## Minimum build host

The install layer has been exercised on very small hardware, and several
defaults (boot wait, key interval, install timeout) are tuned for it. Treat
the following as the floor for a build host, not a recommendation:

| Resource | Development build | Release build |
|---|---|---|
| CPU microarchitecture | x86-64-v2 (AlmaLinux 10 v2 ISO) | x86-64-v3 with AVX2 (Rocky 10) |
| vCPUs for the build VM | 2 | 4 |
| RAM for the build VM | 4 GiB | 8 GiB |
| Free thin-pool space | 40 GiB plus EFI vars | 60 GiB plus EFI vars |
| Host RAM headroom beyond the VM | 1 GiB | 2 GiB |
| ISO storage | 2 GiB (minimal ISO) | 12 GiB (DVD ISO) |

On a low-end host, expect UEFI firmware with Secure Boot to take 20 seconds
or more to reach GRUB, the package install to take 15 to 30 minutes, and the
`%post` download of the guest agent and cloud-init to depend on the host's
internet speed. Timeouts and waits are variables; raise them before
suspecting the pipeline.

## Hypervisor prerequisites

What the human has to set up on the hypervisor before a build can run is
target-specific. For Proxmox, follow [docs/guides/proxmox/build.md](guides/proxmox/build.md):
ISO upload, the least-privilege API token, pool and ACLs, and the variables
file. Other targets get their own guide alongside their Packer source.

## Workstation prerequisites

- Packer 1.12 or newer; plugins are pinned and installed by `packer init`
- `pipx install pykickstart` for the kickstart lint
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

The build types a short GRUB edit at the ISO menu, serves the kickstart,
waits through the install and reboot, confirms FIPS and the guest agent over
SSH, resets cloud-init, and converts the VM to a template.

## Prove the template

```
SAFBOX_NODE=<node> SAFBOX_POOL=<pool> scripts/clone-and-ssh.sh <template-vmid> <clone-vmid>
```

Clones the template through the API into the pool, injects a cloud-init
user and an RSA key, boots it, learns the IP from the guest agent, logs in
as that user, and asserts FIPS mode is on and cloud-init applied the clone's
hostname. Set `SAFBOX_CA_FILE` to the cluster CA, or `SAFBOX_INSECURE_TLS=1`
for a throwaway lab. Pass `--keep` as a third argument to leave the clone
running. A Phase 1 template is unsealed and not distributable; see the
Proxmox guide.

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
