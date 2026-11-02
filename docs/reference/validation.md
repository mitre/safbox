# How SAFBox is validated

## How a build is validated

Three checks, at three moments:

1. **During the build**, before the seal, `scripts/validate.sh` scans the
   build VM from your workstation over SSH in the `build` context, and the
   SAF CLI thresholds decide whether the build continues. Nothing is
   installed on the image for this check; its results go into the
   template afterwards, for each box's Heimdall (`--results-dir`, below).
2. **At the end of the seal**, the seal's own final script asserts that the
   build user, its sudo rule, host keys, machine identity, cloud-init
   instance state, installer residue, first-boot secrets, and build-VM
   network profiles are all gone. Nothing outside can log in afterwards, so
   the seal checks itself; any miss fails the build.
3. **Before publishing an image** (the release gate), a clone is booted and
   scanned from outside as `admin` in the `release` context, which
   also proves what only a first boot does: the secrets, the certificate and
   the running services. Then the client profile checks the clone from
   your workstation, as a browser there would: through the TLS proxy only.

## The profiles

Three InSpec profiles live in `verify/profiles/`, one for each place they
run from:

| Profile | Runs | Checks |
|---|---|---|
| `verify/profiles/safbox` | on the box, over SSH | the appliance itself: OS, FIPS mode, Secure Boot, accounts, the hardening record and the settings SAFBox applies itself (AIDE, Ctrl-Alt-Delete), the tools at their pinned versions, Heimdall, Vulcan and the TLS proxy, and on a clone the seal and first boot |
| `verify/profiles/safbox-rhel10-stig-overlay` | on the box, over SSH | the pinned MITRE RHEL 10 STIG baseline, with Not Applicable marked only where a control does not apply to SAFBox |
| `verify/profiles/safbox-client` | on your workstation (`-t local://`), release gate only | the box from another machine, through its TLS proxy: the proxy's TLS, that only the proxy's ports answer, plain HTTP redirected, and each application's page answering |

