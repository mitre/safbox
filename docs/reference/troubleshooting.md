# Troubleshooting

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
between "the guest agent has an address" and "admin can log in",
and on a disconnected network it hangs. The clone test passes `ciupgrade=0`
(qemu-server 8.1 and later) to turn it off; do the same in any deployment
tooling, and expect an appliance to be patched deliberately, not on boot.

## Common problems

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
