# Base image, disk and build host

## Base image and firmware

- **Base:** Rocky Linux 10 or AlmaLinux 10, the two RHEL 10 family
  distributions SAFBox is built and tested on. The packaged image uses
  Rocky Linux 10, which is simply the one chosen for the download; AlmaLinux
  10 builds from the same kickstart, STIG content and appliance layer, and only
  the ISO changes. Rocky Linux 10 and AlmaLinux 10 (x86_64) need an
  x86-64-v3 host (AVX2); AlmaLinux's x86_64_v2 ISO also builds on older
  CPUs. The build record and `safbox status` show which distribution an
  image came from.
- **Firmware:** UEFI (OVMF, q35) with Secure Boot keys pre-enrolled. RHEL 10
  deprecates legacy BIOS installation.
- **FIPS:** enabled at installation (`fips=1` on the installer command line
  and carried onto the installed bootloader). It cannot be turned on later on
  RHEL 10, and it is never turned off. Use RSA (2048 bits or more) or ECDSA
  SSH keys; sshd refuses Ed25519 under the FIPS policy.
- **Headless by default.** The `environment_group` variable selects the
  kickstart environment. `minimal-environment` installs from the minimal ISO.
  A desktop (`graphical-server-environment`) needs the full DVD ISO or a
  reachable package mirror; the minimal ISO carries no GUI packages.
- **Fallback:** if the RHEL 10 STIG content proves too immature, Rocky Linux 9
  is the fallback, for its mature RHEL 9 STIG content. It is a different
  kickstart version and different content pins, not a flag.

## One image for each supported hypervisor

The template is built and gated on Proxmox. It carries what it needs to
boot and be customised on vSphere as well, so one sealed image can be
exported for both. Exporting it (an OVA) and moving its disk to vSphere's
PVSCSI controller are later steps; until a vSphere host proves them, the
vSphere side is untested. What is in the image for vSphere already:

- **Initramfs with every hypervisor's disk drivers.** The initramfs
  stays host-only, the distribution's default, which carries only the build VM's
  drivers (virtio, `ahci`), so a clone on PVSCSI or NVMe would never
  find its root disk. The kickstart's `%post` writes the dracut drop-in
  `/etc/dracut.conf.d/90-safbox-storage-drivers.conf`, which adds the
  storage drivers `ahci`, `nvme`, `virtio_blk`, `virtio_scsi` and
  `vmw_pvscsi` (`add_drivers`), and rebuilds every installed kernel's
  initramfs; later kernels get them too. Control `safbox-initramfs-1`
  checks the drop-in and every installed kernel's initramfs. Network
  drivers (`vmxnet3`) are loaded from the root filesystem, so they are
  not needed there.
- **Initramfs size.** A generic initramfs (`dracut-config-generic`,
  `hostonly="no"`) would also carry these drivers, but with firmware for
  every driver it includes: the desktop image's was about 245 MB per
  kernel, mostly GPU firmware, and `/boot` (960 MiB) had no room for the
  third kernel dnf keeps (`installonly_limit=3`). The host-only one with
  the added drivers is about 37 MiB per kernel on the headless image and
  53 MiB on the desktop one. With two kernels (each with its kdump
  initramfs) and the rescue image, `/boot` is 37% used on headless and
  41% on desktop, with room for several more kernels. The rescue
  initramfs (about 78 MiB) stays generic, as `dracut-config-rescue` makes
  it, and there is only one.
- **Both guest agents.** `%post` installs and enables `qemu-guest-agent`
  (Proxmox) and `open-vm-tools` (vSphere; cloud-init's VMware datasource
  needs it to read guestinfo). Each starts only on its own hypervisor:
  `qemu-guest-agent` is bound to its virtio port, `vmtoolsd` has
  `ConditionVirtualization=vmware`, so on Proxmox it stays inactive
  without failing.
- **open-vm-tools hardened.** `%post` writes `/etc/vmware-tools/tools.conf`
  with `[guestoperations] disabled = true`, so a vCenter user with guest
  credentials cannot run programs or move files in the guest (the
  exposure `qemu-guest-agent`'s `guest-exec` and `guest-file-*` would
  open, which its distribution allow list leaves out), and `[deployPkg]
  enable-custom-scripts = false`, so a customization spec's script never
  runs as root. The file is not the package's, so `rpm -V open-vm-tools`
  still checks the package as shipped.
