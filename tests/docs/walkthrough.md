# Guide walkthrough checklist

A manual check that a stranger can follow [docs/deploy.md](../../docs/deploy.md)
and [docs/rebuild.md](../../docs/rebuild.md) as written (ADR-0001 Phase 8:
both guides complete enough for a stranger to deploy and to rebuild). Run it
before a release, on a fresh clone and a fresh checkout, following only the
guides; anything you had to know that a guide does not say is a failure of
the guide. Record the results (date, commit, template, which items passed,
what you had to work around) in the release's ticket, not in this file:
results name hosts and IDs that do not belong in the repository.

## Deploy guide

### Terraform

- [ ] `deploy/terraform/proxmox/example.tfvars` copies to `terraform.tfvars`
      and every value it asks for is explained by a variable description.
- [ ] The credential exports in "Deploy with Terraform" work as written
      from the build's env file; nothing secret lands in a file in the
      repository.
- [ ] `terraform init` and `terraform apply` succeed with the build
      guide's least-privilege token; `apply` prints `address`,
      `landing_page`, `ssh` and `vm_id`.
- [ ] The clone keeps the template's firmware: UEFI, Secure Boot on
      (`mokutil --sb-state` on the box), and no package upgrade ran on
      first boot.
- [ ] `terraform destroy` removes the VM and its disks.

### By hand

- [ ] The `qm` steps in "Deploy by hand" produce a box that behaves as the
      Terraform one does (or `scripts/clone-and-ssh.sh` does).

### First boot and login

- [ ] `ssh <user>@<address>` with the key given to cloud-init logs in;
      password login is refused; the banner shows.
- [ ] `safbox status` shows FIPS mode enabled and first boot completed.
- [ ] `safbox services` shows every service running and exits 0.

### Landing page and applications

- [ ] `https://<address>/` shows each service Running and links to
      Heimdall and Vulcan on the address used.
- [ ] The certificate fingerprint command matches what the browser shows.
- [ ] `tests/services/landing.sh <address>` passes.

### Certificates

- [ ] Replacing `/etc/safbox/tls/safbox.crt` and `safbox.key` with a
      certificate from a test CA, as the guide says, and restarting the
      proxy serves the new certificate on 443, 8443 and 9443.
- [ ] Deleting both files, running the first-boot hook and restarting
      the proxy brings back a self-signed certificate.

### Accounts

- [ ] The journal command in "Heimdall's administrator" prints the seeded
      password; logging in with it forces a password change.
- [ ] The first account registered in Vulcan is an administrator.

### Site settings and security state

- [ ] Setting `safbox_remote_log_server` and applying the playbook to the
      running box writes `/etc/rsyslog.d/99-forwarding.conf` for that
      server.
- [ ] Every link in "Security state" and "FIPS" resolves; the findings
      named there match the release scan's failing low controls.
- [ ] `sudo firewall-cmd --list-all` on the box shows only `ssh` and the
      ports 443, 8443 and 9443.

## Rebuild guide

- [ ] From a fresh checkout, "Workstation prerequisites" lists every tool
      the static suite and the build need; the static suite in "Release a
      template" step 1 passes.
- [ ] Following "Hypervisor prerequisites" (the Proxmox guide) and "Site
      variables" alone, `scripts/build.sh` builds a sealed template.
- [ ] "Prove the template" passes against it.
- [ ] "A reduced build without Vulcan" builds and passes its release gate
      with the site files exactly as the guide describes them.
- [ ] `tests/ansible/idempotence.sh` passes against a build VM or clone.
