# Tools on the box

The `template_tools` role installs each tool at the version pinned in
`ansible/group_vars/all/main.yml`; `safbox status` on the box prints them.
To change a pin, update the version there (and, for a downloaded
artifact, its sha256), and
the matching expected-version input in
`verify/inputs/pins.yml`. A site that overrides a pin in `ansible/local.yml` sets
the matching input in its site inputs file, for example
`packer_version: <version>`. CINC Auditor's control compares the version
only, so a different build of the same version (the el9 release on
x86-64-v2 hardware) needs no input. The SAF CLI and its dependencies
install from a committed npm lockfile, and each Ansible collection from
its git repository at the commit its release tag names.

FIPS is not a toggle, so every tool must work under FIPS enforcement. After
changing a tool, try it on a FIPS-mode build VM or clone. Known gaps: CINC
Auditor carries its own OpenSSL and Packer uses Go's crypto, neither through
the system FIPS provider.

One known failure: under FIPS enforcement,
`saf convert jfrog_xray2hdf` fails on a JFrog Xray report in which any
finding's `id` is empty. The converter (`@mitre/hdf-converters` 2.14.0,
bundled in SAF CLI 1.7.0) makes such a finding's control ID from an MD5
hash of its summary, and Node.js refuses MD5 in FIPS mode
(`ERR_OSSL_EVP_UNSUPPORTED`). The SAF CLI prints the error, writes no
output file, and still exits 0, so check that the output file exists.
Reports in which every finding has an `id` convert normally. Re-enabling
MD5 for Node.js would take the tool out of FIPS mode, so the box offers
no workaround: convert such a report on a host without FIPS enforcement
until the converter is fixed upstream. Heimdall's upload is not affected:
it converts the report in the browser, not on the box.

## Fetching a profile or a hardening role

The box ships the tools, not the content they run: no STIG profiles and
no Lockdown roles are installed. Fetch the one you need, pinned to a
release, and run it from the box. For example, to scan a RHEL 9 host
against MITRE's RHEL 9 STIG baseline and then harden it with Ansible
Lockdown's RHEL 9 STIG role (replace `<tag>` with the release you want):

```
git clone --branch <tag> https://github.com/mitre/redhat-enterprise-linux-9-stig-baseline
cinc-auditor exec redhat-enterprise-linux-9-stig-baseline -t ssh://<user>@<host> -i <key> --sudo \
  --reporter cli json:rhel9-stig.json
ansible-galaxy role install -p roles git+https://github.com/ansible-lockdown/RHEL9-STIG.git,<tag>
```

Upload `rhel9-stig.json` to Heimdall to see the results. The role installs
into `roles/`; run it from a playbook that names it, against the same host.