- **cloud-init datasources.** `datasource_list: [ NoCloud, ConfigDrive,
  VMware, None ]` (Packer variable `datasource_list`; the answer file
  adds `None`). ds-identify enables only those whose source it finds:
  Proxmox's cloud-init drive or a NoCloud seed ISO, a config drive, or
  vSphere guestinfo. The first-boot play reads cloud-init's merged
  configuration, so it runs the same whichever datasource supplied it.
- **The gates check the agent for the detected hypervisor.** The
  answer file's `packer/answerfiles/el10/guest-agents.yml` describes each
  agent, keyed by the hypervisor `systemd-detect-virt` names, and
  `scripts/validate.sh` passes it to every scan (input `guest_agents`).
  `safbox-system-1` expects the detected hypervisor's agent to run and
  every agent to be installed and enabled; `safbox-guest-agent-1` checks
  each agent's package with `rpm -V` and its hardening: the running
  `qemu-guest-agent`'s allow list, and `tools.conf`'s settings on every
  hypervisor, since the image moves between them.
- **The build record** (`SAFBOX_UNPINNED_PACKAGES`) names the exact
  build of `cloud-init` and both agents, which
  the kickstart installs without a version pin.

## Partition layout

The kickstart creates separate filesystems for `/home`, `/tmp`, `/var`,
`/var/tmp`, `/var/log`, and `/var/log/audit`, as the RHEL STIG requires, plus
`/boot`, `/boot/efi`, and swap. All but the two boot partitions are logical
volumes in the volume group `vg_safbox`, which fills the rest of the disk.

| Fixed size | |
|---|---|
| `/boot/efi` | 600 MiB |
| `/boot` | 1 GiB |
| `/` | 12 GiB |
| `/tmp`, `/var/tmp`, swap | 2 GiB each |

That is about 20 GiB. The rest of the volume group is shared:

| Share | Holds | On the minimum 60G disk | On a 100G disk |
|---|---|---|---|
| `/home` 40% | automation content, rootless container storage | about 16 GiB | about 32 GiB |
| `/var` 40% | container images | about 16 GiB | about 32 GiB |
| `/var/log` 10% | | about 4 GiB | about 8 GiB |
| `/var/log/audit` 10% | | about 4 GiB | about 8 GiB |

Give the disk at least 60G.

**Giving a clone more disk.** Enlarge the clone's disk in the hypervisor
before its first boot. The first-boot play's first role, `clone_grow_disk`
(tag `grow_disk`, which runs a shell script), grows the partition to
the end of the disk and the physical volume to the partition, then hands
the volume group's free space to `/home`, `/var`, `/var/log` and
`/var/log/audit` by the same 40/40/10/10 shares, growing each XFS
filesystem online. It logs each step to the journal (`journalctl -u
safbox-firstboot`). On a disk of the template's size there is nothing to
grow and it changes nothing. To give a box that has already booted more
space, enlarge its disk and run the role again as root
([Appliance](appliance.md#first-boot), "Running it again"):

```
sudo env ANSIBLE_CONFIG=/usr/local/lib/safbox/firstboot/ansible.cfg \
  ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags grow_disk
```

It only ever adds the space not yet in use, so running it twice is
harmless. Nothing shrinks: XFS cannot,
so for a smaller disk build a template with a smaller `vm_disk_size`.

## Build host

A Proxmox node with an x86-64-v3 CPU (AVX2, roughly 2013 or newer), room for
a 4 vCPU, 8 GiB, 60 GiB VM, and the DVD or minimal ISO on its ISO storage.
Timeouts and waits are variables; raise them on a slow host before
suspecting the pipeline.

Older x86-64-v2 hardware can build from the AlmaLinux `x86_64_v2` ISO with a
few site overrides (CPU model, and third-party packages built for v3); see
[Site overrides](../guides/proxmox/build.md#site-overrides).
