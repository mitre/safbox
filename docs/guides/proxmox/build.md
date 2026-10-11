# Building SAFBox on Proxmox VE

This is the operator's checklist for one Proxmox target: what you do by hand
once, which variable each choice lands in, and the smallest set of
permissions the build account needs. The generic build procedure lives in
[docs/rebuild.md](../../rebuild.md); read that for the base image, partition
layout, and troubleshooting.

Everything below runs as root on a Proxmox node unless stated otherwise.
Replace the angle-bracket placeholders with your own names; none of the
values here are committed to git.

## 1. Pick the node and check its CPU

The release base, Rocky Linux 10, needs an x86-64-v3 CPU (AVX2). AlmaLinux
10 ships an `x86_64_v2` build for older hardware. Check the node:

```
/lib64/ld-linux-x86-64.so.2 --help | grep -A4 'Subdirectories of glibc-hwcaps'
```

`x86-64-v3 (supported, searched)` means Rocky 10 will boot. If only
`x86-64-v2` is supported, use the AlmaLinux `x86_64_v2` ISO for development
builds; a Rocky 10 VM will not boot on that node.

| Fact | Variable |
|---|---|
| Node name | `proxmox_node` |

## 2. Upload the ISO

Two network prerequisites on the bridge the VM will use: a DHCP server
(the kickstart and the clone test both use DHCP), and outbound HTTPS to the
distribution's mirrors, because the minimal ISO lacks the guest agent and
cloud-init and the install fetches them. Without egress the install fails
early and visibly (`%post --erroronfail`) rather than leaving a silent
template.

The build account cannot upload files by design, so you do it. Either:

- GUI: select the node, then its ISO storage (usually `local`), then
  **ISO Images**, then **Upload** or **Download from URL**.
- Shell on the node: copy the file into the storage's ISO directory, for
  `local` that is `/var/lib/vz/template/iso/`.

Verify the checksum against the distribution's `CHECKSUM` file, then record
the ISO by its storage volume id:

| Fact | Variable | Example value |
|---|---|---|
| ISO volume id | `iso_file` | `local:iso/AlmaLinux-10.2-x86_64_v2-minimal.iso` |
| Checksum | `iso_checksum` | `sha256:<hex from CHECKSUM>` |

The minimal ISO installs a headless system from the media alone. A desktop
build needs the DVD ISO or a reachable package mirror.

## 3. Create the sandbox

A resource pool is the boundary everything else hangs off. The build account
will see and touch only what is in it.

```
pveum pool add <pool> --comment "SAFBox builds"
```

| Fact | Variable |
|---|---|
| Pool name | `proxmox_pool` |

## 4. Create the least-privilege role

Two roles: one for building, one read-only for the ISO storage. These are
the privileges the Packer Proxmox plugin and the clone test use, and nothing
else. Notably absent: `Datastore.AllocateTemplate` (no ISO or template
upload), `Pool.Allocate` (creating a VM into a pool is authorized by
`VM.Allocate` on the pool, so the account never needs to modify or delete
the pool itself), `Sys.Modify` (no node changes), and anything on `/`.

```
pveum role add SAFBoxBuilder -privs "VM.Allocate VM.Clone VM.Audit VM.Console VM.PowerMgmt \
  VM.Config.CDROM VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network \
  VM.Config.Options VM.Config.Cloudinit VM.Config.HWType VM.GuestAgent.Audit \
  Datastore.Audit Datastore.AllocateSpace Pool.Audit SDN.Use Sys.Audit"
pveum role add SAFBoxISOReader -privs "Datastore.Audit"
```

On Proxmox 8, `VM.GuestAgent.Audit` does not exist; use `VM.Monitor` in its
place. `Sys.Audit` on the node is required by the plugin for node and bridge
lookups; be aware it also lets the account list that node's tasks and read
its network configuration.

## 5. Create the build user and an API token

```
pveum user add <user>@pve --comment "SAFBox build runner"
pveum user token add <user>@pve <token-name> --privsep 0
```

A Proxmox API token is two values. Its **ID** is `<user>@pve!<token-name>`,
which identifies which of the user's tokens is being used and is not
sensitive. Its **secret** is the UUID printed once by the command above.
The API wants both, as `PVEAPIToken=<id>=<secret>`, and the Packer plugin
takes them as separate fields. `--privsep 0` means the token carries the
user's permissions, so the ACLs below are granted to the user.

Put the three values in a file only you can read, by default
`~/.config/proxmox/packer.env`, which `scripts/build.sh` sources:

```
PROXMOX_URL=https://<node-address>:8006/api2/json
PROXMOX_USERNAME=<user>@pve!<token-name>
PROXMOX_TOKEN=<token-secret>
```

```
chmod 600 ~/.config/proxmox/packer.env
```

It is best practice to never put these in a Packer variables file, and to avoid putting them anywhere you might accidentally commit them to history.

## 6. Grant the ACLs

One grant per thing the build touches. Creation rights come from the pool:
every create and clone request names it, and Proxmox authorizes the request
through `VM.Allocate` on the pool path.

