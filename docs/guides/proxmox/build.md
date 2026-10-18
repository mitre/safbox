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
(`ssh`, `ssh-keygen`), curl, jq, and flock (util-linux; on macOS, Homebrew's
`flock` or `util-linux`).

**Install the right Ansible.** Several different things are called Ansible,
and it is easy to get the wrong one:

- `ansible` is the community package: `ansible-core` plus a set of
  collections. **This is the one to install**, at the version pinned in
  `tests/requirements.txt` (currently 14.5.0). `ansible/requirements.yml`
  pins collection versions that match it.
- `ansible-core` on its own has no collections. It works for the build,
  which installs its collections from `ansible/requirements.yml`, but it is
  not what the static suite or the linters were verified with.
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
| `vm_cores`, `vm_memory`, `vm_disk_size` | the node is smaller than the reference 4 vCPU, 8 GiB, 60G; the disk must be at least 60G. Beyond the fixed 20 GiB, the disk is shared 40/40/10/10 between `/home`, `/var`, `/var/log` and `/var/log/audit` ([Partition layout](../../reference/platform.md#partition-layout)) |
| `proxmox_insecure_skip_tls_verify = true` | a throwaway lab only, where you will not trust the cluster CA (step 6 explains why trusting it is better: with verification off, the token goes to whoever answers) |
| `http_interface` | the workstation has several network interfaces |
| `kickstart_url` | the VM's network cannot reach the workstation; host the rendered kickstart elsewhere |
| `installer_ssh = true` | you want to SSH into a stuck installer while developing; `scripts/build.sh` refuses it unless `SAFBOX_DEV=1` |
| `cpu_type` | the default `x86-64-v3` needs a v3 node; on older hardware see [Site overrides](#site-overrides) below. Named models expose no hardware RNG, which is why the source attaches a virtio-rng device (`rng0` needs `VM.Config.HWType`, already in the role) |
| `disk_format = "qcow2"` | the disk storage is a directory, NFS, or CIFS storage |
| `vlan_tag` | the build network is a tagged VLAN |
| `vga = "std"` | only if SPICE cannot be used at all: the default `qxl` is what SPICE needs, and SPICE (Console → SPICE, `remote-viewer`) is the default, tested way to reach the console ([desktop.md](desktop.md)); noVNC works with either |
| `http_bind_address` | the runner should offer the rendered kickstart on one address only |
| `build_gate_ssh_config_file` | CINC Auditor cannot read or use the runner's SSH client config (the build gate fails with `Permission denied @ rb_sysopen - /etc/ssh/ssh_config`); `"/dev/null"` reads none. Set `SAFBOX_SSH_CONFIG` the same way for the clone test. See [`scripts/validate.sh`](../../reference/validation.md#scripts-validate-sh) |

### Site overrides

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

## 8. Build and prove

```
tests/packer/validate.sh
tests/kickstart/ks-lint.sh
scripts/build.sh
SAFBOX_NODE=<node> SAFBOX_POOL=<pool> scripts/clone-and-ssh.sh <template-vmid> <clone-vmid>
```

`scripts/build.sh` mints an ephemeral build key and runs Packer. The build
types a short GRUB edit at the ISO menu, serves the kickstart, waits
through the install and reboot, confirms FIPS, Secure Boot and the guest
agent over SSH, runs the appliance playbook, validates the VM from this
machine (`scripts/validate.sh`: CINC Auditor over SSH, then the SAF CLI
thresholds), seals the image (deletes the build user, scrubs host identity
and installer residue, asserts the seal's own post-conditions), and
converts the VM to a template.

Add `SAFBOX_CA_FILE=<cluster-ca.pem>` (or, for a throwaway lab,
`SAFBOX_INSECURE_TLS=1`) to the clone command. Pass `--keep` as a third
argument to leave the clone running. Set `SAFBOX_CLONE_PASSWORD` to an
`openssl passwd -6` hash to give `safuser` its password (see
[Accounts on a clone](#accounts-on-a-clone)); without it first boot
generates `safuser`'s.

The clone test (`scripts/clone-and-ssh.sh`) is the release gate. It clones
the template through the API into the pool, injects a cloud-init user
(`admin`, or `SAFBOX_CLONE_USER`, which a site inputs file must then name
as `admin_user`) and an RSA key, boots it, learns its address from the
guest agent, logs in as that user and checks FIPS mode and the clone's
host name, waits for the boot to finish (below), logs in as `safuser` with
the same key, then runs
`scripts/validate.sh` against it. SSH
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

The clone test only destroys a VM it created itself: each run writes a
unique run ID into the clone's description and refuses to delete any VM
whose description does not carry that ID, so a pre-existing VM with the
same number is never touched.

### Accounts on a clone

A clone has two accounts besides root: `admin`, the key-only account for
deploying and automation (the release gate logs in as it), and `safuser`,
the account people log in as day to day. On the clone's **Cloud-Init** tab
(or through the API, as `scripts/clone-and-ssh.sh` does) set:

- **User** (`ciuser`): leave it blank, and cloud-init makes `admin`; the
  clone test sets `admin` explicitly. It gets the SSH key and passwordless
  sudo, never a password.
- **SSH public key** (`sshkeys`): your key, for `admin`. First boot gives
  it to `safuser` as well.
- **Password** (`cipassword`, optional): `safuser`'s password, and
  `safuser`'s only; `admin` never gets it. Paste the output of `openssl
  passwd -6`, not the plain password: Proxmox stores a plain one as a
  SHA-256 hash, which the STIG flags, but keeps a `$6$` hash as given.
  Leave it empty and first boot generates `safuser`'s password; read it
  with `sudo cat /etc/safbox/safuser.env` as `admin`.

`safuser`'s password follows the STIG: it expires 60 days after it is set,
and three wrong passwords in 15 minutes lock the account until an
administrator releases it. As `admin`, `sudo passwd safuser` sets a new
password and `sudo faillock --user safuser --reset` releases a lock.
`admin` itself cannot be locked out or expire. [Accounts](../../reference/accounts.md)
says more, including a deployment's own cloud-init users list.

### Giving a clone more disk

A clone's disk starts at the template's `vm_disk_size`. To give it more,
resize the disk after cloning and before the first start: the disk's
**Resize** action in the GUI, or through the API (the token's
`VM.Config.Disk` covers it):

```
curl -sS --cacert <cluster-ca.pem> -H "Authorization: PVEAPIToken=$PROXMOX_USERNAME=$PROXMOX_TOKEN" \
  -X PUT --data-urlencode disk=scsi0 --data-urlencode size=+20G \
  "$PROXMOX_URL/nodes/<node>/qemu/<clone-vmid>/resize"
```

First boot hands the new space out by share; [Partition
layout](../../reference/platform.md#partition-layout) explains how, and how
to grow a box that has already booted.

Rebuilding reuses `vm_id`, and Packer never overwrites: delete the previous
template first (through the API with the same token, which the pool grant
allows, or in the GUI). Full clones made from it are unaffected; linked
clones block the deletion.

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

### Where a run keeps its files

Every `scripts/build.sh` run gets its own directory, `.build/runs/<run id>/`
(the UTC start time and a random suffix, mode 0700), and prints it as its
first line (`build log: .../build.log`). It holds:

| File | Kept after the run |
|---|---|
| `build.log`, everything the run printed | yes |
| `packer-debug.log`, Packer's full debug log, checked for the API token when the run ends: normally, on failure, or on a SIGINT, SIGTERM or SIGHUP (a run whose debug log holds the token exits 2 and says so in `build.log`). A SIGKILL skips every end-of-run step; delete that run's key yourself | yes |
| `build_key`, `build_key.pub`, the ephemeral key pair | only with `SAFBOX_DEV=1` |
| `galaxy/`, the run's own install of `ansible/requirements.yml` | no |

`.build/runs/latest` points at the newest run, and `last.log` in the
repository root at `.build/runs/latest/build.log`, so `tail -F last.log`
follows the current build and the next one. Run directories are not pruned;
delete old ones when you no longer need their logs.

To stop a run, signal its whole process group: Ctrl-C in its terminal
(SIGINT), `kill -TERM -<pgid>`, or `kill -HUP -<pgid>` (what closing the
terminal sends). Packer cancels the build and removes its VM, its output
still reaches `build.log`, and then the end-of-run steps above run; the run
exits 130 for SIGINT, 143 for SIGTERM and 129 for SIGHUP, or 2 if the token
is in the debug log. A SIGTERM or SIGHUP sent to `build.sh` alone takes
effect only once Packer has exited on its own.

Earlier versions kept the key in `.build/build_key` (with `SAFBOX_DEV=1`),
the logs in `.build/logs/` and the debug log in `.build/packer-debug.log`.
Nothing uses or cleans those any more; delete them.

When the clone's user cannot log in to a development template, the clone
test reads cloud-init's state over SSH as the build user, for diagnostics.
That needs the key of the run that built the template, which is kept only
if the build ran with `SAFBOX_DEV=1`. The clone test offers every kept key,
newest first; with many kept keys sshd's `MaxAuthTries` can refuse before
it reaches the right one, so name it with
`SAFBOX_BUILD_KEY=.build/runs/<run id>/build_key`.

### Running builds in parallel

Two builds can run at the same time from one checkout, for example a Rocky
and an AlmaLinux build, on a host large enough for both VMs. Give each its
own template ID and name; everything else a run writes is already its own:

```
scripts/build.sh -var vm_id=9003 -var vm_name=safbox-rocky &
scripts/build.sh -var vm_id=9004 -var vm_name=safbox-alma -var iso_file=<storage>:iso/<alma iso> &
```

- Both IDs must be free and inside what the account may use (step 6: the
  pool grant, and any per-ID ceiling you set).
- `last.log` follows whichever run started last. Follow a particular run
  with `tail -F .build/runs/<run id>/build.log`.
- Each run installs the pinned Lockdown role from its Git source itself, so
  each needs to reach it.
- The build gates write separate results files: a second scan in the same
  second gets `.build/validate-build-<profile>-<timestamp>-2.json`.
- CINC Auditor shares one cache for profile dependencies (the STIG
  baseline). The first scan after the baseline pin changes, or on a new
  workstation, clones it into the cache while holding a lock, and a second
  scan waits for that lock for at most 30 seconds. If the clone takes
  longer, the second build's gate fails with `Giving up waiting on cache
  lock` and `validate.sh: cinc-auditor exited 1`. It fails loudly, with
  no verdict recorded, and the template is
  not made. Rerun it. To avoid it, start the parallel builds only once one
  scan has filled the cache, for example one earlier build, or
  `cinc-auditor vendor verify/profiles/safbox-rhel10-stig-overlay` (as
  `tests/ansible/lint.sh` does).

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