`verify/profiles/safbox` is plain InSpec: `package`, `service`, `port`,
`file`, `http`, `parse_config_file` and the like, one control per thing
an operator cares about, grouped in `os.rb`, `accounts.rb`, `hardening.rb`,
`tools.rb`, `services.rb` and `sealed.rb`. Its inputs, with defaults in its
`inspec.yml`, are what a site varies: which tools and services the image
ships (`expected_tools`, `expected_services`), the CA roots it trusts
(`trusted_roots`), the pinned versions, the drivers every initramfs must
carry (`initramfs_drivers`), and `deployed`, which is true on a
clone and false on the build VM (`verify/inputs/build.yml`). One input
comes from the install layer instead: `guest_agents`, the guest agents
the answer file installs keyed by the hypervisor each serves
(`packer/answerfiles/el10/guest-agents.yml`), which `scripts/validate.sh`
passes to every scan before any other inputs; `safbox-system-1` and
`safbox-guest-agent-1` check the one for the hypervisor
`systemd-detect-virt` reports, and every one's package and hardening
([Base image, disk and build host](platform.md#one-image-for-each-supported-hypervisor)). A control that
does not apply (a service switched off, a clone-only control on the build
VM) is Not Applicable and does not count. The pinned versions have no
default: their values are in `verify/inputs/pins.yml`, which
`scripts/validate.sh` passes to every scan, and a pin changed in
`ansible/group_vars/all/main.yml` is changed there too.

The overlay's baseline is pinned by commit. The first scan that needs that
commit clones it from GitHub into CINC Auditor's cache, and later scans use
the cached copy, so the workstation needs network access for the first
scan after the pin changes.

`verify/profiles/safbox-client` checks what only another machine can see,
in `controls/proxy.rb`, `heimdall.rb`, `vulcan.rb` and `keycloak.rb`: the
proxy's TLS with `openssl s_client` (OpenSSL 3), its ports with `host`,
and with `http` that plain HTTP is redirected and that Heimdall, Vulcan
and Keycloak each answer at their names. It sends each name to the box's
address itself (the TLS server name, the HTTP Host header), so your
workstation needs no DNS or hosts entry. Its inputs are the box's
`address` and the `domain` and `expected_services` it shares with the
safbox profile. It only reads: it signs in to nothing and changes nothing
on the box.

The proxy must refuse TLS 1.0, TLS 1.1 and ChaCha20-Poly1305, so the
client profile makes those offers and expects the box's TLS alert. A
workstation in FIPS mode (a RHEL-family one, say) would not make them by
default, so those probes pass `-propquery '?fips=no'` to `openssl s_client`,
which lets its OpenSSL use the non-FIPS algorithms it ships; on a
workstation not in FIPS mode (Ubuntu, WSL) it changes nothing. That needs
OpenSSL 3: macOS's LibreSSL `openssl` does not take the option. A probe
that never reaches the box, because the client would not make the offer
or the connection failed, is no verdict and fails the control.

Signing in is checked by hand, on a clone kept with
`scripts/clone-and-ssh.sh --keep`:

1. On the box, read `safuser`'s first Keycloak password:

   ```sh
   sudo podman secret inspect --showsecret --format '{{.SecretData}}' keycloak-safuser-password
   ```

2. In a browser, open `https://heimdall.<domain>/` and sign in through Keycloak as `safuser` with that password.
3. Keycloak asks for a new password; set one.
4. Heimdall opens, signed in as `safuser`.
5. Open `https://vulcan.<domain>/` and sign in through Keycloak: Vulcan opens without asking for the password again.

## `scripts/validate.sh`

```
scripts/validate.sh [--site-inputs FILE] [--ssh-config FILE] [--results-dir DIR] \
  [--client] <user@host[:port]> <private-key> <build|release> [label]
```

It scans the box with the safbox profile and the overlay and checks each
against its threshold. Results land in
`.build/validate-<label>-<profile>-<timestamp>.json`, readable in
Heimdall. `--site-inputs` is layered after the context's inputs (its values
win); `--ssh-config /dev/null` stops CINC Auditor reading an SSH client
config it cannot use.

`--results-dir DIR` also keeps the box profiles' results, the safbox
profile's and the overlay's, as `DIR/safbox.json` and
`DIR/safbox-rhel10-stig-overlay.json`. Each file's modification time is
the time its scan ended. DIR is made if it is missing, readable by you
only. The client profile's results are not kept there. `scripts/build.sh`
gives the build gate its run's `scans/` directory this way, and the seal
installs what the gate kept in the template. On each box,
`safbox-heimdall-scans.service` imports them into Heimdall as public
evaluations, tagged with the build run (the STIG overlay's also `STIG`).
It runs once, after first boot, when Heimdall answers its healthcheck
([Services on the box](services.md), "The template's own scan results in
Heimdall").

In the `release` context, `--client` also runs the client profile from
your workstation against the target's host and checks it against
`client-release.yml`. `validate.sh` changes nothing on the box.

## The thresholds

`verify/thresholds/` holds five short SAF CLI threshold files, written by
hand, one per profile and context:

- `safbox-build.yml` and `safbox-release.yml`, for the safbox profile: no
  failed controls and no errors. Every control that applies, on the build
  VM or on a deployed clone, must pass.
- `stig-build.yml` and `stig-release.yml`, for the overlay: a compliance
  percentage taken from a real scan in that context, rounded down, a cap on
  failed CAT I (high) controls equal to the known CAT I failures, and no
  errors. The known failures are listed in [Hardening](hardening.md#known-failures).
  The build VM has not rebooted since hardening, so some settings apply
  only on a clone and the build percentage is lower.
- `client-release.yml`, for the client profile on a clone: no failed,
  skipped or errored controls. A switched-off service's controls are Not
  Applicable and do not count.

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