```
pveum acl modify /pool/<pool>                     -user <user>@pve -role SAFBoxBuilder
pveum acl modify /storage/<disk-storage>          -user <user>@pve -role SAFBoxBuilder
pveum acl modify /storage/<iso-storage>           -user <user>@pve -role SAFBoxISOReader
pveum acl modify /sdn/zones/localnetwork/<bridge> -user <user>@pve -role SAFBoxBuilder
pveum acl modify /nodes/<node>                    -user <user>@pve -role SAFBoxBuilder
```

Optionally, cap which VM IDs the account may ever use by granting the role on
specific IDs, for example `/vms/9000`. Treat that as a ceiling, not the
grant: Proxmox removes every ACL on `/vms/<id>` whenever that VM is
destroyed (the purge option is unrelated; it only clears backup, replication,
and HA references), so a per-ID grant works exactly once. The pool grant is
what survives. There is no VM or disk quota on a pool; a leaked token can
fill the granted storage.

| Fact | Variable |
|---|---|
| Disk storage (thin pool) | `disk_storage` |
| Bridge | `bridge` |
| Template VM ID | `vm_id` |

Verify from your workstation. The output should list exactly the paths
above and nothing on `/`, `/vms`, or `/nodes` itself:

```
set -a; . ~/.config/proxmox/packer.env; set +a
curl -sS --cacert <cluster-ca.pem> -H "Authorization: PVEAPIToken=$PROXMOX_USERNAME=$PROXMOX_TOKEN" "$PROXMOX_URL/access/permissions"
```

For TLS, prefer trusting the cluster CA over skipping verification: copy
`/etc/pve/pve-root-ca.pem` from a node, point `SSL_CERT_FILE` at it for
Packer and `SAFBOX_CA_FILE` for the clone test. Reserve
`proxmox_insecure_skip_tls_verify` and `SAFBOX_INSECURE_TLS=1` for throwaway
labs: with verification off, the token is sent to whoever answers.

## 7. Write the variables file

Copy `packer/example.pkrvars.hcl` to `packer/local.auto.pkrvars.hcl`. The
`.auto` name makes Packer load it without flags, and git ignores it. Fill in
every variable from the tables above, plus:

| Variable | Set it when |
|---|---|
| `vm_cores`, `vm_memory`, `vm_disk_size` | the node is smaller than the reference 4 vCPU, 8 GiB, 60G; the disk must be at least 40G |
| `proxmox_insecure_skip_tls_verify = true` | the API serves a self-signed certificate |
| `http_interface` | the workstation has several network interfaces |
| `kickstart_url` | the VM's network cannot reach the workstation; host the rendered kickstart elsewhere |
| `installer_ssh = true` | you want to SSH into a stuck installer while developing; `scripts/build.sh` refuses it unless `SAFBOX_DEV=1` |
| `cpu_type` | `x86-64-v3` for Rocky 10; the default `x86-64-v2-AES` suits the AlmaLinux v2 lane and keeps clones migratable. Named models expose no hardware RNG, which is why the source attaches a virtio-rng device; `rng0` needs `VM.Config.HWType`, already in the role |
| `disk_format = "qcow2"` | the disk storage is a directory, NFS, or CIFS storage |
| `vlan_tag` | the build network is a tagged VLAN |
| `http_bind_address` | the runner should offer the rendered kickstart on one address only |

## 8. Build and prove

```
tests/packer/validate.sh
scripts/build.sh
SAFBOX_NODE=<node> SAFBOX_POOL=<pool> scripts/clone-and-ssh.sh <template-vmid> <clone-vmid>
```

Add `SAFBOX_CA_FILE=<cluster-ca.pem>` (or, for a throwaway lab,
`SAFBOX_INSECURE_TLS=1`) to the clone command. The clone test only destroys
a VM it created itself: each run writes a unique run ID into the clone's
description and refuses to delete any VM whose description does not carry
that ID, so a pre-existing VM with the same number is never touched.

Rebuilding reuses `vm_id`, and Packer never overwrites: delete the previous
template first (through the API with the same token, which the pool grant
allows, or in the GUI). Full clones made from it are unaffected; linked
clones block the deletion.

**The Phase 1 template is not distributable.** It is tagged `unsealed` and
says so in its description: the build user, its passwordless sudo and SSH
key, shared SSH host keys, and the kickstart copies under `/root` are all
still present until the Phase 2 seal step. Use it only to develop and test
the appliance layer. The rendered kickstart is also served to the build VM
over plain HTTP from the runner, so the build network segment is trusted;
for release builds host it over HTTPS via `kickstart_url` or use the ISO
route described in the rebuild guide.

## What the account cannot do, on purpose

- Upload ISOs or templates. You stage media.
- Create, modify, or delete pools, or touch nodes other than the one granted.
- See or change any VM outside the pool.
- Write to any storage other than the one disk storage granted; the ISO
  storage is read-only to it.

If a build fails with a Proxmox 403, the message names the missing privilege
and path. Add exactly that to the role or ACL and nothing broader. One known
case: the template `tags` need the datacenter option `user-tag-access` to
permit them; if it does not, the 403 names it.
