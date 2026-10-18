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

### Service status

Open Heimdall and Vulcan from here: each name links to its application.

<ServiceStatus />

### Signing in

Heimdall and Vulcan share one sign-in: choose **SAFBox** on either
application's sign-in page and sign in as `safuser` with its Keycloak
password, which your administrator reads on the box
([Accounts](/reference/accounts)). Change it from the Keycloak bookmark.
Heimdall refuses self-registration. Vulcan 2.4.1 still accepts it from
anyone who can reach it, although registration is set off (an upstream
defect); such an account is a separate local one, not your SAFBox
sign-in.

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

### More

- [Building SAFBox on Proxmox VE](/guides/proxmox/build): the build, step by step.
- [Services on the box](/reference/services): the names, the certificate, and how to reach the apps from another machine.
- [STIG hardening](/reference/hardening): what is hardened and what deviates, and why.
- [saf.mitre.org](https://saf.mitre.org): the SAF project, its tools and training.
