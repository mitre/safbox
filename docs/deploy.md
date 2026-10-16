# Deploying SAFBox

This guide takes a sealed SAFBox template to a running appliance: deploy
it, log in, reach Heimdall and Vulcan, and make the site decisions the
appliance leaves to you. To build the template yourself, see
[rebuild.md](rebuild.md). Everything SAFBox does not meet in the RHEL 10
STIG, and why, is in [deviations.md](deviations.md).

## What you get

| Port | Service | Notes |
|---|---|---|
| 22 | SSH | key login only, as the user cloud-init creates |
| 443 | landing page | each service's status and a link to it |
| 8443 | Heimdall | view and compare security results (HDF) |
| 9443 | Vulcan | author STIG-ready security content |

Every web port is HTTPS through one nginx proxy, with a certificate the box
generates for itself on first boot. Nothing listens on port 80, and the
firewall allows those four ports and nothing else. The SAF tools are on
the box for assessments from it: CINC Auditor, the SAF CLI, Ansible with
the Lockdown STIG collections, and Packer (`safbox status` lists their
versions).

The reference footprint is 4 vCPU, 8 GiB of memory and a 60 GB disk. With
both applications running the box needs 4 GiB at the least; a build without
Vulcan (`safbox_vulcan_1: false`, see rebuild.md) runs in less.

## Before you start

- A sealed SAFBox template on your hypervisor. A template built with
  `seal = false` is a development artifact, tagged `unsealed`; do not
  deploy it for use.
- An SSH key pair, RSA (3072 bits or more) or ECDSA. SAFBox runs in FIPS
  mode, which may refuse Ed25519 keys.
- A network that gives the box an address (DHCP, or a static address you
  pass to cloud-init) and lets your browser reach ports 443, 8443 and 9443.
- Storage for the box that is encrypted beneath it (see "Data at rest").

## Deploy with Terraform

`deploy/terraform/proxmox/` clones the template, hands the clone a
cloud-init user, key and network, starts it, waits for the guest agent to
report an address, and prints it. It uses the community `bpg/proxmox`
provider, pinned to one release in `versions.tf` with its checksums in
`.terraform.lock.hcl`, and needs Terraform 1.16 or newer.

**Account.** The least-privilege account and token of the build guide
([guides/proxmox/build.md](guides/proxmox/build.md), the `SAFBoxBuilder`
role on the pool, the disk storage, the bridge and the node) can deploy as
well: cloning into the pool is authorized by `VM.Allocate` on the pool,
and the clone needs `VM.Clone` on the template, `VM.Config.*`,
`VM.PowerMgmt`, `Datastore.AllocateSpace` and the guest-agent privilege to
read the address. Give deployment its own token if you prefer.

**Credentials** come from the environment, never from a file in the
repository. From the build's env file:

```
set -a; . ~/.config/proxmox/packer.env; set +a
export PROXMOX_VE_ENDPOINT="${PROXMOX_URL%/api2/json}/"
export PROXMOX_VE_API_TOKEN="${PROXMOX_USERNAME}=${PROXMOX_TOKEN}"
```

For TLS, trust the cluster CA (`export SSL_CERT_FILE=<cluster-ca.pem>`);
set `proxmox_insecure = true` only for a throwaway lab whose API serves a
self-signed certificate, since the token then goes to whoever answers.

**Site values** go in `terraform.tfvars`, which git ignores:

```
cd deploy/terraform/proxmox
cp example.tfvars terraform.tfvars    # then edit: node, pool, storage, template ID, your public key
terraform init
terraform apply
```

`apply` takes a few minutes: it clones the template, then waits for the
guest agent, which reports an address once the box has booted. It prints:

```
address      = "<address>"
landing_page = "https://<address>/"
ssh          = "ssh safbox@<address>"
vm_id        = <id>
```

First boot is still running when the address appears: the box generates
its secrets and certificate and starts the services, which takes a few
more minutes. `terraform destroy` stops and deletes the box and its disks.

The variables (`variables.tf`) cover a static address (`ipv4_address`,
`ipv4_gateway`, `dns_servers`), another bridge or VLAN, and the CPU and
memory, which otherwise stay the template's. The module sets the
template's firmware (UEFI on q35) explicitly, because the provider would
otherwise apply its own defaults to the clone, and it turns off cloud-init's
package upgrade on first boot: an appliance is patched deliberately, and
on a disconnected network that upgrade hangs first boot.

To move to a newer provider release, change the version in `versions.tf`
and refresh the checksums for every platform the module is run from:

```
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
```

`tests/terraform/validate.sh` checks formatting, the pins, the lock file
and that site files stay out of git.

## Deploy by hand

Without Terraform, do the same four steps in the Proxmox interface or with
`qm` on the node:

