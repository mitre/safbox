---
layout: home

hero:
  name: SAFBox
  text: The MITRE Security Automation Framework in a box
  tagline: A hardened, FIPS-mode appliance with Heimdall, Vulcan and the SAF command-line tools, ready to use.
  image:
    src: /saf-logo.svg
    alt: The MITRE SAF shield
  actions:
    - theme: brand
      text: How to sign in
      link: "#how-to-sign-in-to-safbox-services"
    - theme: alt
      text: Service status
      link: "#service-status"
    - theme: alt
      text: Build your own
      link: /guides/proxmox/build

features:
  - title: Heimdall
    details: View, compare and share security scan results from InSpec, CINC Auditor and the many formats the SAF CLI converts.
  - title: Vulcan
    details: Write and manage security guidance, from a STIG or SRG to the InSpec profile that tests it.
  - title: The command-line tools
    details: CINC Auditor, the SAF CLI, Ansible with the Lockdown hardening content, and Packer, all installed and pinned.
    link: /reference/tools
---

## Welcome to SAFBox

SAFBox is a virtual machine that carries the
[MITRE Security Automation Framework](https://saf.mitre.org): the tools to
harden systems, test them against security guidance, and look at the
results, on a box that is itself hardened to the RHEL 10 STIG and runs in
FIPS mode. Everything here works without reaching the internet.

## Service status

Open Heimdall and Vulcan from here: each name links to its application.

<ServiceStatus />

## What is on the box

### Heimdall

Heimdall is where results go. Upload
the JSON a scan produces (or anything the SAF CLI converts into the
Heimdall Data Format) to see each requirement, what was tested and why it
passed or failed, filter and compare scans, and export reports. This
Heimdall keeps its data on the box.

### Vulcan

Vulcan is where guidance gets written.
Start from a DISA SRG or STIG, work through each requirement with your
team, and export the result as a STIG-ready document or the skeleton of an
InSpec profile that tests it.

### The tools on the command line

Log in over SSH (or at the console) and the SAF tools are on your path:

| Tool | Try |
|---|---|
| CINC Auditor (InSpec) | `cinc-auditor exec <profile> -t ssh://user@host --reporter json:results.json` scans a system against a profile |
| SAF CLI | `saf convert` turns other scanners' output into Heimdall Data Format; `saf view summary -i results.json` summarises a scan; `saf validate threshold` gates on it |
| Ansible | `ansible-playbook` with the Ansible Lockdown hardening content applies STIG settings to a host |
| Packer | builds machine images, the way this SAFBox was built |

Results you produce here can go straight into Heimdall.

### The `safbox` command

`safbox help` lists what the appliance itself can tell you, and
`safbox status` shows the box's tools and their versions, its services,
and whether FIPS mode is on.

## How to sign in to SAFBox services

**Heimdall and Vulcan sign in through Keycloak** (single sign-on). On
either application's sign-in page choose **SAFBox**, then sign in to
Keycloak as `safuser`.

**`safuser`'s first Keycloak password** is generated at first boot and
kept in a podman secret. To see the initial password, open a terminal and run:

```
sudo podman secret inspect --showsecret --format '{{.SecretData}}' keycloak-safuser-password
```

**Keycloak makes you choose a new password at the first sign-in** (at
least 15 characters, not the user name). The secret keeps only the first
one; later changes go through the Keycloak bookmark (the account page).

**The desktop and SSH password is a different one.** `safuser`'s
password for the desktop, the console and SSH is its operating-system
password, not its Keycloak one: the password whoever deployed the box
gave it in cloud-init (on Proxmox, the clone's **Password**), or, if they
gave none, the one first boot generated, which `admin` reads with
`sudo cat /etc/safbox/safuser.env`.

**`admin` is key-only.** It is the account for deploying and
administering the box: SSH with the key given at deployment, passwordless
sudo, no password at all, and it does not appear on the desktop's sign-in
screen.

**Heimdall's own administrator**, `admin@safbox.internal`, is a local
account for when Keycloak is down. Its password is the podman secret
`heimdall-admin-password` (Vulcan's is `vulcan-admin-password`), read the
same way as `admin`:

```
sudo podman secret inspect --showsecret --format '{{.SecretData}}' heimdall-admin-password
```

Heimdall asks for a new one at that account's first sign-in.

Heimdall refuses self-registration. Vulcan 2.4.1 still accepts it from
anyone who can reach it; such an account is a separate local one, not your SAFBox
sign-in.

More: [Services on the box](/reference/services) (the applications'
accounts and secrets), [Accounts](/reference/accounts#accounts-in-the-applications),
and the build guide's
[Accounts on a clone](/guides/proxmox/build#accounts-on-a-clone).

### More

- [Building SAFBox on Proxmox VE](/guides/proxmox/build): the build, step by step.
- [Services on the box](/reference/services): the names, the certificate, and how to reach the apps from another machine.
- [STIG hardening](/reference/hardening): what is hardened and what deviates, and why.
- [saf.mitre.org](https://saf.mitre.org): the SAF project, its tools and training.
