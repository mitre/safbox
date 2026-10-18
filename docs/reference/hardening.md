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
still runs and reports what it finds. One is off because its task would
damage SAFBox: RHEL-10-400290 (SV-281075, every file has a valid owner)
gives root every file whose owner is not in `/etc/passwd`, and on SAFBox
those are the container image layers under `/var/lib/containers`, owned
by users that exist only inside each image. Given root, the images break
(PostgreSQL refuses a data directory it does not own), and the task takes
hours, one file at a time. The requirement is applicable and is not a
deviation; SAFBox has no hardening for it yet (safbox-m5f.63), and
the baseline control still runs. To add a deviation, add the override
to the overlay and the switch to group_vars; every new deviation is an
owner decision.

**Account lockout is applied by SAFBox.** Lockdown puts pam_faillock in
the PAM stacks (RHEL-10-600600 and 600610) and holds a lock until an
administrator releases it (RHEL-10-600425) only when
`rhel10stig_disruption_high` is on, which SAFBox leaves off. The hardening
role therefore applies those three itself, before Lockdown runs: it enables
authselect's `with-faillock` feature and sets `unlock_time = 0` in
`/etc/security/faillock.conf`; Lockdown sets the rest of that file (three
failures in 15 minutes). Root is not locked (SV-281195, a deviation in the
overlay). `admin` logs in with a key and has passwordless sudo, neither of
which checks a password, so a lock never shuts it out, and it releases a
locked account with `sudo faillock --user <name> --reset`; see
[Accounts](accounts.md).

Lockdown's own variables are the knobs for everything else: set any
`rhel10stig_*` value in `ansible/local.yml` (a rule switch to `false`, a
banner text, a time server). Hardening does not reboot the build VM,
because a reboot would run the first-boot unit inside the template; kernel
arguments and some other settings take effect when a clone first boots, so
the build STIG threshold is lower than the release one.

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
hardening role switches off the forwarding rule (RHEL-10-200642), and the
overlay marks SV-280985 Not Applicable as a deploy-time deviation. A site
that has a log server sets `safbox_remote_log_server` (and, if needed,
`safbox_remote_log_port` and `safbox_remote_log_protocol`, tcp or udp) in
`ansible/local.yml`, and the overlay input `remote_log_server` to the same
server in its site inputs file. The hardening then writes
`/etc/rsyslog.d/99-forwarding.conf` for that server and SV-280985 is
evaluated.

USBGuard is enabled with no rules, so USB devices are blocked until a site
allows them.

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