```
qm clone <template-id> <new-id> --name <name> --full 1 --pool <pool>
qm set <new-id> --ciuser safbox --sshkeys <your-key>.pub --ipconfig0 ip=dhcp --ciupgrade 0
qm start <new-id>
qm guest cmd <new-id> network-get-interfaces    # the address, once the guest agent runs
```

Make a full clone (a linked clone ties the box to the template), keep the
cloud-init drive the template carries, and set `--ciupgrade 0` (Proxmox
VE 8.1 and later) for the reason above. The VM's name becomes the host
name, which the first-boot certificate names. `scripts/clone-and-ssh.sh`
does the same through the API with a token, and then runs the release
gate against the clone.

## First boot and first login

On its first boot the box runs cloud-init (your user, key, network and
host name), creates fresh SSH host keys and machine identity, and runs
`safbox-firstboot` once: it generates each service's secrets and the TLS
certificate, after which the services start. Then log in:

```
ssh safbox@<address>
safbox status        # distribution, FIPS mode, first boot, tool versions, build record
safbox services      # each service and the units behind it
```

Your cloud-init user is the only account that can log in: by key, over
SSH, with `sudo`. There is no password login and no default account. The
login banner is a SAFBox placeholder; see "Site settings".

`safbox services` reports each service as running, starting, waiting
(first boot has not written what it needs), stopped or failed, and exits 0
only when all of them run. If a service stays failed, `journalctl -u
<unit>` shows why; if first boot failed, `journalctl -u
safbox-firstboot.service` does, and the next boot retries it.

## The landing page and the applications

Open `https://<address>/`. The page lists Heimdall, Vulcan and the proxy
with their status, refreshed every 30 seconds, and links to each
application on the address you used. It shows nothing secret, and the page
loads nothing but its own stylesheet.

Your browser warns on the first visit to each port, because the
certificate is self-signed for this box. Compare its SHA-256 fingerprint
with the one on the box before you accept it:

```
sudo openssl x509 -in /etc/safbox/tls/safbox.crt -noout -fingerprint -sha256
```

To stop the warnings, replace the certificate with one your organisation
issues (next section).

## Certificates

First boot writes a self-signed certificate (RSA 3072, SHA-256, valid 365
days) for the host name, `localhost` and every address the box had then:

| File | Owner and mode | Holds |
|---|---|---|
| `/etc/safbox/tls/safbox.crt` | root, 0644 | the certificate, PEM |
| `/etc/safbox/tls/safbox.key` | root, 0600 | its private key, PEM, unencrypted |

**Your own certificate.** Put your certificate (PEM, followed by any
intermediate certificates) and its unencrypted key in those two files,
with the owners and modes above, and restart the proxy:

```
sudo install -o root -g root -m 0644 server.crt /etc/safbox/tls/safbox.crt
sudo install -o root -g root -m 0600 server.key /etc/safbox/tls/safbox.key
sudo systemctl restart safbox-proxy.service
```

The key must be one the FIPS policy accepts (RSA 2048 bits or more, or
ECDSA on P-256 or P-384). Nothing ever overwrites the files: first boot
keeps an existing pair. Name every host name and address users will type
in the certificate.

**Regenerate the self-signed one** after the box's name or address
changes: delete both files, run `sudo /etc/safbox/firstboot.d/40-proxy.sh`,
and restart the proxy.

## Heimdall's administrator

Heimdall creates an administrator, `admin@heimdall.local`, with a random
password on its first start, and prints the password to its log:

```
sudo journalctl -u heimdall.service | grep 'New administrator password'
```

Log in with it at `https://<address>:8443/` and change it; Heimdall makes
you. Until then, anyone who can read the journal can read it, and it stays
in the persistent journal until the journal rotates it out. This is a
known weakness that SAFBox has yet to fix. Read and rotate the password
soon after deployment, and keep journal access to administrators: on
SAFBox the journal is readable by root and the `systemd-journal`, `adm`
and `wheel` groups, and the cloud-init user is in `adm` and
`systemd-journal`.

Anyone who can reach port 8443 can register a Heimdall account. Heimdall
turns that off with its `REGISTRATION_DISABLED` setting, which SAFBox does
not expose yet; if open registration is not acceptable, limit who can
reach port 8443 until it does.

## Vulcan's first user

In Vulcan the first account registered becomes its administrator. Register
yours at `https://<address>:9443/` before anyone else can reach the box.
Local login and registration are on; OIDC, LDAP and SMTP are site settings
of the vulcan role (`vulcan_settings` in its defaults), applied when you
rebuild or re-run the role.

## Site settings

These are rebuild settings: set them in `ansible/local.yml` and build a
new template, or apply the playbook to the running box from a workstation
(rebuild.md, "Applying the roles to a box that has already booted") with
your cloud-init user, which has `sudo`:

