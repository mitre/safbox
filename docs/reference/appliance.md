# The appliance layer

## Choosing what the appliance layer does

Every task group in the `platform`, `site_config`, `base`, `tools` and
`services` roles is a block tagged `safbox-<role>-<n>` with a switch
`safbox_<role>_<n>` (default on), in the style of Ansible Lockdown (a
hyphen for the underscore in the tag: `safbox-site-config-1`, switch
`safbox_site_config_1`). The switches and a one-line description of each
group are listed in `ansible/group_vars/all/main.yml`.

- Turn a group off for every build by setting its switch to `false` in
  `ansible/local.yml` (site overrides, git-ignored).
- The switches take effect when a template is built. Switching a group
  off and applying the roles again to a box that already has it does not
  undo it: no task removes a service's units, image or first-boot hook,
  and nothing reconfigures the services left on to match (the proxy
  certificate keeps the names first boot gave it). Build a new template
  instead; see [Services on the box](services.md).
- Run or skip groups for one invocation with `--tags` / `--skip-tags`, for
  example against an existing host, from the repository root
  (`ANSIBLE_CONFIG` names the project's configuration, which finds the
  roles):
  `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i <host>, -u <user> ansible/playbooks/safbox.yml -e @ansible/local.yml --tags safbox-platform-3`
- The `seal` role's groups are tagged (`safbox-seal-<n>`) but have no
  switch: a partially sealed image carries build identity, so the seal runs
  whole. The one exception is the development seal (`seal = false`), which
  stops before the final group and marks the template `unsealed`.
