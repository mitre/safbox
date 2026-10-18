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
before its first boot. First boot runs the hook
`/etc/safbox/firstboot.d/10-grow-disk.sh` before any other: it grows the
partition to the end of the disk and the physical volume to the partition,
then hands the volume group's free space to `/home`, `/var`, `/var/log` and
`/var/log/audit` by the same 40/40/10/10 shares, growing each XFS filesystem
online. It logs each step to the journal (`journalctl -t
safbox-firstboot`). On a disk of the template's size there is nothing to
grow and it changes nothing. To give a box that has already booted more
space, enlarge its disk and run the hook again as root (`sudo
/etc/safbox/firstboot.d/10-grow-disk.sh`); it only ever adds the space not
yet in use, so running it twice is harmless. Nothing shrinks: XFS cannot,
so for a smaller disk build a template with a smaller `vm_disk_size`.

## Build host

A Proxmox node with an x86-64-v3 CPU (AVX2, roughly 2013 or newer), room for
a 4 vCPU, 8 GiB, 60 GiB VM, and the DVD or minimal ISO on its ISO storage.
Timeouts and waits are variables; raise them on a slow host before
suspecting the pipeline.

Older x86-64-v2 hardware can build from the AlmaLinux `x86_64_v2` ISO with a
few site overrides (CPU model, and third-party packages built for v3); see
[Site overrides](../guides/proxmox/build.md#site-overrides).