```
ansible-playbook -i <address>, -u safbox --private-key <your-key> \
  ansible/playbooks/safbox.yml -e @ansible/local.yml
```

- **Remote log server.** SAFBox forwards no logs by default, and the
  STIG's remote-logging requirement (SV-280985) is a documented
  deploy-time deviation until you name a server: set
  `safbox_remote_log_server` (and `safbox_remote_log_port`,
  `safbox_remote_log_protocol`, `tcp` or `udp`). The hardening then
  writes `/etc/rsyslog.d/99-forwarding.conf` for it. For your own scans,
  set the STIG overlay's `remote_log_server` input to the same server in a
  site inputs file (rebuild.md, "Site inputs and thresholds").
- **Login banner.** Set `safbox_logon_banner` to your notice, and the
  overlay's banner inputs to the same text.
- **Firewall.** The box's firewalld zone (`drop` on a hardened image)
  allows the services in `safbox_firewall_services` (`ssh`) and the
  proxy's ports. DNS and NTP are not in it: the box is their client, and
  replies to its own queries are allowed as related traffic. If your
  network hands out IPv6 addresses by DHCPv6, add `dhcpv6-client`.
- **USB devices** are blocked by USBGuard until you allow them; see
  [deviations.md](deviations.md#settings-a-site-will-want-to-know-about).

## Security state

SAFBox is hardened to the DISA RHEL 10 STIG with the Ansible Lockdown role
and checked with the MITRE STIG baseline. It aims for a documented security
state, not a clean report:

- [deviations.md](deviations.md) lists the requirements SAFBox
  deliberately does not apply, each with its justification; the rules
  whose Lockdown task fails and are left off; known defects of the
  baseline; and every STIG requirement that still fails on a deployed
  box, with whether it is a known defect, a failed task, or not yet
  triaged.
- Known weaknesses of SAFBox itself are recorded as low-severity failing
  checks in its validation profile, never hidden: crypto that bypasses a
  FIPS provider (below).

To scan your box yourself, run the release gate from a workstation
(rebuild.md, "Prove the template"), or run the CINC Auditor and SAF CLI
on the box against the STIG baseline.

## FIPS

Every Rocky Linux SAFBox runs in FIPS mode from installation: the kernel
and the system crypto policy enforce FIPS-approved algorithms, and FIPS
mode cannot be turned off. Per component:

| Component | Cryptography | Status |
|---|---|---|
| Operating system, OpenSSH, system OpenSSL | the host's OpenSSL FIPS provider, FIPS crypto policy | FIPS mode enforced |
| TLS proxy (nginx, Red Hat UBI 9 image) | the image's OpenSSL with its FIPS provider active, the host's FIPS policy | TLS 1.2 and 1.3 with approved suites only |
| Heimdall (UBI 9 image) | the image's OpenSSL with its FIPS provider active | **finding:** passwords and API keys are hashed with bcrypt in pure JavaScript, outside any FIPS provider |
| Vulcan (UBI 9 image) | the image's OpenSSL with its FIPS provider active | FIPS provider in use |
| PostgreSQL for Heimdall and for Vulcan (upstream images) | the image's OpenSSL, which has no FIPS provider | **finding** for each |
| SAF CLI | the distribution's Node.js on the system OpenSSL | FIPS provider in use |
| Ansible | the distribution's Python on the system OpenSSL | FIPS provider in use |
| CINC Auditor | its own embedded OpenSSL | **finding:** bypasses the system FIPS provider |
| Packer | Go's own crypto, statically linked | **finding:** bypasses the system FIPS provider |

The containers' FIPS module is the RHEL 9 one inside each image, not the
host's RHEL 10 module; their crypto follows the host's FIPS policy, which
podman passes into them. Each finding is a low-severity check that fails
in the validation results on purpose (`safbox-heimdall-4`,
`safbox-heimdall-5`, `safbox-vulcan-4`, and the FIPS exercise's
`safbox-fips-provider-1` and `-4`).

**Rocky Linux's FIPS modules are not certified.** Rocky in FIPS mode
enforces the approved algorithms, but its cryptographic modules hold no
FIPS 140-3 certificate of their own; validated modules for Rocky are a
paid offering. If you need a certificate, deploy the same appliance layer
(the Ansible playbook) on Red Hat Enterprise Linux. Images built from the
AlmaLinux development base are development artifacts and make no claim
either way.

## Data at rest

SAFBox does not encrypt its own disk: a template that boots unattended
would share its key with every copy. The STIG's data-at-rest requirement
is a documented deviation on that basis; protect the box's storage at the
layer beneath it (an encrypted datastore, storage array or volume).
