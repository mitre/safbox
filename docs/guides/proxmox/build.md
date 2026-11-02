# Building SAFBox on Proxmox VE

This is the operator's checklist for a Proxmox VE 8 or 9 cluster: what you
do by hand once, which variable each choice lands in, and the smallest set of
permissions the build account needs. It is the one build procedure; the
[reference pages](../../reference/platform.md) describe what the image
contains, how it is validated, and how to troubleshoot it.

Everything below runs as root on a Proxmox node unless stated otherwise.
Replace the angle-bracket placeholders with your own names; none of the
values here are committed to git.

## Prerequisites

The build runs from your workstation: Packer drives the Proxmox API, Ansible
configures the build VM over SSH, and CINC Auditor and the SAF CLI check the
VM before it is sealed. `scripts/build.sh` refuses to start if any of them
is missing. Install them with whatever your OS provides, or from the
upstream pages linked below. The versions listed are the ones CI uses
(`.github/workflows/static.yml`, `tests/requirements.txt`).

| Tool | Version | Install |
|---|---|---|
| Packer | 1.12 or newer (CI: 1.16.1); `packer init` installs the pinned plugins | [developer.hashicorp.com/packer/install](https://developer.hashicorp.com/packer/install) |
| Ansible | the `ansible` package, 14.5.0 (see below) | [Ansible installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) |
| CINC Auditor | 7.2.1 (any 5.0 or newer runs the profiles) | [cinc.sh/docs/auditor](https://cinc.sh/docs/auditor/#install) |
| SAF CLI | 1.7.0, on Node.js 22 | [SAF CLI installation](https://github.com/mitre/saf#installation) |
| Node.js and npm | 18 or newer; the build uses them to build the documentation site the box serves (`site/`), from its lockfile | [nodejs.org](https://nodejs.org/en/download) |

The scripts also use the usual command-line tools: git, the OpenSSH client
(`ssh`, `ssh-keygen`), curl, jq, `uuidgen` (util-linux), `timeout`
(coreutils; on macOS, Homebrew's `coreutils`), netcat (`nc` or `ncat`) and
OpenSSL 3 as `openssl`,
which the release gate's client checks use to probe the box's ports and
TLS (on macOS, whose `openssl` is LibreSSL, put Homebrew's `openssl@3`
first on `PATH`).

**Install the right Ansible.** Several different things are called Ansible,
and it is easy to get the wrong one:

- `ansible` is the community package: `ansible-core` plus a set of
  collections. **This is the one to install**, at the version pinned in
  `tests/requirements.txt` (currently 14.5.0). `ansible/requirements.yml`
  pins collection versions that match it.
- `ansible-core` on its own has no collections, and `scripts/build.sh`
  refuses it: the build checks for the `ansible` package at the pinned
  version.
- Packages from an OS repository called `ansible` or `ansible-core` are
  often several releases old, and the version number they carry may be
  for either of the two above. Don't use them unless their version matches.
- The appliance itself installs `ansible-core` 2.16.16 on the box
  (`ansible/group_vars/all/main.yml`). That pin applies to the image, not
  to your workstation.

With pipx, `--include-deps` is required. The `ansible` package declares only
one command of its own, `ansible-community`; `ansible-playbook` and the rest
come from its dependency `ansible-core`, whose commands pipx does not expose
without the flag.

```
pipx install --include-deps ansible==14.5.0
ansible-community --version   # Ansible community version 14.5.0
```

The Ansible control node does not run natively on Windows; use WSL there.
Contributors also need the development tools (pre-commit, pykickstart,
the linters) listed in [Developing SAFBox](../../reference/development.md).

## 1. Pick the node and check its CPU

Rocky Linux 10 and AlmaLinux 10 need an x86-64-v3 CPU (AVX2); AlmaLinux 10
also ships an `x86_64_v2` build for older hardware. Check the node:

```
/lib64/ld-linux-x86-64.so.2 --help | grep -A4 'Subdirectories of glibc-hwcaps'
```

`x86-64-v3 (supported, searched)` means Rocky Linux 10 and AlmaLinux 10 will
boot. If only `x86-64-v2` is supported, use the AlmaLinux `x86_64_v2` ISO;
the x86-64-v3 builds will not boot on that node.

| Fact | Variable |
|---|---|
| Node name | `proxmox_node` |

Use the node's name as shown under Datacenter in the GUI (`hostname` on the
node, or `pvesh get /nodes`), not its IP address. The address goes only in
`PROXMOX_URL`. An address here makes Proxmox try to forward the request to
another node of that name, and the build fails with
`596 ... certificate verify failed`, which looks like a certificate problem
but isn't. Use the same name in the `/nodes/<node>` ACL in step 6.

## 2. Upload the ISO

Two network prerequisites on the bridge the VM will use: a DHCP server
(the kickstart and the clone test both use DHCP), and outbound HTTPS to the
distribution's mirrors, because the minimal ISO lacks the guest agents
and cloud-init, and the install fetches them. Without egress the install fails
early and visibly (`%post --erroronfail`) rather than leaving a silent
template.

The build VM also fetches its kickstart from the runner, on TCP port 8600
(the `http_port` variable). If the runner has a firewall, allow that port from
the build network, or the installer waits and the build times out waiting for
SSH:

```sh
sudo firewall-cmd --permanent --add-port=8600/tcp && sudo firewall-cmd --reload  # firewalld
sudo ufw allow 8600/tcp                                                            # ufw
```

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
is chosen by `safbox_desktop_enabled` in `ansible/local.yml`, not by the
ISO, and needs the DVD ISO or a reachable package mirror; see
[A desktop build](../../reference/appliance.md#a-desktop-build). Reach any
SAFBox's console over SPICE, the default: see [desktop.md](desktop.md).

Use an installer ISO (`minimal` or `dvd`), never a live image such as
`Workstation` or `Workstation-Lite`. A live image boots to a desktop and
ignores the kickstart, so the build waits for SSH until `install_timeout`
expires.

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

Three roles: one for building, one read-only for the ISO storage, and one
that only reads the node. These are the privileges the Packer Proxmox
plugin and the clone test use, and nothing else. Notably absent:
`Datastore.AllocateTemplate` (no ISO or template upload), `Pool.Allocate`
(creating a VM into a pool is authorized by `VM.Allocate` on the pool, so
the account never needs to modify or delete the pool itself), `Sys.Modify`
(no node changes), and anything on `/`.

```
pveum role add SAFBoxBuilder -privs "VM.Allocate VM.Clone VM.Audit VM.Console VM.PowerMgmt \
  VM.Config.CDROM VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network \
  VM.Config.Options VM.Config.Cloudinit VM.Config.HWType VM.GuestAgent.Audit \
  Datastore.Audit Datastore.AllocateSpace Pool.Audit SDN.Use"
pveum role add SAFBoxISOReader -privs "Datastore.Audit"
pveum role add SAFBoxNodeAudit -privs "Sys.Audit"
```

On Proxmox 8, `VM.GuestAgent.Audit` does not exist; use `VM.Monitor` in its
place. `Sys.Audit` on the node is required by the plugin for node and bridge
lookups; be aware it also lets the account list that node's tasks and read
its network configuration.

## 5. Create the build user and an API token

```
pveum user add <user>@pve --comment "SAFBox build runner"
pveum user token add <user>@pve <token-name> --privsep 1
```

A Proxmox API token is two values. Its **ID** is `<user>@pve!<token-name>`,
which identifies which of the user's tokens is being used and is not
sensitive. Its **secret** is the UUID printed once by the command above.
The API wants both, as `PVEAPIToken=<id>=<secret>`, and the Packer plugin
takes them as separate fields. `--privsep 1` separates the token's
privileges from the user's: the token may do only what both the user and
the token are granted, so step 6 grants each ACL to both.

Put the token and the cluster CA in a file only you can read, by default
`~/.config/proxmox/packer.env`, which `scripts/build.sh` and
`scripts/clone-and-ssh.sh` source (`SAFBOX_PROXMOX_ENV` names another). It
holds credentials only: the node, pool and every other site setting go in
`packer/local.auto.pkrvars.hcl` (step 7), which both scripts read. A
variable already set in your shell wins over the file. Start from
`scripts/example.env`:

```
mkdir -p ~/.config/proxmox
cp scripts/example.env ~/.config/proxmox/packer.env
chmod 600 ~/.config/proxmox/packer.env
```

Then replace the placeholders. The whole file is four lines:

```
PROXMOX_URL=https://<node-address>:8006/api2/json
PROXMOX_USERNAME='<user>@pve!<token-name>'
PROXMOX_TOKEN=<token-secret>
PROXMOX_CA_FILE=~/.config/proxmox/pve-root-ca.pem
```

`PROXMOX_CA_FILE` is the cluster CA (step 6); leave it out to use the
system trust store. When it is set, the scripts hand it to Packer as
`SSL_CERT_FILE`, replacing any `SSL_CERT_FILE` in your shell. The scripts refuse the file unless its mode is 0600.
An older file that still sets `SAFBOX_NODE`, `SAFBOX_POOL`,
`SAFBOX_CA_FILE` or `SSL_CERT_FILE` keeps working for now; the scripts
print a warning naming each line to move.

It is best practice to never put these in a Packer variables file, and to avoid putting them anywhere you might accidentally commit them to history.

## 6. Grant the ACLs

One grant per thing the build touches, each to the user and to its token.
Creation rights come from the pool: every create and clone request names
it, and Proxmox authorizes the request through `VM.Allocate` on the pool
path. The node gets only `Sys.Audit`.

```
pveum acl modify /pool/<pool>                     --users <user>@pve --tokens '<user>@pve!<token-name>' --roles SAFBoxBuilder
pveum acl modify /storage/<disk-storage>          --users <user>@pve --tokens '<user>@pve!<token-name>' --roles SAFBoxBuilder
pveum acl modify /storage/<iso-storage>           --users <user>@pve --tokens '<user>@pve!<token-name>' --roles SAFBoxISOReader
pveum acl modify /sdn/zones/localnetwork/<bridge> --users <user>@pve --tokens '<user>@pve!<token-name>' --roles SAFBoxBuilder
pveum acl modify /nodes/<node>                    --users <user>@pve --tokens '<user>@pve!<token-name>' --roles SAFBoxNodeAudit
```

Optionally, cap which VM IDs the account may ever use by granting the role on
specific IDs, for example `/vms/<id>`. Treat that as a ceiling, not the
grant: Proxmox removes every ACL on `/vms/<id>` whenever that VM is
destroyed (the purge option is unrelated; it only clears backup, replication,
and HA references), so a per-ID grant works exactly once. The pool grant is
what survives. There is no VM or disk quota on a pool; a leaked token can
fill the granted storage.

| Fact | Variable |
|---|---|
| Disk storage (thin pool) | `disk_storage` |
| Bridge | `bridge` |
| Template VM ID, a free one the account may use | `vm_id` (step 7) |

Verify from your workstation. The output should list exactly the paths
above and nothing on `/`, `/vms`, or `/nodes` itself. curl reads the token
from a file descriptor, so it never appears on a command line:

```
set -a; . ~/.config/proxmox/packer.env; set +a
curl -sS ${PROXMOX_CA_FILE:+--cacert "$PROXMOX_CA_FILE"} -K <(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PROXMOX_USERNAME" "$PROXMOX_TOKEN") \
  "$PROXMOX_URL/access/permissions"
```

For TLS, prefer trusting the cluster CA over skipping verification: copy
`/etc/pve/pve-root-ca.pem` from a node and point `PROXMOX_CA_FILE` at it;
the scripts trust it for their own API calls and hand it to Packer. Reserve
`proxmox_insecure_skip_tls_verify` and `SAFBOX_INSECURE_TLS=1` for throwaway
labs: with verification off, the token is sent to whoever answers.

## 7. Write the variables file

Copy `packer/example.pkrvars.hcl` to `packer/local.auto.pkrvars.hcl`. The
`.auto` name makes Packer load it without flags, and git ignores it. Fill in
every variable from the tables above, plus:

| Variable | Set it when |
|---|---|
| `vm_cores`, `vm_memory`, `vm_disk_size` | the node is smaller than the reference 4 vCPU, 8 GiB, 60G; the disk must be at least 60G. Beyond the fixed 20 GiB, the disk is shared 40/40/10/10 between `/home`, `/var`, `/var/log` and `/var/log/audit` ([Partition layout](../../reference/platform.md#partition-layout)) |
| `proxmox_insecure_skip_tls_verify = true` | a throwaway lab only, where you will not trust the cluster CA (step 6 explains why trusting it is better: with verification off, the token goes to whoever answers) |
| `http_interface` | the workstation has several network interfaces |
| `kickstart_url` | the VM's network cannot reach the workstation; host the rendered kickstart elsewhere |
| `cpu_type` | the default `x86-64-v3` needs a v3 node; on older hardware see [Site overrides](#site-overrides) below. Named models expose no hardware RNG, which is why the source attaches a virtio-rng device (`rng0` needs `VM.Config.HWType`, already in the role) |
| `disk_format = "qcow2"` | the disk storage is a directory, NFS, or CIFS storage |
| `vlan_tag` | the build network is a tagged VLAN |
| `vga = "std"` | only if SPICE cannot be used at all: the default `qxl` is what SPICE needs, and SPICE (Console → SPICE, `remote-viewer`) is the default, tested way to reach the console ([desktop.md](desktop.md)); noVNC works with either |
| `http_bind_address` | the runner should offer the rendered kickstart on one address only |
| `http_port` | port 8600 is taken on the runner, or your firewall allows another port for the kickstart |
| `build_gate_ssh_config_file` | CINC Auditor cannot read or use the runner's SSH client config (the build gate fails with `Permission denied @ rb_sysopen - /etc/ssh/ssh_config`); `"/dev/null"` reads none. Set `SAFBOX_SSH_CONFIG` the same way for the clone test. See [`scripts/validate.sh`](../../reference/validation.md#scripts-validate-sh) |

### Site overrides

The repository describes the normal case. Anything particular to your site
goes in two git-ignored files:

- `packer/local.auto.pkrvars.hcl` for Packer variables (node, pool, storage,
  ISO, CPU model, resources).
- `ansible/local.yml` for Ansible variables. The build passes it to every
  playbook when it exists, and its log says whether it did (`Ansible site
  settings: ...`); when running a playbook by hand, add
  `-e @ansible/local.yml`. Values there replace the project's defaults in
  `ansible/group_vars/all/main.yml`.

Example: on x86-64-v2 hardware, set `cpu_type = "x86-64-v2-AES"` in the
Packer file, and in `ansible/local.yml` replace `safbox_tool_cinc_auditor`
with CINC's el9 build (its el10 build requires x86-64-v3).

## 8. Build and prove

```
scripts/build.sh
scripts/clone-and-ssh.sh <template-vmid> <clone-vmid>
```

`scripts/build.sh --help`, `scripts/clone-and-ssh.sh --help` and
`scripts/validate.sh --help` list every argument, environment variable and
file each script reads, with its default. `build.sh` passes every other
argument to `packer build` unchanged.

The template's VM ID is `vm_id` in `packer/local.auto.pkrvars.hcl`, or
`-var vm_id=<id>` on the `build.sh` command line, which wins. The clone's
is the second argument of `clone-and-ssh.sh`. Both must be free and
inside what step 6 lets the account use.

`scripts/build.sh` mints an ephemeral build key and runs Packer. The build
types a short GRUB edit at the ISO menu, serves the kickstart, waits
through the install and reboot, confirms FIPS, Secure Boot and the guest
agent over SSH, runs the appliance playbook, validates the VM from this
machine (`scripts/validate.sh`: CINC Auditor over SSH, then the SAF CLI
thresholds), seals the image (deletes the build user, scrubs host identity
and installer residue, asserts the seal's own post-conditions), and
converts the VM to a template. A build that fails or is interrupted keeps
its VM for diagnosis; see
[When a build fails or is interrupted](#when-a-build-fails-or-is-interrupted).

The clone test uses the same node, pool and CA as the build:
`proxmox_node` and `proxmox_pool` from `packer/local.auto.pkrvars.hcl`,
`PROXMOX_CA_FILE` from the env file (for a throwaway lab,
`SAFBOX_INSECURE_TLS=1` on the command line turns verification off
instead). Pass `--keep`
after the IDs to leave the clone running for you. Set `SAFBOX_CLONE_PASSWORD` to an
`openssl passwd -6` hash to give `safuser` its password (see
[Accounts on a clone](#accounts-on-a-clone)); without it first boot
generates `safuser`'s. To log in to the clones it makes with your own key,
put the public key in `.build/keys/` (every `*.pub` there is added) or
name its file in `SAFBOX_EXTRA_SSH_KEYS` (colon-separated); a key the
FIPS-mode box would refuse, Ed25519 included, stops the run before the
clone is made. Run from a git worktree, the script uses that worktree's
`.build/`; see [Deploying a clone](../../reference/accounts.md#deploying-a-clone).

The clone test (`scripts/clone-and-ssh.sh`) is the release gate. It clones
the template through the API into the pool, injects a cloud-init user
(`admin`, or `SAFBOX_CLONE_USER`, which a site inputs file must then name
as `admin_user`) with its RSA build key and any extra keys, boots it,
learns its address from the guest agent, logs in as that user and checks FIPS mode and the clone's
host name, waits for the boot to finish (below), logs in as `safuser` with
the same key, then runs `scripts/validate.sh --client` against it:
the box's two profiles over SSH, then the client profile from your
workstation (see [How SAFBox is validated](../../reference/validation.md)). SSH
answers well before first boot has finished: the secrets, the certificate,
the Heimdall and Vulcan pods and the TLS proxy come later, and a scan that
starts too early fails their controls. So the clone test first waits, over
SSH, on `systemctl is-system-running --wait`, which returns once the boot's
job queue has settled:

- `running`: the scan starts.
- `degraded`: the boot finished with failed units. They are listed, then
  the scan starts and judges the services itself. A fresh clone usually
  ends here: a podman healthcheck that fails while its container is still
  starting leaves a failed transient unit (`podman healthcheck run`).
- No answer within `SAFBOX_READY_TIMEOUT` seconds (a positive whole number;
  default 600; raise it on a slow host): the run fails without a scan and
  lists the jobs still queued. An SSH failure while waiting is reported as
  such, not as a timeout.

A switched-off service has no units, so it neither holds up the wait nor
fails it. `SAFBOX_SKIP_VALIDATE=1` stops after the SSH check, before the
wait.

The release gate signs in to nothing, so on a clone kept with `--keep`
your first sign-in to Heimdall or Vulcan through Keycloak, with the
password first boot generated (see
[Accounts in the applications](../../reference/accounts.md#accounts-in-the-applications)),
asks for a new one, as it will for the box's users. Check sign-in by hand
there; see [How SAFBox is validated](../../reference/validation.md).

The clone test only destroys a VM it created itself: each run writes a
unique run ID into the clone's description and refuses to delete any VM
whose description does not carry that ID, so a pre-existing VM with the
same number is never touched. Delete a clone kept with `--keep` with
`scripts/delete-vm.sh <clone-vmid>` (below).

### Accounts on a clone

A clone has two accounts besides root: `admin`, the key-only account for
deploying and automation (the release gate logs in as it), and `safuser`,
the account people log in as day to day. On the clone's **Cloud-Init** tab
(or through the API, as `scripts/clone-and-ssh.sh` does) set:

- **User** (`ciuser`): leave it blank, and cloud-init makes `admin`; the
  clone test sets `admin` explicitly. It gets the SSH key and passwordless
  sudo, never a password.
- **SSH public key** (`sshkeys`): your key, for `admin`. First boot gives
  it to `safuser` as well. It must be ECDSA or RSA of at least 2048 bits:
  the box is in FIPS mode and its sshd refuses Ed25519 (`ssh-keygen -t
  ecdsa -b 384` makes an accepted key).
- **Password** (`cipassword`, optional): `safuser`'s password, and
  `safuser`'s only; `admin` never gets it. Paste the output of `openssl
  passwd -6`, not the plain password: Proxmox stores a plain one as a
  SHA-256 hash, which the STIG flags, but keeps a `$6$` hash as given.
  Leave it empty and first boot generates `safuser`'s password; read it
  with `sudo cat /etc/safbox/safuser.env` as `admin`.

Set them before the clone's first boot: first boot runs once, so a
password or key changed afterwards does not reach `safuser` (as `admin`,
`sudo passwd safuser` sets its password). See
[Deploying a clone](../../reference/accounts.md#deploying-a-clone).

Clone the sealed template, never a box that has already booted: a clone
of a deployed box keeps that box's secrets, keys and databases (see
**Cloning a deployed box** in [Services on the box](../../reference/services.md)).

`safuser`'s password follows the STIG: it expires 60 days after it is set,
and three wrong passwords in 15 minutes lock the account until an
administrator releases it. As `admin`, `sudo passwd safuser` sets a new
password and `sudo faillock --user safuser --reset` releases a lock.
`admin` has no password, so it cannot be locked out and does not expire. [Accounts](../../reference/accounts.md)
says more, including a deployment's own cloud-init users list.

### Giving a clone more disk

A clone's disk starts at the template's `vm_disk_size`. To give it more,
resize the disk after cloning and before the first start: the disk's
**Resize** action in the GUI, or through the API (the token's
`VM.Config.Disk` covers it):

```
curl -sS ${PROXMOX_CA_FILE:+--cacert "$PROXMOX_CA_FILE"} -K <(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PROXMOX_USERNAME" "$PROXMOX_TOKEN") \
  -X PUT --data-urlencode disk=scsi0 --data-urlencode size=+20G \
  "$PROXMOX_URL/nodes/<node>/qemu/<clone-vmid>/resize"
```

First boot hands the new space out by share; [Partition
layout](../../reference/platform.md#partition-layout) explains how, and how
to grow a box that has already booted.

Packer never overwrites a VM: a rebuild needs a free `vm_id`, or the
previous template deleted first. Delete templates you no longer need
(`scripts/delete-vm.sh <vm_id>`, below, which uses the same token and the
pool grant, or the GUI). Full clones made from a template are unaffected
by its deletion; linked clones block it.

**Only sealed templates are distributable.** The build seals by default:
it deletes the build user, its key, and its sudo rule, removes shared SSH
host keys, machine identity, and the installer's kickstart copies, and
asserts its own result. A build with `seal = false` runs the development
seal instead: machine identity, cloud-init state and installer residue are
still scrubbed, but the build user, its key and sudo rule and the shared SSH
host keys stay for inspection, with the build logs. Such a template is tagged `unsealed` and says
so in its description, and nothing checks it for leftovers (the seal's
post-conditions run only in a full seal); use it only to develop and test
the appliance layer. The rendered kickstart is also served to the build VM
over plain HTTP from the runner, so the build network segment is trusted;
for release builds host it over HTTPS via `kickstart_url` or use one of
the routes in [When the VM cannot reach your workstation](#when-the-vm-cannot-reach-your-workstation).

### When a build fails or is interrupted

A failed build, a failed build gate included, keeps its VM so you can find
out why: `build.sh` runs Packer with `-on-error=abort`, which leaves the VM
as it was when the build stopped, usually running. Ctrl-C does the same.
The build key stays in `.build/run/`, and the last lines of the build's
output say how to reach the VM and how to delete it:

```
The build failed or was interrupted. Its VM is kept for diagnosis:
  VM ID:   <vm_id>
  ssh:     ssh -i .../.build/run/build_key ... packer@<address>
  delete:  scripts/delete-vm.sh <vm_id> (or on the node: qm stop <vm_id>; qm destroy <vm_id> --purge)
```

The address is the one Packer connected to; a build that stopped before
it reached SSH (during the install, say) shows it only in the Proxmox UI,
on the VM's console or, once the guest agent runs, its summary. The kept
VM holds its ID until you delete it, so delete it before you rebuild with
the same `vm_id`. The next build empties `.build/run/`, the kept key with
it.

A build whose `vm_id` another VM already has fails at once without making
a VM. `build.sh` then says the ID belongs to an existing VM and suggests no
delete, because that VM is not the build's: give the build a free ID.

`scripts/delete-vm.sh <vm_id>` deletes a VM or template through the API
with the build's token and env file: it shows the VM's name, node and
whether it is a template, asks you to type the ID, stops the VM if it
runs, and deletes it with its disks (purge, so backup, replication and HA
jobs lose it too). It works for a failed build's VM, a clone kept with
`--keep` and a template you no longer need. List IDs it must never touch,
space- or comma-separated, in `SAFBOX_PROTECTED_IDS` set in the shell.
Deleting cannot be undone. Without the API, on the node: `qm stop <vm_id>`
if it runs, then `qm destroy <vm_id> --purge --destroy-unreferenced-disks 1`.

To have Packer delete the VM on failure instead, pass `-on-error=cleanup`
to `build.sh`; any other `-on-error=` mode you pass is used as given.

### Where a build keeps its files

`scripts/build.sh` keeps its files in `.build/run/` (mode 0700), which the
next build empties first, and prints the log's path as its first line
(`build log: .../build.log`). It holds:

| File | Kept after the build |
|---|---|
| `build.log`, everything the build printed | yes |
| `packer-debug.log`, Packer's full debug log, checked for the API token when the build ends, however it ends, Ctrl-C included (a build whose debug log holds the token exits 2 and says so). A SIGKILL skips that check and leaves the build key; delete it yourself | yes |
| `build_key`, `build_key.pub`, the ephemeral key pair | after a successful build, no; after a failed or interrupted one, yes (see above) |
| `galaxy/`, the build's install of `ansible/requirements.yml` | yes |
| `site/`, the documentation site the box serves | yes |
| `scans/`, the build gate's results, which the seal installs in the template | yes |

One build at a time per checkout: a second build started from the same
checkout empties the first one's directory.

## When the VM cannot reach your workstation

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
