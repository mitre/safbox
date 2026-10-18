# How SAFBox is validated

## How a build is validated

Three checks, at three moments:

1. **During the build**, before the seal, `scripts/validate.sh` scans the
   build VM from your workstation over SSH in the `build` context, and the
   SAF CLI thresholds decide whether the build continues. Nothing is
   installed on the image for this.
2. **At the end of the seal**, the seal's own final script asserts that the
   build user, its sudo rule, host keys, machine identity, cloud-init
   instance state, installer residue, first-boot secrets, and build-VM
   network profiles are all gone. Nothing outside can log in afterwards, so
   the seal checks itself; any miss fails the build.
3. **Before publishing an image** (the release gate), a clone is booted and
   scanned from outside as `admin` in the `release` context, which
   also proves what only a first boot does: the secrets, the certificate and
   the running services.

## The profiles

Two InSpec profiles live in `verify/profiles/`:

| Profile | Checks |
|---|---|
| `verify/profiles/safbox` | the appliance itself: OS, FIPS mode, Secure Boot, accounts, the hardening record, the tools at their pinned versions, Heimdall, Vulcan and the TLS proxy, and on a clone the seal and first boot |
| `verify/profiles/safbox-rhel10-stig-overlay` | the pinned MITRE RHEL 10 STIG baseline, with SAFBox's deviations marked Not Applicable |

`verify/profiles/safbox` is plain InSpec: `package`, `service`, `port`,
`file`, `http`, `parse_config_file` and the like, one control per thing
an operator cares about, grouped in `os.rb`, `accounts.rb`, `hardening.rb`,
`tools.rb`, `services.rb` and `sealed.rb`. Its inputs, with defaults in its
`inspec.yml`, are what a site varies: which tools and services the image
ships (`expected_tools`, `expected_services`), the CA roots it trusts
(`trusted_roots`), the pinned versions, and `deployed`, which is true on a
clone and false on the build VM (`verify/inputs/build.yml`). A control that
does not apply (a service switched off, a clone-only control on the build
VM) is Not Applicable and does not count. Pin changes in
`ansible/group_vars/all/main.yml` need the matching input default changed
too.

The overlay fetches its pinned baseline from GitHub on each scan, so the
workstation needs network access.

## `scripts/validate.sh`

```
scripts/validate.sh [--site-inputs FILE] [--ssh-config FILE] \
  <user@host[:port]> <private-key> <build|release> [label]
```

It scans both profiles and checks each against its threshold. Results land
in `.build/validate-<label>-<profile>-<timestamp>.json`, readable in
Heimdall. `--site-inputs` is layered after the context's inputs (its values
win); `--ssh-config /dev/null` stops CINC Auditor reading an SSH client
config it cannot use.

## The thresholds

`verify/thresholds/` holds four short SAF CLI threshold files, written by
hand, one per profile and context:

- `safbox-build.yml` and `safbox-release.yml`, for the safbox profile: a
  cap on failed controls and no errors. Every control that applies on the
  build VM must pass. A deployed clone may fail at most 2, the two that
  fail on every image today (the Heimdall and Vulcan PostgreSQL images
  carry no OpenSSL FIPS provider), so a third failure fails the gate.
- `stig-build.yml` and `stig-release.yml`, for the overlay: a compliance
  percentage taken from a real scan in that context, rounded down, at most
  5 failed CAT I (high) controls, the five that fail today, and no errors.
  The build VM has not rebooted since hardening, so some settings apply
  only on a clone and the build percentage is lower.

A comment in each file says where its numbers came from. When the image
gets better, tighten them by hand from a new scan.

## Site inputs

A site that builds a different image than the repository default (a tool
or service switched off, a pin overridden) writes an inputs file in
`verify/local/`, which is git-ignored, for example
`verify/local/inputs.yml`:

```
---
expected_tools: [cinc-auditor, saf-cli, ansible]
```

and names it to the build in `packer/local.auto.pkrvars.hcl`
(`build_gate_site_inputs_file = "verify/local/inputs.yml"`) and to the
release gate with `SAFBOX_SITE_INPUTS`. The controls of a switched-off tool
or service become Not Applicable, so the thresholds need no change.
