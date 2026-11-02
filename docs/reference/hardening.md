# STIG hardening

The `template_hardening` role is the last role of the appliance play. It applies the
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

Its task group, `safbox-hardening-stig`, has a switch, `safbox_hardening_stig`,
as a troubleshooting lever, not a deployment choice: building without it
tells whether a fault comes from the STIG, and a box built that way fails
validation.

**A requirement SAFBox does not meet fails.** The STIG overlay,
`verify/profiles/safbox-rhel10-stig-overlay/controls/overlay.rb`, runs
every baseline control. It marks a control Not Applicable, with its
reason, only where the requirement does not apply to SAFBox at all: today
that is SV-280952 (subscription-manager) on the RHEL rebuilds. A
requirement SAFBox chooses not to meet, or leaves to the deploying site,
is not overridden: its control fails in every scan, and it is listed in
[Known failures](#known-failures) with its cause. Where the Lockdown rule
would apply the requirement anyway, it is switched off in the Lockdown
section of `ansible/group_vars/all/main.yml`, one `rhel10stig_<n>: false`
per line with a one-line comment giving the reason. Other lines there are
off because their Lockdown task fails on SAFBox, and the baseline control
still runs and reports what it finds. Two are off because their tasks would damage SAFBox. RHEL-10-400290 (SV-281075, every file has a valid owner)
gives root every file whose owner is not in `/etc/passwd`, and on SAFBox
those are the container image layers under `/var/lib/containers`, owned
by users that exist only inside each image. Given root, the images break
(PostgreSQL refuses a data directory it does not own), and the task takes
hours, one file at a time. The requirement is applicable; SAFBox has no
hardening for it yet, and the baseline control still runs. RHEL-10-400285 (SV-281074, every file
has a valid group owner) runs only with `rhel10stig_disruption_high` (see
[Lockdown's disruptive changes](#lockdowns-disruptive-changes)). Its task
looks for files whose group is not root (`find / -xdev -type f ! -group
root`) rather than files whose group does not exist (`-nogroup`), and
gives every one group root. Changing a file's group clears its setgid
bit, so `write`, `postdrop`, `postqueue`, `postlog` and `utempter` lose
the group they run as (`rpm -V` reports `.M....G..`), and the sssd
helpers and `/etc/fapolicyd` files are regrouped. The requirement is
applicable: no file on SAFBox lacks a valid group, and the baseline
control, which still runs, passes. Every new choice or site deviation is an owner
decision: switch the rule off in group_vars, add the control to the
known failures table and to the STIG thresholds' comments.

**Account lockout is applied by SAFBox.** Lockdown puts pam_faillock in
the PAM stacks (RHEL-10-600600 and 600610) and holds a lock until an
administrator releases it (RHEL-10-600425) only when
`rhel10stig_disruption_high` is on. The template_hardening role applies those three
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
writes. Root is not locked (SV-281195, a known failure). `admin` logs in with a key and has passwordless sudo, neither of
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
authselect profile below, which uses it before Lockdown runs). Hardening
does not reboot the build VM, because a reboot would run the first-boot
unit inside the template; kernel arguments and some other settings take
effect when a clone first boots, so the build STIG threshold is lower than
the release one.

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
template_hardening role switches off the forwarding rules (RHEL-10-200642, and
RHEL-10-200646, which writes the same forwarding file when
`rhel10stig_disruption_high` is on), and SV-280987, SV-280988 and
SV-280989 fail (see [Known failures](#known-failures); SV-280985 passes
anyway, as explained there). A site that has a log server sets `safbox_remote_log_server` (and, if needed,
`safbox_remote_log_port` and `safbox_remote_log_protocol`, tcp or udp) in
`ansible/local.yml`. The hardening then writes
`/etc/rsyslog.d/99-forwarding.conf` for that server, and these controls
can pass.

USBGuard allows USB hubs and nothing else, so USB devices are blocked
until a site allows them (see [Settings SAFBox applies
itself](#settings-safbox-applies-itself)).

## Known failures

These STIG controls failed in the scans the STIG thresholds were measured
from: the build gate and the release gate of both variants. A row fails
on headless and desktop alike unless its Fails column says otherwise. The
comments in `verify/thresholds/stig-build.yml` and `stig-release.yml` name
the same controls. Each cause starts with what kind of failure it is:

- **Choice**: SAFBox does not meet the requirement, for the reason given;
  its Lockdown rule is off in `ansible/group_vars/all/main.yml`.
- **Site**: met once the deploying site provides what it needs.
- **Baseline defect** or **image defect**: the MITRE baseline profile, or
  a container image, fails a box that meets the requirement. None is filed
  upstream yet except where a link is given.
- **Lockdown defect**: Ansible Lockdown's task does not apply the
  requirement as the STIG's fix text gives it. Not filed upstream yet,
  and not patched locally.
- **Build gate only**: the build scan runs before the reboot that loads
  the audit rules and mount options, and while the build account still
  exists; the control passes on a clone.
- **Not yet triaged**: what the scan reports; the cause is not yet
  established.

| Control | STIG ID | Requirement | Fails | Cause | Check by hand |
|---|---|---|---|---|---|
| SV-280931 | RHEL-10-001020 | vendor packages signature-checked | both gates | Not yet triaged; owner decision pending. The check asks for Red Hat's keys (`/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release`, Red Hat `gpg-pubkey` entries), which a RHEL rebuild does not carry: its packages are signed with the distribution's own key, which is installed and checked (SV-280932 to SV-280934 pass). On Red Hat Enterprise Linux the control applies as written | `rpm -q gpg-pubkey --qf '%{SUMMARY}\n'` names the distribution's release key; `grep -h '^gpgcheck' /etc/yum.repos.d/*.repo \| sort -u` prints only `gpgcheck=1` |
| SV-280935 (CAT I) | RHEL-10-000510 | disk encryption | both gates | Choice. No disk encryption inside the VM: a template that boots unattended would share its key with every copy. Encryption is left to the hypervisor or storage | `lsblk -f` shows no `crypto_LUKS`; ask how the hypervisor or storage encrypts the disk. A site whose storage is encrypted can set the baseline input `data_at_rest_exempt: true`, as the STIG's check text allows |
| SV-280970 | RHEL-10-200601 | fapolicyd enabled | both gates | Choice. On an automation runner the accounts run InSpec, Ansible and Node.js code they bring, and fapolicyd refuses it | `systemctl is-active fapolicyd` prints `inactive` |
| SV-280971 | RHEL-10-200602 | fapolicyd deny-all policy | both gates | Choice. The policy takes effect only while fapolicyd runs (SV-280970) | as SV-280970 |
| SV-280978 (CAT I) | RHEL-10-200631 | AIDE protects the audit tools | both gates | Baseline defect. It also expects AIDE lines for `/usr/sbin/autrace`, which the STIG's check does not list and SAFBox's `aide.conf` does not carry | `sudo grep /usr/sbin/au /etc/aide.conf` lists auditctl, auditd, ausearch, aureport and augenrules with `p+i+n+u+g+s+b+acl+xattrs+sha512` |
| SV-280979 | RHEL-10-200632 | AIDE uses FIPS hashes | both gates | Baseline defect. It looks for an AIDE group named `All`, which neither the STIG's check nor SAFBox's `aide.conf` has; every rule and group there uses `sha512` | `sudo grep -iE 'sha\|md5\|rmd' /etc/aide.conf \| grep -v '^#'` shows only `sha512`; `sudo grep -iE 'md5\|sha1\|whirlpool\|tiger' /etc/aide.conf \| grep -v '^#'` prints nothing |
| SV-280986 | RHEL-10-200643 | rsyslog accepts no remote logs | both gates | Baseline defect. Its greps keep comments, so it reports the commented-out listener examples in the stock `/etc/rsyslog.conf` (`#module(load="imtcp")`, `#input(...)`); rsyslog listens on no port | `sudo ss -tulnp \| grep rsyslog` prints nothing; `sudo grep -E 'ServerRun\|imtcp\|imudp\|imrelp' /etc/rsyslog.conf /etc/rsyslog.d/* \| grep -v ':\s*#'` prints nothing |
| SV-280987 | RHEL-10-200644 | log server authenticated | both gates | Site. No log server to authenticate until the site sets `safbox_remote_log_server` | `/etc/rsyslog.d/99-forwarding.conf` is absent; ask for the site's log server |
| SV-280988 | RHEL-10-200645 | off-loaded records encrypted | both gates | Site. As SV-280987: no log server to send encrypted records to | as SV-280987 |
| SV-280989 | RHEL-10-200646 | off-load via the gtls driver | both gates | Site. As SV-280987: no log server for TLS off-load | as SV-280987 |
| SV-281001 | RHEL-10-200720 | SSH server installed | both gates | Baseline defect. It applies its container test (the SSH server must not be installed) on every host, never asking whether the target is a container; the STIG requires the server, and it is installed | `rpm -q openssh-server` |
| SV-281009 (CAT I) | RHEL-10-000500 | FIPS mode | both gates | Baseline defect. It runs `fips-mode-setup --check`, which EL10 no longer ships ([baseline #6](https://github.com/mitre/redhat-enterprise-linux-10-stig-baseline/issues/6)) | `cat /proc/sys/crypto/fips_enabled` prints `1` |
| SV-281045 | RHEL-10-400140 | world-writable directories owned by system accounts | both gates | Image defect. Four gem directories in the Vulcan image's layers are world-writable and owned by uid 1000 (see [above](#stig-hardening)) | `sudo find /var/lib/containers/storage -xdev -type d -perm -0002 -uid +999` lists only directories under `usr/local/bundle` |
| SV-281064 | RHEL-10-400235 | dotfiles mode 0740 or less | build gate | Build gate only. The scan reports root's and the build account's dotfiles. The seal deletes the build account; root's get mode 0600 at the clone's first boot, from the systemd-tmpfiles rule Lockdown's RHEL-10-400335 writes (`/etc/tmpfiles.d/root_dot_files.conf`), which takes effect at boot | |
| SV-281077, SV-281078 | RHEL-10-400300, 400305 | audit tools owned and group-owned by root | both gates | Baseline defect. It also requires `/sbin/autrace`, which the STIG's check does not list and EL10's audit package does not ship | `sudo stat -c '%U %G %n' /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/auditd /sbin/rsyslogd /sbin/augenrules` prints `root root` for each |
| SV-281103 | RHEL-10-500035 | panic on audit failure | both gates | Choice. A panic would take the services down; the STIG accepts this where availability is documented as overriding | `sudo grep '^-f' /etc/audit/audit.rules` shows a value other than `2` |
| SV-281115 | RHEL-10-500215 | sshd `LogLevel VERBOSE` | both gates | Baseline defect. It reads only `/etc/ssh/sshd_config`, as SV-281268; Lockdown sets the value in a drop-in under `sshd_config.d`, as the STIG's check expects | `sudo sshd -T \| grep -i loglevel` prints `loglevel VERBOSE` |
| SV-281116, SV-281117, SV-281125 to SV-281127, SV-281152 to SV-281154, SV-281156 to SV-281164 (17) | RHEL-10-500300 to 500790 | audit rules for system calls and account files | build gate | Build gate only. One cause: the build scan finds these rules not loaded; after the reboot they are, and the controls pass on a clone | |
| SV-281118 to SV-281124, SV-281128 to SV-281146, SV-281148 to SV-281151 (30) | RHEL-10-500320 to 500650 | audit rules for privileged commands | both gates | Lockdown defect. One cause: Lockdown adds `-F arch=b32` or `b64` to each rule, which the STIG's fix text does not have, and audit then loads the rule as `-S execve`; the STIG's check shows `-S all`, which the baseline requires | `sudo auditctl -l \| grep perm=x` shows a rule pair for each command |
| SV-281147 | RHEL-10-500610 | audit `mount` | both gates | Baseline defect. The STIG asks for `-S mount` rules with key `export`, which are loaded; the baseline looks for a rule on the `/usr/bin/mount` path instead | `sudo auditctl -l \| grep -- '-S mount'` shows the b32 and b64 rules with `key=export` |
| SV-281155 | RHEL-10-500690 | audit `/etc/sudoers.d/` | both gates | Baseline defect. The loaded rule watches the directory and what is in it (`dir=/etc/sudoers.d/`); InSpec's auditd resource reads only `path=` and `-w` rules, so the baseline finds none. Lockdown writes `dir=` where the fix text has `path=`, which covers the files in the directory too | `sudo auditctl -l \| grep /etc/sudoers.d` shows the b32 and b64 rules with `perm=wa` and `key=identity` |
| SV-281165 | RHEL-10-500810 | audit rename and unlink calls | both gates | Lockdown defect. The rules are loaded, but Lockdown gives them the key `perm_mod`; the STIG's fix text, and the baseline, use `delete` | `sudo auditctl -l \| grep renameat2` shows the b32 and b64 rules with all six calls |
| SV-281166 | RHEL-10-600000 | boot loader password | both gates | Site. A password in the template would be shared by every copy | `/boot/grub2/user.cfg` is absent; the site runs `grub2-setpassword` |
| SV-281167 | RHEL-10-600010 | unique boot loader superuser | both gates | Site. As SV-281166: its Lockdown rule is off until the site sets a boot loader password. The superuser is `root`, the name grub2-tools ships in `/etc/grub.d/01_users`, which the STIG disallows; the site renames it there when it sets the password (Lockdown's rule appears not to: its pattern misses the indented line) | `sudo grep -A1 superusers /boot/grub2/grub.cfg` names an account other than `root` |
| SV-281186 | RHEL-10-600270 | one-day minimum password age | build gate | Build gate only. The scan reports the build account, which the seal deletes | |
| SV-281193 | RHEL-10-600405 | password complexity for root | both gates | Baseline defect. Lockdown writes `enforce_for_root = true`, which pwquality accepts (the option ignores its value); the baseline counts only a bare `enforce_for_root`, finds none, and reports it both unset and set more than once | `sudo grep enforce_for_root /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf` shows one uncommented line |
| SV-281195 | RHEL-10-600415 | root locked after failed logins | both gates | Choice. Root is the console recovery account of last resort | `grep '^even_deny_root' /etc/security/faillock.conf` finds nothing |
| SV-281199 | RHEL-10-600450 | no unauthorized accounts | build gate | Build gate only. The scan reports the build account, which the seal deletes | |
| SV-281224 | RHEL-10-700010 | SSH login banner | both gates | Baseline defect. As SV-281115: `Banner` is in a drop-in | `sudo sshd -T \| grep -i '^banner'` prints `banner /etc/issue` |
| SV-281233 | RHEL-10-700125 | `/boot` mounted `nosuid` | build gate | Build gate only. `/boot` is remounted with its new options at the reboot | |
| SV-281235 | RHEL-10-700135 | `/dev/shm` mounted `nodev` | both gates | Lockdown defect. Lockdown 1.2.0 writes the `/dev/shm` line in `/etc/fstab` only for a `/dev/shm` it finds in Ansible's mount facts, which leave out filesystems such as tmpfs whose source is not a path; it finds none and only warns. `/dev/shm` is mounted `nodev` (systemd's default), but the STIG's check also reads `/etc/fstab` | `findmnt -no OPTIONS /dev/shm` shows `nodev`; `grep /dev/shm /etc/fstab` finds nothing |
| SV-281236 | RHEL-10-700140 | `/dev/shm` mounted `noexec` | both gates | Lockdown defect. As SV-281235; without the fstab line `/dev/shm` is mounted without `noexec` | `findmnt -no OPTIONS /dev/shm` shows no `noexec` |
| SV-281237 | RHEL-10-700145 | `/dev/shm` mounted `nosuid` | both gates | Lockdown defect. As SV-281235; `/dev/shm` is mounted `nosuid` (systemd's default) | `findmnt -no OPTIONS /dev/shm` shows `nosuid` |
| SV-281239 | RHEL-10-700155 | `/tmp` mounted `noexec` | both gates | Choice. Installers unpack into `/tmp` and run from there. `nodev` and `nosuid` stay, and `/var/tmp` stays `noexec` (`/dev/shm` does not yet: SV-281236) | `findmnt -no OPTIONS /tmp` shows `nodev,nosuid` and no `noexec` |
| SV-281248 | RHEL-10-700200 | `nodev` on non-root partitions | build gate | Build gate only. As SV-281233: `/boot` | |
| SV-281250 | RHEL-10-700410 | sudo elevates to `sysadm_r` | both gates | Choice. SAFBox's accounts log in unconfined, with SELinux enforcing for the services | `sudo grep -r sysadm_r /etc/sudoers /etc/sudoers.d` finds nothing |
| SV-281264 | RHEL-10-700610 | sshd refuses blank passwords | both gates | Lockdown defect. Its RHEL-10-700610 task edits `/etc/login.defs` instead, and nothing writes `PermitEmptyPasswords no` into a drop-in before `50-redhat.conf`, as the STIG's check requires; sshd's default is already `no`. (The baseline also reads only `sshd_config`, as SV-281115) | `sudo sshd -T \| grep -i permitemptypasswords` prints `permitemptypasswords no`; `sudo grep -ri permitemptypasswords /etc/ssh/` finds no line |
| SV-281268 (CAT I) | RHEL-10-700650 | SSH session rekeying | both gates | Baseline defect. It reads `/etc/ssh/sshd_config` only, while the setting is in a drop-in under `sshd_config.d`, as the STIG's check expects | `sudo sshd -T \| grep -i rekeylimit` prints `rekeylimit 1073741824 3600` |
| SV-281296 | RHEL-10-700930 | SSH idle timeout | both gates | Baseline defect. The same container test as SV-281001, so the interval is never tested | `sudo sshd -T \| grep -i clientaliveinterval` prints `clientaliveinterval 600` |
| SV-281298 (CAT I) | RHEL-10-700950 | Ctrl-Alt-Delete burst disabled | both gates | Baseline defect. Its `grep -iR` prints file names before each line, so its pattern anchored at the line start never matches | `systemctl show -p CtrlAltDelBurstAction` prints `CtrlAltDelBurstAction=none` |
| SV-281316 | RHEL-10-701140 | ptrace restricted | both gates | Baseline defect. It fails on any sysctl file line with another value, here the vendor default `kernel.yama.ptrace_scope = 0` in `/usr/lib/sysctl.d/10-default-yama-scope.conf`, which a later file in `/etc/sysctl.d` overrides; the running value is right | `sysctl kernel.yama.ptrace_scope` prints `1` |
| SV-281322 | RHEL-10-701200 | kdump disabled | build gate | Build gate only. kdump runs until the reboot | |
| SV-281325 | RHEL-10-701230 | certificate status for multifactor login | both gates | Site. No PKI-based multifactor login until the site provides its PKI | ask how the site provides multifactor login |
| SV-281329 | RHEL-10-701270 | PKI trust anchor | both gates | Site. As SV-281325 | as SV-281325 |
| SV-281330 | RHEL-10-701280 | PKI identity mapping | both gates | Site. As SV-281325 | as SV-281325 |
| SV-281332, SV-281333 | RHEL-10-800000, 800010 | firewall restricts remote access and ports | both gates | Baseline defect. It runs `firewall-cmd --zone=drop (default) ...` with the zone name as listed, and the shell rejects the parenthesis, so the firewall is never read | `sudo firewall-cmd --list-all` shows the default zone's services and ports |
| SV-281338 | RHEL-10-800060 | two name servers | both gates | Site. Name servers come from the site's network (DHCP or cloud-init); fails where it gives fewer than two | `grep -c '^nameserver' /etc/resolv.conf` |
| SV-281342 | RHEL-10-800100 | no IPv4 source-routed forwarding | both gates | Baseline defect. As SV-281316: it flags `-net.ipv4.conf.all.accept_source_route` in `/usr/lib/sysctl.d/50-default.conf`, a line that only keeps `all` out of a wildcard and sets nothing | `sysctl net.ipv4.conf.all.accept_source_route` prints `0` |
| SV-281345 | RHEL-10-800130 | IPv4 reverse-path filter | both gates | Baseline defect. As SV-281342: `-net.ipv4.conf.all.rp_filter` in two vendor files | `sysctl net.ipv4.conf.all.rp_filter` prints `1` |
| SV-281348 | RHEL-10-800160 | IPv4 reverse-path filter by default | both gates | Baseline defect. As SV-281316: the vendor default `net.ipv4.conf.default.rp_filter = 2` in `/usr/lib/sysctl.d/50-default.conf`, overridden later | `sysctl net.ipv4.conf.default.rp_filter` prints `1` |
| SV-281353 | RHEL-10-800210 | no IPv4 forwarding | both gates | Choice. Podman's container networks need forwarding. The box has one interface and is not a router | `sysctl net.ipv4.conf.all.forwarding` prints `1`; `ip -br link` shows one physical interface |
| SV-281365 | RHEL-10-900100 | audit rules immutable | build gate | Build gate only. `/etc/audit/audit.rules` gets `-e 2` last when it is rebuilt at the reboot | |

Three requirements SAFBox does not meet pass anyway, because their
baseline controls do not test them: SV-281211 (`admin` keeps passwordless
sudo; the control's filter can never match a rule), SV-281090 (`/home` is
not mounted `noexec`; the control never checks the option) and SV-280985
(no remote log server; the control passes when the forwarding line is
commented out). Their Lockdown rules are off with the reasons above, and
an assessor checks them by hand: `sudo grep -r NOPASSWD /etc/sudoers
/etc/sudoers.d` shows only admin's rule; `findmnt -no OPTIONS /home` shows
`nodev,nosuid` and no `noexec`; `/etc/rsyslog.d/99-forwarding.conf` is
absent.

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
| RHEL-10-400140 (SV-281045), RHEL-10-400280 (SV-281073) | off on desktop builds only | their tasks run `find` over every local mount and fail when it exits non-zero; on a desktop the login screen's document-portal mount (`/run/user/42/doc`) refuses even root. Headless builds keep both; the baseline controls still run |

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
  sudo stays (RHEL-10-600560 is off; the baseline's SV-281211 passes
  anyway, see [Known failures](#known-failures)).
- A password can be changed at most once a day: RHEL-10-600210 sets
  `PASS_MIN_DAYS 1` in `/etc/login.defs`, and RHEL-10-600270 gives every
  existing account a one-day minimum. A user who has just changed a
  password needs an administrator (`sudo passwd <name>`) to change it
  again that day.
- RHEL-10-400280 (SV-281073) sets the sticky bit on world-writable
  directories. On SAFBox these are the four Vulcan gem directories
  described above, inside the image layers under
  `/var/lib/containers/storage`. Vulcan runs as before, so the rule stays
  on for headless builds, but the change is made to pulled layers behind
  podman's back, the same caveat as changing their modes by hand. On
  desktop builds it is off (see the table above). SV-281045, which checks
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
  podman needs forwarding, so the rule is off and SV-281353 is a known
  failure.

These stay on, because on a box in SAFBox's own state they change
nothing and none of them touches `admin`:

- RHEL-10-600110 and 600270 set the ageing of existing accounts that have
  a password (not `admin`'s, which is locked and made after them): at
  most 60 days, at least one. `safuser` already has both from
  `/etc/login.defs` when first boot creates it, and first boot gives
  `admin` the 60 days itself ([Accounts](accounts.md#admin)). SV-281170
  passes for `admin` on that maximum, but `admin` has no password and an
  empty last-change date, so its ageing stays off until it gets one:
  `sudo chage -l admin` shows "Password expires: never".
- RHEL-10-400230 removes and reinstalls cronie when the permissions of
  the cron files differ from the package's; on SAFBox they do not.

## Settings SAFBox applies itself

Where a Lockdown task fails or would do harm, its rule is switched off in
group_vars ("Lockdown task fails" or "harmful") and the template_hardening role
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
  `safbox-aide-init.service`, a unit of its own and not a role of the
  first-boot play, makes it once, after first boot has configured the
  box (it waits for the play's done marker), and the seal removes any
  database the build left.
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
  their handlers); the template_hardening role writes this file after that and does
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
  applies the rule at build, before cloud-init makes `admin` and first
  boot makes `safuser`, so it finds no home to fix. Both accounts are made
  with `useradd -m`, which copies `/etc/skel` with its modes, and the
  packages that own its dotfiles install them 0644. So the role gives the
  dotfiles in `/etc/skel` 0740 or less (`g-wx,o-rwx`, 0640 in practice)
  after every package install, and again on every run, since an update of
  the owning package (`bash`, for example) restores its mode; every
  account made from it starts compliant. The safbox profile checks
  `/etc/skel` (`safbox-hardening-5`); the STIG overlay checks the real
  homes (SV-281064). An account made later without `useradd -m` gets
  whatever modes its maker gives.

## The firewall zone

`safbox_firewall_zone` in `ansible/group_vars/all/main.yml` is the one
firewalld zone every role opens ports in: the template_os role's base services
(group `safbox-platform-firewall`) and the proxy's HTTPS ports. With hardening on
it is `drop`, because Lockdown's rule RHEL-10-200532 (SV-280957, a
deny-all firewall) moves the network interface into Lockdown's zone and
makes it the default; `rhel10stig_custom_firewall_zone` is set from
`safbox_firewall_zone`, so the two cannot differ. With hardening off
(`safbox_hardening_stig: false`) it is the distribution default, `public`.
A site that switches Lockdown's zone rule off (`rhel10stig_200532: false`)
while hardening stays on keeps the interface where it was, so it must also
set `safbox_firewall_zone` to that zone (usually `public`) in
`ansible/local.yml`; otherwise the proxy's ports open in a zone the
interface is not in.
