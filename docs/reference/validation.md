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
| `verify/profiles/safbox-rhel10-stig-overlay` | on the box, over SSH | the pinned MITRE RHEL 10 STIG baseline, with SAFBox's deviations marked Not Applicable |
| `verify/profiles/safbox-client` | on your workstation (`-t local://`), release gate only | the box from another machine, through its TLS proxy: the proxy's TLS, each application's page with its scripts and stylesheets, that only the proxy's ports answer, plain HTTP redirected, and each application's sign-in and main use, Keycloak single sign-on included |

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
VM) is Not Applicable and does not count. Pin changes in
`ansible/group_vars/all/main.yml` need the matching input default changed
too.

The overlay fetches its pinned baseline from GitHub on each scan, so the
workstation needs network access.

`verify/profiles/safbox-client` checks what only another machine can see.
Its checks are curl and `openssl s_client` (OpenSSL 3) in `command`
resources, `json` for the answers and `host` for the ports, in
`controls/proxy.rb`, `heimdall.rb`, `vulcan.rb` and `keycloak.rb`; a small
library, `libraries/safbox_client.rb`, builds their command lines. It sends
each name the proxy serves to the box's address itself (`curl --resolve`,
`openssl s_client -servername`), so your workstation needs no DNS or hosts
entry, and it trusts only the certificate the box serves. Each multi-step
flow, such as the Vulcan administrator's sign-in with its CSRF token, then
a new project, is one control whose steps run in order in one session
(cookie jar). Its inputs are the box's `address`, the `domain` and
`expected_services` it shares with the safbox profile, a `work_dir` (an
empty 0700 directory the caller makes and removes), an HDF file to upload
to Heimdall (`hdf_file`), and the passwords first boot generated
(`heimdall_admin_password`, `vulcan_admin_password`,
`keycloak_safuser_password`), which are sensitive: CINC Auditor masks them
in its reports, and the controls pass them to curl in files readable by
you only, never on a command line. The profile signs in, uploads to
Heimdall, creates a Vulcan project and accounts, and changes `safuser`'s
Keycloak password, so it runs against a clone, never an appliance in use.

With the input `read_only` true (`validate.sh --client-read-only`, which
`scripts/clone-and-ssh.sh --keep` passes for a clone kept for a person)
the profile changes no account, password or data on the box. The
controls that would are skipped, each reported as skipped with the
reason, in the gate's output and in the results file (status skipped,
its `skip_message`), never left out:

| Skipped when `read_only` | Why |
|---|---|
| `safbox-client-heimdall-2` | logs in as Heimdall's administrator and uploads an evaluation |
| `safbox-client-vulcan-2` | its sign-up makes a Vulcan account (an accepted deviation, impact 0.0) |
| `safbox-client-vulcan-3` | signs in as Vulcan's administrator and creates a project |
| `safbox-client-keycloak-2` | takes `safuser`'s first Keycloak sign-in and completes its forced password change (so whether `safuser` sees the build scans is not checked either) |
| `safbox-client-keycloak-3` | signs `safuser` in to Vulcan, which makes its Vulcan account, with the password keycloak-2 gives it |
| `safbox-client-keycloak-4` | changes `safuser`'s password in the account console |
| `safbox-client-keycloak-5` | needs the password keycloak-2 gave `safuser`; its refused sign-ins count towards a lockout |

The others (`safbox-client-proxy-1` to `-3`, `heimdall-1`, `vulcan-1`
and `keycloak-1`) only fetch pages and probe TLS and ports, and run as
usual. So on a kept clone `safuser`'s Keycloak password is still the one
first boot generated, its first sign-in still asks for a new password
(the required action `UPDATE_PASSWORD`), and the person the clone is kept
for sees that flow. The skipped controls are proved by the full gate on a
clone that is not kept, the combined build's included.

A deviation SAFBox accepts is recorded in the profile that checks it, as
in the overlay: the control keeps its check, its impact is 0.0 (Not
Applicable, so it does not count) and a `justification` says why. In the
client profile, `safbox-client-vulcan-2` (Vulcan refuses a sign-up with
registration off) is one: Vulcan 2.4.1 accepts the sign-up, a known
upstream defect. Its result stays in the report.

## `scripts/validate.sh`

```
scripts/validate.sh [--site-inputs FILE] [--ssh-config FILE] [--results-dir DIR] \
  [--client-inputs FILE [--client-read-only]] <user@host[:port]> <private-key> <build|release> [label]
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
Heimdall"). `safbox-heimdall-8` checks that Heimdall stores each one as
HDF, with the source file's profiles and as many controls in each.

In the `release` context, `--client-inputs FILE` also runs the client
profile from your workstation against the target's host and checks it
against `client-release.yml`; it uploads the safbox profile's results to
Heimdall. When the box imported the template's build-gate scans
(`safbox-heimdall-8` ran), `safbox-client-keycloak-2` also checks that
`safuser`, once signed in, sees each one as a public evaluation tagged
with its build run (the STIG overlay's also `STIG`), and that each one's
content, fetched as `safuser`, is HDF: its fields, its profiles and their
controls, not the uploaded text Heimdall keeps when it cannot parse it.
It finds their names in the safbox profile's results.

FILE is a `.yml` (or `.yaml`) inputs file of mode 0600 with the box's passwords;
the clone test writes one from the clone and removes it afterwards. To run
it by hand against a clone, make the file readable by you only
(`install -m 600 /dev/null FILE`), put each password in it with an editor,
read on the box with `sudo podman secret inspect --showsecret` (see
[Services on the box](services.md), "Accounts"), and pass the file (never a password with
`--input`, which other users can see in the process list):

```
---
heimdall_admin_password: '<the heimdall-admin-password secret>'
vulcan_admin_password: '<the vulcan-admin-password secret>'
keycloak_safuser_password: '<the keycloak-safuser-password secret>'
```

```
scripts/validate.sh --client-inputs FILE admin@<clone-address> <private-key> release
```

With `--client-read-only` as well, the client profile runs with
`read_only` true and is held to `client-release-read-only.yml`; it then
changes no account, password or data on the box either, and leaves
`safuser`'s first Keycloak sign-in for a person. `validate.sh` says so
before the client scan, and each skipped control is listed as skipped
with its reason. `--client-read-only` without `--client-inputs` is refused.

Without `--client-inputs`, `validate.sh` changes nothing on the box.

## The thresholds

`verify/thresholds/` holds six short SAF CLI threshold files, written by
hand, one per profile and context:

- `safbox-build.yml` and `safbox-release.yml`, for the safbox profile: no
  failed controls and no errors. Every control that applies, on the build
  VM or on a deployed clone, must pass.
- `stig-build.yml` and `stig-release.yml`, for the overlay: a compliance
  percentage taken from a real scan in that context, rounded down, at most
  4 failed CAT I (high) controls, the four that fail today, and no errors.
  The build VM has not rebooted since hardening, so some settings apply
  only on a clone and the build percentage is lower.
- `client-release.yml`, for the client profile on a clone: no failed
  controls, no errors and no skipped (Not Reviewed) controls, so a
  read-only run never passes as the full gate. A switched-off service's
  controls and the accepted deviations are Not Applicable and do not
  count.
- `client-release-read-only.yml`, for the client profile on a kept clone
  (`read_only`): no failed controls and no errors, and at most six
  skipped, the six state-changing controls of impact 1.0 above. Every
  other control that applies must run and pass, as in the full gate.

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