- Each `tools` group (CINC Auditor, SAF CLI, Ansible with the Lockdown
  collections, Packer) has a validation control `safbox-tools-<n>`. The
  profile's `expected_tools` input lists the tools the image ships (default
  `cinc-auditor`, `saf-cli`, `ansible`, `packer`); a tool expected but
  missing fails its control. When you switch a tools group off, drop its
  tool from that input in a site inputs file (see [Site inputs](validation.md#site-inputs));
  its control is then Not Applicable. A distributor who does not
  want to ship Packer's Business Source License sets `safbox_tools_4:
  false`; see the licence note in the [README](https://github.com/mitre/safbox#licences).
- The `services` role holds every long-running service, one task group and
  one task file each: `safbox_services_1` Heimdall (`tasks/heimdall.yml`),
  `safbox_services_2` Vulcan (`tasks/vulcan.yml`), `safbox_services_3` the
  TLS proxy (`tasks/proxy.yml`). A host short of memory runs Heimdall alone
  with `safbox_services_2: false`; the proxy then serves Heimdall only and
  closes Vulcan's port. The profile's `expected_services` input lists
  the services the image ships (default `heimdall`, `vulcan`, `proxy`):
  drop a switched-off service there in a site inputs file, as for a tools
  group.
- `safbox_site_config_1` installs the site's CA bundles, the DoD PKI bundle
  by default; see [Site CA bundles](site-config.md).
- `safbox_base_3` brings every installed package up to date and reboots
  when the update needs it; see [Package updates](#package-updates).
- `safbox_base_4` installs the SAF login greeting, the SAF shield and
  "Welcome to SAFBox!", as `/etc/motd.d/safbox`; it is shown after every
  console and SSH login. It does not touch `/etc/issue`, the login banner
  shown before the password prompt (`safbox_logon_banner`), or
  `/etc/motd`, which stays the site's.
- `safbox_base_5` makes `safuser`, the account for using the tools, on
  each clone's first boot; see [Accounts](accounts.md).
- `safbox_base_6` settles `admin`, cloud-init's key-only default user, on
  each clone's first boot: no password, exempt from password ageing,
  hidden from the desktop login screen; see [Accounts](accounts.md).

## Migrating from the per-service roles

Heimdall, Vulcan and the TLS proxy were once three roles (`heimdall`,
`vulcan`, `proxy`), each with one switch. They are now the task groups of
the `services` role. The old switches are not read any more, so a site that
set one in `ansible/local.yml` must rename it, or the service it had
switched off is built again:

| Old switch | New switch | Old tag | New tag |
|---|---|---|---|
| `safbox_heimdall_1` | `safbox_services_1` | `safbox-heimdall-1` | `safbox-services-1` |
| `safbox_vulcan_1` | `safbox_services_2` | `safbox-vulcan-1` | `safbox-services-2` |
| `safbox_proxy_1` | `safbox_services_3` | `safbox-proxy-1` | `safbox-services-3` |

Rename the tags the same way in any `--tags` or `--skip-tags` you pass.
The role's own variables now carry the role's name as a prefix
(`heimdall_memory` is `services_heimdall_memory`, `vulcan_settings` is
`services_vulcan_settings`, `proxy_tls_dir` is `services_proxy_tls_dir`,
and so on for every `heimdall_*`, `vulcan_*` and `proxy_*` variable in
`ansible/roles/services/defaults/main.yml`); rename any you override in
`ansible/local.yml`, which otherwise has no effect.

The validation controls of the services keep their names
(`safbox-heimdall-*`, `safbox-vulcan-*`, `safbox-proxy-*`). A control
never shares its name with the tag of a task group it does not check (the
`hardening` and `tools` controls are named after their groups because they
check exactly what those groups do), so the controls that had a group's
name are renamed:

| Old control | New control | Checks |
|---|---|---|
| `safbox-services-1` | `safbox-system-1` | the guest agent, cloud-init and sshd enabled, sshd running |
| `safbox-services-2` | `safbox-system-1` | chrony and firewalld running, SSH allowed (merged into `safbox-system-1`) |
| `safbox-services-3` | `safbox-system-3` | the journal kept on disk |
| `safbox-platform-1` | `safbox-os-1` | the operating system is one the appliance supports |
| `safbox-platform-2` | `safbox-os-2` | the CPU supports the image's x86-64 level |
| `safbox-seal-1` | `safbox-sealed-1` | the build user, its key and its sudo rule are gone |
| `safbox-seal-2` | `safbox-sealed-2` | no installer residue |

## Package updates

The kickstart installs from the ISO's own repository, so a fresh install
carries the packages of the ISO's release. Task group `safbox-base-3`
(switch `safbox_base_3`, on by default) updates every installed package
from the configured repositories, on every playbook run: the build and any
later run against a deployed box.

- **What it updates.** On the RHEL family, `dnf` updates every installed
  package to the latest version (`ansible.builtin.dnf`, `name: '*'`,
  `state: latest`, with a fresh metadata cache). On the Debian family,
  `apt-get update` then a full upgrade (`upgrade: dist`). An update can
  install new packages: new kernels, new dependencies, replacements for
  obsoleted packages. Packages the STIG removes are kept out by the
  `excludepkgs` line in `/etc/dnf/dnf.conf`, which the update honours. The
  reboot check needs `dnf-plugins-core`, which the group installs.
- **When it runs.** First in the `base` role: after `platform` and
  `site_config` (so the site's CA bundles are trusted when the repositories
  are fetched over TLS), before the first-boot unit is enabled, and before
  the `tools`, `services` and `hardening` roles, which therefore install
  and harden on the updated system.
- **When it reboots.** Only when the update changed something and needs a
  reboot: `dnf needs-restarting -r` exits 1 (the kernel or a core library
  such as glibc, systemd or OpenSSL was updated since boot), or apt left
  `/var/run/reboot-required`. The box reboots (`ansible.builtin.reboot`) and
  the play continues once SSH is back. In a Packer build this is
  safe: the Ansible provisioner connects directly (`use_proxy = false`),
  and the build user, its key and its sudo rule are on disk and survive the
  reboot. A run with nothing to update neither changes nor reboots; a
  later run updates again only when the repositories carry newer packages.
- **Switching it off.** Set `safbox_base_3: false` in `ansible/local.yml`,
  or skip it for one run with `--skip-tags safbox-base-3`. An air-gapped
  site whose box cannot reach any repository does this; it stays on by
  default.

## A desktop build

The image is headless by default. The RHEL 10 STIG allows a graphical
interface only where one is a documented requirement, so a desktop is a
site decision, made in one place:

1. In `ansible/local.yml`, set `safbox_desktop_enabled: true`. Platform
   group 7 then installs GNOME (the "Server with GUI" environment group),
   enables the display manager, and makes the box boot to the graphical
   login. The same switch approves the GUI to the Lockdown role
   (`rhel10stig_gui`, `rhel10stig_gui_approved`) and stops it removing gdm
   (`RHEL-10-200080`); see `ansible/group_vars/all/main.yml`. Lockdown
   then applies the STIG's GUI rules itself: dconf locks and no automatic
   login. Its graphical banner task fails and is switched off
   (`rhel10stig_700020: false`).
2. The group set includes packages the STIG removes (tuned, from
   `@standard`, removed by RHEL-10-200040); without help every playbook
   run would reinstall tuned and the hardening remove it again. The role
   therefore adds `excludepkgs=tuned` to `/etc/dnf/dnf.conf` in a marked
   block that names the rule (`platform_desktop_package_excludes` in the
   role's `vars/RedHat.yml`), so `dnf install tuned` on a desktop box
   finds nothing to install.
3. The desktop carries the SAF branding, all of it defaults a user can
   change, none of it a lock, and none of it a change to GNOME's own
   theme files, so distribution updates keep applying:

   | What | Where |
   |---|---|
   | the three SAF wallpapers, listed in GNOME Settings | `/usr/share/backgrounds/safbox/`, `/usr/share/gnome-background-properties/safbox.xml` |
   | the navy wallpaper as every user's default | `/etc/dconf/db/local.d/10-safbox-background` |
   | the SAF logo on the login screen | `/etc/dconf/db/gdm.d/10-safbox-logo` (`org.gnome.login-screen logo`) |
   | the SAF logo as the profile picture of every user who has not chosen one | `/etc/accountsservice/user-templates/standard` and `administrator` (`Icon=`) |
   | the "SAF Navy" terminal palette as the default terminal profile's | `/etc/skel/.local/share/org.gnome.Ptyxis/palettes/saf.palette`, `/etc/dconf/db/local.d/10-safbox-terminal` |

   Ptyxis reads palettes only from the user's own data directory, so the
   palette reaches accounts created after the build, through `/etc/skel`;
   an account that already exists copies the file into its own
   `~/.local/share/org.gnome.Ptyxis/palettes/` to use it. The role checks
   each installed file against the sha256 pinned in its `vars/main.yml`.
4. The console is reached over SPICE, the default (`vga = "qxl"`;
   [Reaching a SAFBox console](../guides/proxmox/desktop.md) on
   Proxmox). Optionally set
   `environment_group = "graphical-server-environment"` in the Packer
   variables file, to install GNOME from the DVD ISO during the install
   instead of fetching it from the mirrors afterwards. Without the Ansible
   switch the hardening would remove it again.
5. In a site inputs file for both gates (see [Site inputs](validation.md#site-inputs)), record the
   requirement for the STIG baseline and tell the safbox profile to expect
   a desktop:

   ```
   ---
   gdm_required: true
   gui_required: true
   desktop: true
   ```

   SV-280950 then requires gdm instead of forbidding it, and SV-281297 is
   Not Applicable. Neither is a deviation. `safbox-os-3` checks the
   desktop side: gdm installed and enabled, booting to `graphical.target`,
   and the branding above (on a headless image: no gdm,
   `multi-user.target`). The tracked thresholds apply unchanged.
