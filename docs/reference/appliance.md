# The appliance layer

## Roles

The build's playbook, `ansible/playbooks/safbox.yml`, runs the `template_`
roles in this order; the first-boot play runs the `clone_` roles on each
clone (below).

| Role | Runs | What it does |
|---|---|---|
| `template_os` | build | the OS contract (base packages and services, firewall, podman and its registry policy, the persistent journal), the desktop, the site's CA bundles, the package update, the first-boot play and its unit, the `safbox` command, the login greeting, `safuser`'s packages |
| `template_tools` | build | CINC Auditor, the SAF CLI, ansible-core with the Lockdown collections, Packer |
| `template_services` | build | Heimdall, Vulcan and Keycloak pods, the TLS proxy, the start page's status, Firefox bookmarks |
| `template_hardening` | build, last | the RHEL 10 STIG through Ansible Lockdown, and the STIG settings SAFBox applies itself |
| `template_seal` | build, its own play | build record, scan results, scrub, delete the build user |
| `clone_grow_disk` | first boot | hands a clone's larger disk to the growing volumes |
| `clone_accounts` | first boot | settles `admin` and makes `safuser` |
| `clone_secrets` | first boot | the services' secrets as podman secrets |
| `clone_proxy_tls` | first boot, and daily with `--tags renew` | the local CA, the proxy's certificate, trust, renewal |
| `clone_heimdall_scans` | its own unit, after Heimdall is up | imports the build-gate scans into Heimdall |

## Choosing what the appliance layer does

Every task group in the `template_os`, `template_tools` and
`template_services` roles is a block tagged `safbox-<area>-<n>`, in the
style of Ansible Lockdown. The `template_os` role keeps the tags of the
areas it is made of (`platform`, `site-config`, `base`). A group a site
may turn off has a switch `safbox_<area>_<n>` (default on, a hyphen in the
tag for the underscore in the switch: `safbox-site-config-1`, switch
`safbox_site_config_1`); the switches and a one-line description of each
are listed in `ansible/group_vars/all/main.yml`. The groups the box cannot
work without have a tag and no switch: they always run.

| Tag | Switch | What it does |
|---|---|---|
| `safbox-platform-1` | none | base packages and services |
| `safbox-platform-3` | none | the firewall allows the base services |
| `safbox-platform-4` | none | podman, Quadlet, the registry policy, containers read the host's trust store |
| `safbox-platform-6` | `safbox_platform_6` | the journal kept on disk |
| `safbox-platform-7` | `safbox_platform_7` | the desktop (also needs `safbox_desktop_enabled`) |
| `safbox-site-config-1` | `safbox_site_config_1` | the site's CA bundles in the trust store |
| `safbox-base-3` | `safbox_base_3` | update every installed package |
| `safbox-base-1` | none | the first-boot play and its unit |
| `safbox-base-2` | none | the `safbox` command |
| `safbox-base-4` | `safbox_base_4` | the SAF login greeting |
| `safbox-base-5` | `safbox_base_5` | `safuser`, made at first boot |
| `safbox-base-6` | `safbox_base_6` | `admin` settled at first boot |
| `safbox-tools-1` to `-4` | `safbox_tools_1` to `_4` | CINC Auditor, SAF CLI, Ansible, Packer |
| `safbox-services-1` to `-5` | `safbox_services_1` to `_5` | Heimdall, Vulcan, the TLS proxy, Firefox bookmarks, Keycloak |
| `safbox-hardening-1` | `safbox_hardening_1` | the RHEL 10 STIG |

- Turn a group off for every build by setting its switch to `false` in
  `ansible/local.yml` (site overrides, git-ignored).
- The switches take effect when a template is built. Switching a group
  off and applying the roles again to a box that already has it does not
  undo it: no task removes a service's units, image or secrets,
  and nothing reconfigures the services left on to match (the proxy
  certificate keeps the names first boot gave it). Build a new template
  instead; see [Services on the box](services.md).
- Run or skip groups for one invocation with `--tags` / `--skip-tags`, for
  example against an existing host, from the repository root
  (`ANSIBLE_CONFIG` names the project's configuration, which finds the
  roles):
  `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i <host>, -u <user> ansible/playbooks/safbox.yml -e @ansible/local.yml --tags safbox-site-config-1`
- The `template_seal` role's groups are tagged (`safbox-seal-<n>`) but have no
  switch: a partially sealed image carries build identity, so the seal runs
  whole. The one exception is the development seal (`seal = false`), which
  stops before the final group and marks the template `unsealed`.
- `safbox_hardening_1` is a troubleshooting lever, not a deployment
  choice: switching it off tells whether a fault comes from the STIG, and
  a box built without it fails validation.
