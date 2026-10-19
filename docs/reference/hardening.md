# STIG hardening

The `hardening` role is the last role of the appliance play. It applies the
DISA RHEL 10 STIG with the Ansible Lockdown RHEL10-STIG role, pinned in
`ansible/group_vars/all/main.yml` (`safbox_hardening_lockdown`: release,
the commit its tag names, and the STIG release) and installed on the build
runner from `ansible/requirements.yml` by that commit. The build installs it
itself; to run the playbook by hand, install it first from the `ansible/`
directory:

```
ansible-galaxy install -r requirements.yml   # roles go to ansible/galaxy_roles/ (git-ignored)
```

The role refuses to run if another version of the Lockdown role is
installed.

**The deviation record is the STIG overlay.** Each requirement SAFBox
deliberately does not apply is a Not Applicable override, with its
justification, in
`verify/profiles/safbox-rhel10-stig-overlay/controls/overlay.rb`; a scan's
results carry the same text, readable in Heimdall. The hardening role
switches the matching Lockdown rule off in the Lockdown section of
`ansible/group_vars/all/main.yml`, one `rhel10stig_<n>: false` per
line with a one-line comment, where the rule would undo the deviation:
SV-281170 (admin is exempt from password ageing) has no switch, because
its rule, RHEL-10-600110, cannot touch `admin`, which first boot makes
with a locked password. A few lines there are not deviations: their
Lockdown task fails on SAFBox, so the rule is off, and the baseline control
still runs and reports what it finds. Two are off because their tasks
would damage SAFBox. RHEL-10-400290 (SV-281075, every file has a valid owner)
gives root every file whose owner is not in `/etc/passwd`, and on SAFBox
those are the container image layers under `/var/lib/containers`, owned
by users that exist only inside each image. Given root, the images break
(PostgreSQL refuses a data directory it does not own), and the task takes
hours, one file at a time. The requirement is applicable and is not a
deviation; SAFBox has no hardening for it yet (safbox-m5f.63), and
the baseline control still runs. RHEL-10-400285 (SV-281074, every file
has a valid group owner) runs only with `rhel10stig_disruption_high` (see
[Lockdown's disruptive changes](#lockdowns-disruptive-changes)). Its task
looks for files whose group is not root (`find / -xdev -type f ! -group
root`) rather than files whose group does not exist (`-nogroup`), and
gives every one group root. Changing a file's group clears its setgid
bit, so `write`, `postdrop`, `postqueue`, `postlog` and `utempter` lose
the group they run as (`rpm -V` reports `.M....G..`), and the sssd
helpers and `/etc/fapolicyd` files are regrouped. The requirement is
applicable and is not a deviation: no file on SAFBox lacks a valid group,
and the baseline control, which still runs, passes. To add a deviation,
add the override to the overlay and the switch to group_vars; every new
deviation is an owner decision.

**Account lockout is applied by SAFBox.** Lockdown puts pam_faillock in
the PAM stacks (RHEL-10-600600 and 600610) and holds a lock until an
administrator releases it (RHEL-10-600425) only when
`rhel10stig_disruption_high` is on. The hardening role applies those three
itself, before Lockdown runs, so they hold whichever way a site sets
`rhel10stig_disruption_high`: it selects its authselect profile with the
`with-faillock` feature (see [Settings SAFBox applies
itself](#settings-safbox-applies-itself)) and sets `unlock_time = 0` in `/etc/security/faillock.conf`;
Lockdown sets the rest of that file (three failures in 15 minutes).
`rhel10stig_uses_authselect: true` tells Lockdown that authselect makes
the stacks, so RHEL-10-600600 and 600610 only check that `with-faillock`
is enabled. Lockdown's default (`false`) would have them edit
`/etc/pam.d/system-auth` and `password-auth`, which authselect made,
directly, adding a second `pam_faillock.so preauth` line to each. Their
baseline controls (SV-281212, SV-281213) pass on the stacks authselect
writes. Root is not locked (SV-281195, a deviation in the
overlay). `admin` logs in with a key and has passwordless sudo, neither of
which checks a password, so a lock never shuts it out, and it releases a
locked account with `sudo faillock --user <name> --reset`; see
[Accounts](accounts.md).

Lockdown's own variables are the knobs for everything else: set any
`rhel10stig_*` value in `ansible/local.yml` (a rule switch to `false`, a
banner text, a time server). Two of them SAFBox sets to describe the box:
`rhel10stig_system_uses_ipv6: true`, because the box runs the IPv6 stack
and Lockdown applies its IPv6 network rules (RHEL-10-800230 to 800280)
only when told so, and `rhel10stig_pam_rounds: '100000'`, the STIG's
minimum hashing rounds for `pam_unix` (RHEL-10-600720, and SAFBox's
authselect profile below), where Lockdown's default is 5000. Hardening
does not reboot the build VM, because a reboot would run the first-boot
unit inside the template; kernel arguments and some other settings take
effect when a clone first boots, so the build STIG threshold is lower than
the release one.

Known upstream defect: the pinned Lockdown release ends every run with
`POST | Warning a reboot required but skip option set`, a task marked
`changed_when: true`, so a second playbook run reports `changed=1`.
`tests/ansible/idempotence.sh` tolerates exactly that task, matched by its
name; any other change fails the check. The tolerance goes when a fixed
Lockdown release is pinned.

Known failure from the Vulcan image: SV-281045 (RHEL-10-400140,
world-writable directories must be owned by a system account) fails on
every SAFBox that ships Vulcan, and passes without it. The baseline runs
`find <every /etc/fstab mount point> -xdev -type d -perm -0002 -uid +999`,
and podman keeps image layers in `/var/lib/containers/storage` on `/var`,
so directories inside a pulled image are scanned like any host directory.
The pinned `mitre/vulcan` 2.4.1 image ships four gem directories with mode
0777, owned by uid 1000, all in the layer its `COPY /usr/local /usr/local`
step creates:

```
/usr/local/bundle/ruby/3.4.0/gems/faraday-2.14.3/spec/faraday/adapter
/usr/local/bundle/ruby/3.4.0/gems/fuzzyurl-0.9.0/lib/fuzzyurl
/usr/local/bundle/ruby/3.4.0/gems/globalid-1.4.0/lib/global_id/uri
/usr/local/bundle/ruby/3.4.0/gems/reline-0.7.0/lib/reline/io
```

On the box they appear as
`/var/lib/containers/storage/overlay/<layer>/diff/usr/local/bundle/...`.
The gem archives are not the cause: none of them contains a directory
entry, and every file in them is 0644. The cause is a race during the
image build's `bundle install`. Bundler installs gems in parallel threads;
RubyGems reads the umask with `File.umask` for every file it extracts, and
Ruby implements that read as `umask(0)` followed by restoring the old
value, so for an instant the whole process has umask 0. A directory
another thread creates in that instant gets mode 0777, and nothing in the
image build removes the other-write bit afterwards. Which directories are
hit varies from build to build (Vulcan's next release, 2.4.2, has two
different ones), so the fix belongs in the image build, not in any gem.
Changing modes inside `/var/lib/containers/storage` is not a fix: it alters
pulled layers behind podman's back, so the digest no longer describes what
runs.

The login banner is a site setting: SAFBox ships "Welcome to SAFBox!", a
greeting rather than a legal notice, since it cannot know whether a site
monitors the box (`safbox_logon_banner` in
`ansible/group_vars/all/main.yml`). It is not the DoD Notice and Consent
Banner the STIG requires; the STIG banner controls check for SAFBox's text
instead of the DoD notice. A site that needs a notice, a DoD site included,
sets its own text there in `ansible/local.yml`, and the same text for the
STIG overlay's `banner_message_text_cli`, `_ral` and `_gui` inputs in its
site inputs file.

Remote logging is off by default: `safbox_remote_log_server` is empty, the
hardening role switches off the forwarding rules (RHEL-10-200642, and
RHEL-10-200646, which writes the same forwarding file when
`rhel10stig_disruption_high` is on), and the
overlay marks SV-280985 (forwarding) and SV-280989 (forwarding over TLS)
Not Applicable as deploy-time deviations. A site
that has a log server sets `safbox_remote_log_server` (and, if needed,
`safbox_remote_log_port` and `safbox_remote_log_protocol`, tcp or udp) in
`ansible/local.yml`, and the overlay input `remote_log_server` to the same
server in its site inputs file. The hardening then writes
`/etc/rsyslog.d/99-forwarding.conf` for that server and SV-280985 is
evaluated.

USBGuard allows USB hubs and nothing else, so USB devices are blocked
until a site allows them (see [Settings SAFBox applies
itself](#settings-safbox-applies-itself)).

## Lockdown's disruptive changes

Lockdown marks some of its rules as disruptive. With
`rhel10stig_disruption_high: false` it only audits them and prints a
warning; with `true` it applies them as well. The setting is in the
Lockdown section of `ansible/group_vars/all/main.yml` and is on by
default. A site turns it off with `rhel10stig_disruption_high: false` in
`ansible/local.yml`; it must be a YAML boolean, so set it there, not with
`-e rhel10stig_disruption_high=false`, which passes the string `"false"`
and makes Lockdown's conditions fail. SAFBox switches off, or confines,
the disruptive rules that damage a fresh build:

| Rule | Switch | Why |
|---|---|---|
| RHEL-10-200646 (SV-280989) | on only with `safbox_remote_log_server`, like RHEL-10-200642 | with no log server it writes `/etc/rsyslog.d/99-forwarding.conf` with `target=""`; rsyslog suspends the action and `/var/log/messages` and `/var/log/secure` stop being written seconds after boot |
| RHEL-10-400285 (SV-281074) | off | strips setgid from system binaries (above) |
| RHEL-10-300010 (SV-281008) | follows `rhel10stig_disruption_high` | without it the task fails: it reads a fact it sets only with the setting on |

RHEL-10-600600 and 600610 stay on: with `rhel10stig_uses_authselect:
true` they only check authselect's `with-faillock` feature (above).

The control `safbox-logging-1` in the safbox profile checks that local
logging works: a message logged during the scan must reach
`/var/log/messages`, an authpriv one `/var/log/secure`, and no rsyslog
forwarding action may have an empty target.

**What it closes.** On a SAFBox build, nine STIG controls pass with it
that do not pass without it. Eight fail without it; SV-281223 is
skipped, because the file it checks, `/etc/libuser.conf`, exists only
once RHEL-10-600750 writes it:

| Control | Rule | Requirement |
|---|---|---|
| SV-281084 | RHEL-10-400335 | systemd-tmpfiles initialization files mode 0600 or less |
| SV-281097 | RHEL-10-500005 | auditing of processes that start before auditd (`audit=1`) |
| SV-281100 | RHEL-10-500020 | the user name logged on failed logins (faillock `audit`) |
| SV-281200 | RHEL-10-600455 | no blank or null passwords (`nullok` removed) |
| SV-281209 | RHEL-10-600540 | reauthentication for sudo |
| SV-281210 | RHEL-10-600550 | sudo asks for the invoking user's password |
| SV-281217 | RHEL-10-600720 | FIPS hashing for `pam_unix` in `password-auth` |
| SV-281222 | RHEL-10-600740 | the shadow file holds only encrypted passwords |
| SV-281223 | RHEL-10-600750 | account tools store only encrypted passwords |

**What it costs.**

- `safuser` types its password at every `sudo`: RHEL-10-600540 sets
  `Defaults timestamp_timeout=0`. `admin` is unaffected; its passwordless
  sudo stays (RHEL-10-600560 is off, a deviation in the overlay).
- A password can be changed at most once a day: RHEL-10-600210 sets
  `PASS_MIN_DAYS 1` in `/etc/login.defs`, and RHEL-10-600270 gives every
  existing account a one-day minimum. A user who has just changed a
  password needs an administrator (`sudo passwd <name>`) to change it
  again that day.
- RHEL-10-400280 (SV-281073) sets the sticky bit on world-writable
  directories. On SAFBox these are the four Vulcan gem directories
  described above, inside the image layers under
  `/var/lib/containers/storage`. Vulcan runs as before, so the rule stays
  on, but the change is made to pulled layers behind podman's back, the
  same caveat as changing their modes by hand. SV-281045, which checks
  their owner, still fails.

**On a later run against a deployed box.** The switches above make a
build safe. Some rules that change nothing on a fresh build act when the
playbook is run again against a box already in use. Three are off for that
reason:

- RHEL-10-600730 (SV-281221) is meant to lock every account whose
  password hash is not SHA-512 (`$6$`), but its filter, `grep -v '$6$'`,
  excludes nothing (a `$` that ends a pattern anchors it), so it locks
  every account with a usable password, SHA-512 or not: a run against a
  deployed box locked `safuser`. It is off, as "Lockdown task harmful";
  the baseline control still checks the stored hashes.
- RHEL-10-200562 (SV-280964) replaces the USBGuard rules with a policy
  generated from the USB devices attached at that moment once any rule
  exists, and SAFBox writes one (below), so it is off too.
- RHEL-10-800210 (SV-281353) sets IPv4 forwarding off; reloaded on a
  running box it turns forwarding off under the pods until the next boot.
  podman needs forwarding, so the rule is off and the control is Not
  Applicable in the overlay.

These stay on, because on a box in SAFBox's own state they change
nothing and none of them touches `admin`:

- RHEL-10-600110 and 600270 set the ageing of existing accounts that have
  a password (not `admin`'s, which is locked): at most 60 days, at least
  one. `safuser` already has both from `/etc/login.defs` when first boot
  creates it.
- RHEL-10-400230 removes and reinstalls cronie when the permissions of
  the cron files differ from the package's; on SAFBox they do not.

## Settings SAFBox applies itself

Where a Lockdown task fails or would do harm, its rule is switched off in
group_vars ("Lockdown task fails" or "harmful") and the hardening role
applies the requirement itself, after Lockdown, so the baseline control
still runs and checks the result:

- **Password hashing** (RHEL-10-600700, 600710, 600720; SV-281218 to
  SV-281220). The distribution's `local` authselect profile hashes with
  yescrypt. The role creates its own copy, `custom/safbox`, whose
  `pam_unix` password lines in `system-auth` and `password-auth` read
  `sha512 rounds=<rhel10stig_pam_rounds>` (100000), and selects it with
  the features already enabled plus `with-faillock`. First boot hashes
  the password it sets for `safuser` with the same rounds, read from
  `system-auth` (`chpasswd -s`); `SHA_CRYPT_MAX_ROUNDS` in
  `/etc/login.defs` is left unset, because with it `chpasswd` on EL10
  picks rounds up to 999999999, a hash that takes minutes to check.
  Existing hashes are untouched and still verify; each password is
  rehashed when it is next changed.
- **AIDE** (RHEL-10-200631 to 200635). Lockdown's `aide.conf` starts with
  `@define`, which AIDE rejects, so AIDE could not run at all. The role
  writes `/etc/aide.conf` (Lockdown's selection list, corrected, every
  group with acl, xattrs and sha512) and `/etc/cron.daily/aide`, an
  executable script anacron runs once a day that mails the report to
  root. The database must describe the deployed box, not the template:
  `safbox-aide-init.service` makes it once, after the first boot has
  configured the box, and the seal removes any database the build left.
  The safbox profile's `safbox-hardening-3` checks the configuration,
  the daily job and, on a clone, the database.
- **Ctrl-Alt-Delete** (RHEL-10-700950). Lockdown's drop-in has no `.conf`
  suffix, so systemd ignored it and pressing the keys seven times in two
  seconds still rebooted the box. The role writes
  `/etc/systemd/system.conf.d/55-safbox-ctrl-alt-del-burst.conf`;
  `safbox-hardening-4` checks the running setting, because the baseline
  control's check cannot match any file.
- **Bluetooth** (RHEL-10-700860). Lockdown's task blacklists
  `firewire-core` instead; the role writes
  `/etc/modprobe.d/safbox-bluetooth.conf`.
- **USBGuard** (RHEL-10-200562). Its implicit policy blocks every device
  that no rule allows. The role adds one rule,
  `/etc/usbguard/rules.d/50-safbox-hubs.conf`, allowing USB hubs alone
  (a single interface of class 09), so the rule list is not empty and
  keyboards, mice and storage stay blocked. The rule allows more than
  before, never less. On a clone of the headless template USBGuard lists
  only the USB host controllers and blocks nothing
  (`usbguard list-devices --blocked` is empty); a desktop build has not
  been checked here. A device the hypervisor presents over USB, such as
  a USB tablet for the console pointer, or one a site attaches, is
  blocked as it was before this rule, and a site allows it with its own
  rule in `/etc/usbguard/rules.d/`.
- **Immutable audit rules** (RHEL-10-900100). Lockdown writes `-e 2`
  commented out. The role writes `/etc/audit/rules.d/99-safbox-immutable.rules`
  (`-e 2`, which augenrules places last), loaded at boot by
  `audit-rules.service`. From then on the kernel refuses any change to
  the audit rules until the box reboots: a later playbook run that changes
  an audit rule writes it to `/etc/audit/rules.d/`, and it takes effect
  only at the next reboot (Lockdown reports that a reboot is required).
  Lockdown loads its rules during its own run (its audit tasks flush
  their handlers); the hardening role writes this file after that and does
  not load it, and the build VM is not rebooted, so the rules stay
  changeable through the build and the seal and become immutable at the
  clone's first boot.
- **Unneeded accounts** (RHEL-10-600450). The role removes `games` and
  `ftp`, which the distribution's `setup` package creates and SAFBox does
  not use; no file on the box belongs to either. The package declares
  them in `/usr/lib/sysusers.d/20-setup-users.conf`, and
  `systemd-sysusers` (on a boot after an update) and rpm (when it
  installs or updates `setup`) would create them again, so the role also
  writes `/etc/sysusers.d/20-setup-users.conf`, the package's file
  without those two entries, which replaces it. Their groups stay.
- **Dotfile modes of the first-boot accounts** (RHEL-10-400235). Lockdown
  applies the rule at build, before first boot makes `admin` and
  `safuser` from `/etc/skel`, whose files are 0644. A first-boot hook,
  `18-init-file-modes.sh`, gives the dotfiles of every interactive
  account 0740 or less once those accounts exist.

## The firewall zone

`safbox_firewall_zone` in `ansible/group_vars/all/main.yml` is the one
firewalld zone every role opens ports in: the platform role's base services
(group `safbox-platform-3`) and the proxy's HTTPS ports. With hardening on
it is `drop`, because Lockdown's rule RHEL-10-200532 (SV-280957, a
deny-all firewall) moves the network interface into Lockdown's zone and
makes it the default; `rhel10stig_custom_firewall_zone` is set from
`safbox_firewall_zone`, so the two cannot differ. With hardening off
(`safbox_hardening_1: false`) it is the distribution default, `public`.
A site that switches Lockdown's zone rule off (`rhel10stig_200532: false`)
while hardening stays on keeps the interface where it was, so it must also
set `safbox_firewall_zone` to that zone (usually `public`) in
`ansible/local.yml`; otherwise the proxy's ports open in a zone the
interface is not in.