- Each `template_tools` group (CINC Auditor, SAF CLI, Ansible with the Lockdown
  collections, Packer) has a validation control `safbox-tools-<n>`. The
  profile's `expected_tools` input lists the tools the image ships (default
  `cinc-auditor`, `saf-cli`, `ansible`, `packer`); a tool expected but
  missing fails its control. When you switch a tools group off, drop its
  tool from that input in a site inputs file (see [Site inputs](validation.md#site-inputs));
  its control is then Not Applicable. A distributor who does not
  want to ship Packer's Business Source License sets `safbox_tools_4:
  false`; see the licence note in the [README](https://github.com/mitre/safbox#licences).
  `safbox_tools_3` must stay on: first boot is an Ansible play run by the
  box's own ansible-core and collections, and the build refuses it off.
- The `template_services` role holds every long-running service, one task group and
  one task file each: `safbox_services_1` Heimdall (`tasks/heimdall.yml`),
  `safbox_services_2` Vulcan (`tasks/vulcan.yml`), `safbox_services_3` the
  TLS proxy (`tasks/proxy.yml`), `safbox_services_4` Firefox bookmarks
  (`tasks/firefox.yml`, desktop builds only), `safbox_services_5` Keycloak
  (`tasks/keycloak.yml`). A host short of memory runs Heimdall alone
  with `safbox_services_2: false`; the proxy then serves Heimdall only and
  closes Vulcan's port. The profile's `expected_services` input lists
  the services the image ships (default `heimdall`, `vulcan`, `keycloak`,
  `proxy`): drop a switched-off service there in a site inputs file, as
  for a tools group.
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

## First boot

Everything that must differ between two boxes made from one template (the
`safuser` account and its password, each service's secrets, the proxy's
certificate) is made on each clone's first boot, never at build.
`safbox-firstboot.service` runs once, after cloud-init has applied the
instance's users and keys, and before the services start. It runs the
first-boot play locally with the box's own ansible-core, offline:

```
ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml
```

The play is `ansible/playbooks/firstboot.yml` in this repository, with
its configuration `firstboot.cfg` (`ansible.cfg` on the box) beside it;
its roles are the `clone_` roles of `ansible/roles/`. The `template_os`
role installs them in `/usr/local/lib/safbox/firstboot/`. Only the
`clone_` roles ship: the build's `template_` roles have done their work
once the template is sealed, so the image carries none of them. Beside the
play, `vars.yml` holds what the build decided: the paths the build and the
play share (`safbox_etc_dir`, `safbox_firstboot_done` and the others in
`ansible/group_vars/all/main.yml`) and the switches that pick the roles.
The roles run in this order, each with its tag:

| Role | Tag | Runs when |
|---|---|---|
| `clone_grow_disk` | `grow_disk` | always: it hands a clone's larger disk to the growing volumes ([Platform](platform.md)) |
| `clone_accounts` | `accounts` (`admin`, `safuser` for one account) | `admin` with `safbox_base_6`, `safuser` with `safbox_base_5` ([Accounts](accounts.md)) |
| `clone_secrets` | `secrets` | any of `safbox_services_1`, `_2` and `_5`: the services' secrets as podman secrets ([Services on the box](services.md), "First boot") |
| `clone_proxy_tls` | `proxy_tls` | `safbox_services_3`: the proxy's certificate |

The dotfiles new accounts start with get their STIG modes at build
instead, in `/etc/skel` ([Hardening](hardening.md)).

- **Its log.** `journalctl -u safbox-firstboot` shows each role and task
  with its time. Tasks that handle a password or a key are `no_log`, so
  their values never reach the journal, and the play's configuration keeps
  Ansible's module invocations out of the system log.
- **A failure** stops first boot. Ansible names the failed role and task
  in the last lines of the log (a `no_log` task's details stay hidden),
  the unit is failed, and `safbox status` shows `First boot: failed; see
  journalctl -u safbox-firstboot.service`. The play writes the done
  marker, `/var/lib/safbox/firstboot.done`, as its last task, so a failed
  first boot leaves none and runs again at the next boot. Every role keeps
  what an earlier run made: an account, a password, a secret, a
  certificate.
- **Running it again** on a box whose first boot is done, as root
  (neither run writes the marker):

  ```
  export ANSIBLE_CONFIG=/usr/local/lib/safbox/firstboot/ansible.cfg
  ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml -e firstboot_rerun=true
  ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags proxy_tls
  ```

  The first runs every role, the second only the tagged ones; any run with
  `--tags` ignores the marker and writes none. With `--tags renew` the play
  runs only the renewal of the proxy's certificate
  ([Services on the box](services.md), "Renewal"). With
  `--tags heimdall-scans` it runs only the import of the template's
  build-gate scan results into Heimdall (the `clone_heimdall_scans` role). This
  is not part of first boot: Heimdall starts after first boot, so
  `safbox-heimdall-scans.service` runs it once, after Heimdall answers
  ([Services on the box](services.md), "The template's own scan results in
  Heimdall").
- **The AIDE database** is not part of first boot either:
  `safbox-aide-init.service` (template_hardening role) makes it once first
  boot is done, so it describes the box with everything first boot made
  ([Hardening](hardening.md)).
- **The build's scan results.** The seal installs the build gate's
  results, for the `safbox` profile and the STIG overlay, in
  `/usr/local/share/safbox/scans/` (seal task group 1, which records
  the build) with a `manifest.json` naming the build run. That run is the
  directory `scripts/build.sh` made under `.build/runs/`.
- **Unit presets.** The seal leaves `/etc/machine-id` "uninitialized", so
  a clone's first boot is a systemd *First Boot*, which may reset every
  unit to its preset policy, and the distribution's presets end in
  `disable *`. One preset file, `/etc/systemd/system-preset/50-safbox.preset`
  (`safbox_preset_file`), written by the `template_os` role, enables every
  SAFBox unit by pattern (`safbox-*.service`, `safbox-*.timer`); the
  `template_hardening` role adds `usbguard.service` to it when it enables
  usbguard. Quadlet-generated units have no preset state. Control
  `safbox-firstboot-3` checks each unit is enabled and its preset agrees.

## Package updates

The kickstart installs from the ISO's own repository, so a fresh install
carries the packages of the ISO's release. Task group `safbox-base-3`
(switch `safbox_base_3`, on by default) updates every installed package
from the configured repositories, on every playbook run: the build and any
later run against a deployed box.

- **What it updates.** On the RHEL family, `dnf` updates every installed
  package to the latest version (`ansible.builtin.dnf`, `name: '*'`,
  `state: latest`, with a fresh metadata cache). An update can
  install new packages: new kernels, new dependencies, replacements for
  obsoleted packages. Packages the STIG removes are kept out by the
  `excludepkgs` line in `/etc/dnf/dnf.conf`, which the update honours. The
  reboot check needs `dnf-plugins-core`, which the group installs.
- **When it runs.** In the `template_os` role, after the OS contract and
  the site's CA bundles (so they are trusted when the repositories
  are fetched over TLS), before the first-boot unit is enabled, and before
  the `template_tools`, `template_services` and `template_hardening` roles, which therefore install
  and harden on the updated system.
- **When it reboots.** Only when the update changed something and needs a
  reboot: `dnf needs-restarting -r` exits 1 (the kernel or a core library
  such as glibc, systemd or OpenSSL was updated since boot). The box reboots (`ansible.builtin.reboot`) and
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
   block that names the rule (`template_os_desktop_package_excludes` in the
   role's `vars/main.yml`), so `dnf install tuned` on a desktop box
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
   | Firefox in the dash (Activities favourites), added to the distribution's default list | `/etc/dconf/db/local.d/10-safbox-shell` (`org.gnome.shell favorite-apps`) |
   | the SAF logo as the icon of Firefox's toolbar bookmarks for Vulcan, SAF, SAF Training and the start page; Heimdall's and Keycloak's bookmarks have their own logos (template_services role, [Firefox bookmarks](services.md)) | `/etc/firefox/policies/policies.json` |

   Ptyxis reads palettes only from the user's own data directory, so the
   palette reaches accounts created after the build, through `/etc/skel`;
   an account that already exists copies the file into its own
   `~/.local/share/org.gnome.Ptyxis/palettes/` to use it. The role's
   `vars/main.yml` records where each file came from.
   GNOME Shell's default dash names Firefox only by its Flatpak's id
   (`org.mozilla.Firefox.desktop`), and the distribution's Firefox is the
   RPM (`firefox.desktop`), so without help Firefox is missing from the
   dash. The role's dash default is the shell's own list, in its order
   (`template_os_desktop_favorite_apps` in `vars/main.yml`), with
   `firefox.desktop` first; apps that are not installed are skipped. It
   reaches users who have not changed their dash.
4. The console is reached over SPICE, the default (`vga = "qxl"`;
   [Reaching a SAFBox console](../guides/proxmox/desktop.md) on
   Proxmox). The display adapter (qxl) prefers 1024x768 until a console
   client sends its window size, and GNOME cannot follow the client's
   window on it: the adapter never marks its outputs as resized by the
   host (the `hotplug_mode_update` connector property stays 0), so GNOME
   handles each resize as a monitor being plugged in again and restores an
   earlier layout about as often as it takes the new size. The role
   therefore gives the console a fixed resolution, 1920x1080
   (`template_os_desktop_console_mode` in the role's defaults), in GNOME's
   system-wide monitor configuration, `/etc/xdg/monitors.xml`, which the
   login screen and every session read; the SPICE client scales it to its
   window. A user who picks another size in **Settings → Displays** keeps
   it in `~/.config/monitors.xml`, which takes precedence. `safbox-os-4`
   checks the file. Optionally set
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
   the branding and the dash above, `safbox-firefox-1` the Firefox policy (on a
   headless image: no gdm,
   `multi-user.target`). The tracked thresholds apply unchanged.
