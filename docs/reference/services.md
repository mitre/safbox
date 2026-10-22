# Services on the box

The `template_services` role runs each application and its PostgreSQL as a podman
pod of Quadlet units (`tasks/heimdall.yml`, `tasks/vulcan.yml`), in the
service shape of the application's upstream `docker-compose.yml` (each
key's counterpart is in [Upstream compose files](#upstream-compose-files)), Keycloak and its PostgreSQL
the same way (`tasks/keycloak.yml`), the single sign-on for both, and one
nginx container that terminates TLS for all of them (`tasks/proxy.yml`).
Images are pinned by digest in `ansible/group_vars/all/main.yml` and
pulled at build, and Keycloak's FIPS image is built then, so a clone starts
offline.

| Service | Pod publishes (loopback only) | Browser URL |
|---|---|---|
| Heimdall | `127.0.0.1:3000` | `https://heimdall.safbox.internal/` |
| Vulcan | `127.0.0.1:3001` | `https://vulcan.safbox.internal/` |
| Keycloak | `127.0.0.1:3002` | `https://keycloak.safbox.internal/realms/safbox/account/` |
| Start page | (served by nginx) | `https://safbox.internal/` |

The proxy serves every application on port 443 by name (name-based
virtual hosts). Any other name, and the box's bare address, get the start
page: this documentation, built with VitePress on the build workstation
(`site/`, by `scripts/build.sh`) and copied to the box. Its welcome page
shows each service up or down and links to the applications, from a
`status.json` that `safbox-site-status.service` rewrites after each
listed service starts (at the end of boot and after a restart) and its
timer rewrites every minute, so a service that stops shows as down
within a minute. Each application's unit counts as started only once
its container's healthcheck passes (Heimdall's page, Vulcan's `/up`,
Keycloak's `/health/ready`), so the end of boot waits for applications
that answer, and "up" means one does. Port 80
redirects every request to
`https://` with the same name and path, and so does a plain `http://`
request sent to port 443. The firewall opens `http` and `https` and no
other port. The loopback ports are `safbox_<service>_loopback_port` in
group_vars. Each pod has its own podman network, so no database is
reachable from another pod or from the network.

**Names.** The domain is `safbox_domain` in group_vars (default
`safbox.internal`; `.internal` is reserved for private networks and never
resolves on the internet). On the box, `/etc/hosts` maps the domain and
each shipped application's name to 127.0.0.1, so the box's own browser
opens them. Because cloud-init rewrites `/etc/hosts` at boot where its
`manage_etc_hosts` is on (Proxmox turns it on), the same entries go in
cloud-init's hosts template, `/etc/cloud/templates/hosts.redhat.tmpl`.
The first-boot certificate names them too, and Heimdall's `EXTERNAL_URL`,
Vulcan's `VULCAN_APP_URL` and Keycloak's `KC_HOSTNAME` are set to them. An application switched
off loses its server, its name and its link.

**Reaching the box from another machine.** Point the names at the box's
address, in your DNS (for example an `A` record for `safbox.internal` and
for `*.safbox.internal`) or, for a single workstation, in its hosts file
(`/etc/hosts`, or `C:\Windows\System32\drivers\etc\hosts`):

```
192.0.2.10  safbox.internal heimdall.safbox.internal vulcan.safbox.internal keycloak.safbox.internal
```

Then browse to `https://heimdall.safbox.internal/`. A site that sets its
own `safbox_domain` uses those names instead, and sets the same value for
the `domain` input of the safbox validation profile.

**Certificate trust.** The box trusts its own certificate: first boot
signs it with a local CA of the box's own and adds that CA to the system
trust store, so curl, the service containers and Firefox on the box open
the names without a warning. The certificate names only the box's names,
not its addresses, so a browser opening the box by bare address
(`https://192.0.2.10/`) warns; the start page is still served there, and
`http://` to the address still redirects.

Another machine's browser warns until it trusts the box. The better fix
is a certificate from a CA your machines already trust (see "Your own
certificate" below). You can instead import the box's CA (any user on the
box can read it at
`/etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt`). The CA can
vouch only for TLS servers (its extended key usage is server
authentication, so it cannot sign mail, code-signing or client
certificates), and its critical name constraints limit those to names
under `safbox_domain` (here `safbox.internal` and its subdomains) and no
IP address. That is what makes importing it reasonably safe: a machine
that trusts it accepts it for no other web site, and for nothing but web
sites. Anyone with root on the box, or a copy of its CA key, can still
issue certificates for names under the domain, which the importing
machine will accept.

**Firefox bookmarks.** On a desktop build (`safbox_desktop_enabled`), task
group `safbox-services-4` writes Firefox's system-wide enterprise policy,
`/etc/firefox/policies/policies.json`: its `Bookmarks` policy puts
Heimdall, Vulcan, Keycloak (its account page), SAF (saf.mitre.org), SAF
Training and SAFBox - Start Here on the bookmarks toolbar, one button each, and
`DisplayBookmarksToolbar` shows the toolbar. `Homepage` makes the start
page (`https://safbox.internal/`) the home page and the page Firefox
opens with; users can change it. `OverrideFirstRunPage` and
`OverridePostUpdatePage` open the start page too, instead of Firefox's
Welcome page on a new profile and its release notes after an update;
without the proxy they are `""`, Firefox's value for no page, so Firefox
still skips the Welcome page. `DisableTelemetry` stops Firefox sending
Mozilla telemetry, as the Firefox STIG asks (FFOX-00-000014), with or
without the proxy. With nothing to send, Firefox also skips its
data-reporting notice: Mozilla's privacy notice in a background tab on a
new profile, or a bar along the top of the window. The policy's
`Preferences` keep that notice away on their own as well, locked so a
profile cannot change them: `datareporting.policy.firstRunURL`, the
address the tab opens, is empty, and
`datareporting.policy.dataSubmissionPolicyBypassNotification`, which skips
the notice altogether, is true.
The applications' bookmarks follow their
switches, and they, the start page's bookmark and the home page need the
proxy. Users keep
their own bookmarks beside them. The distribution's default bookmarks
(Rocky Linux's links, for example) are dropped (`NoDefaultBookmarks`):
Firefox imports them on first run at the same time as it creates the
box's, and one of the box's was lost.

Each bookmark has an icon, embedded in the policy as a
`data:image/svg+xml;base64,` URI. That is the only kind of icon the
`Bookmarks` policy accepts (Firefox 140 ESR ignores an `https:` or `file:`
icon URL), so the file is larger than the bookmarks alone:

| Bookmark | Icon | From |
|---|---|---|
| Heimdall | Heimdall's orange logo | `apps/frontend/src/assets/logo-orange-tsp.svg` in [mitre/heimdall2](https://github.com/mitre/heimdall2) at v2.14.0 (the release of the Heimdall image the box runs), Apache-2.0 |
| Keycloak | Keycloak's logo | `js/apps/admin-ui/public/favicon.svg` (the admin console's icon) in [keycloak/keycloak](https://github.com/keycloak/keycloak) at 26.8.1 (the release of the Keycloak image), Apache-2.0 |
| Vulcan, SAF, SAF Training, SAFBox - Start Here | the SAF shield | the SAF logo the desktop installs (`/usr/share/pixmaps/saf-logo.svg`, installed by the template_os role); Vulcan has no logo of its own |

Heimdall's and Keycloak's files are kept in the role
(`roles/template_services/files/firefox/`) unchanged from upstream, so the build
does not reach GitHub; the comment above `template_services_firefox_app_icons`
in the role's defaults records each one's source and commit. Firefox sets an
icon when it creates the bookmark, the first time a user starts it: a
profile made before the policy carried an icon keeps the one it has, and
once a user opens a site, Firefox may show that site's own icon on its
bookmark instead. `safbox-firefox-1` checks the policy: the home page and
the first-run and post-update pages, telemetry off and the
locked data-reporting notice prefs, the six toolbar bookmarks with their
addresses, and every icon against its own pinned sha256.

**First boot.** The units are installed and enabled at build but start only
once their secrets exist (an `ExecCondition=podman secret exists` for each,
ordered after `safbox-firstboot.service`). First boot
([First boot](appliance.md#first-boot)) is the only place they are made:

- the first-boot play's `clone_secrets` role (tag `secrets`) makes each
  service's secrets as podman secrets: Heimdall's
  `heimdall-database-password`, `heimdall-jwt-secret`,
  `heimdall-api-key-secret` and `heimdall-admin-password`; Vulcan's
  `vulcan-database-password`, `vulcan-secret-key-base`,
  `vulcan-cipher-password`, `vulcan-cipher-salt` and
  `vulcan-admin-password`; Keycloak's `keycloak-database-password`,
  `keycloak-bootstrap-admin-password` and `keycloak-safuser-password`;
  and, with Keycloak on, each application's client secret,
  `heimdall-oidc-client-secret` and `vulcan-oidc-client-secret`. Each
  value comes from `openssl rand -hex` (the FIPS DRBG) at the strength of
  the upstream setup scripts and reaches `podman secret create` on its
  standard input, never in a command line. Each container receives them
  as environment variables (see **Secrets as environment variables**
  below);
- the first-boot play's `clone_proxy_tls` role (tag `proxy_tls`) writes a
  local CA (`/etc/safbox/ca/ca.crt` and its key `ca.key`, valid ten
  years, in a root-only directory the proxy container does not mount,
  limited to names under `safbox_domain`) and a certificate it signs for
  exactly the served names (listed in `/etc/safbox/proxy-names`) to
  `/etc/safbox/tls/safbox.crt`, its RSA 3072 key to `safbox.key` (root
  only), and adds the CA to the system
  trust store (`/etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt`,
  outside the `safbox-*` anchors the template_os role manages).

All of them are root's alone: the secrets in podman's secret store (one
0600 file under `/var/lib/containers/storage/secrets`), the key files mode
0600 (the certificate 0644). First boot never replaces a secret, key or
certificate that exists. The seal removes every podman secret and asserts
that podman lists none and its store is empty, and removes and asserts the
absence of every `/etc/safbox/*.env` file, of `/etc/safbox/tls` and
`/etc/safbox/ca`, and of the local CA's trust anchor, so the template holds
none. While a container runs, podman keeps the values it was given in that
container's own files under `/var/lib/containers` (root only), as it does
any container's environment.

**Secrets as environment variables.** Every container receives the
secrets it reads as environment variables (Quadlet `Secret=` with
`type=env`), and the appliance keeps it that way for now. `podman
inspect` does not show their values. One secret reaches both containers
that read its value: a database password the application and its
PostgreSQL, a client secret the application and Keycloak. A `type=mount`
secret, a file inside the container, would serve only where the image
reads that value from a file:

- The sclorg PostgreSQL image has no `*_FILE` variables. It reads
  `POSTGRESQL_PASSWORD` from the environment and sets its role's password
  from it on every start, so the three database passwords stay
  environment variables.
- Heimdall reads a `.env` file from its backend's working directory as
  well as the environment (`apps/backend/config/app_config.ts`, and the
  `create-administrator` seeder's `dotenv.parse`); a variable set in the
  environment wins over the file. A `.env` holding only Heimdall's own
  values (`JWT_SECRET`, `API_KEY_SECRET`, `ADMIN_PASSWORD`), mounted as
  one secret, would copy nothing another container reads.
  `DATABASE_PASSWORD` and `OIDC_CLIENT_SECRET`, which its PostgreSQL and
  Keycloak read too, would stay environment variables.
- Keycloak reads its options from a file as well as the environment:
  `keycloak.conf` (or the file `--config-file` names) and the config
  keystore (`--config-keystore`). Only the bootstrap administrator's
  password, which no other container reads, would gain from that. Its
  database password is the one its PostgreSQL reads from the
  environment, and the realm import's `${...}` placeholders (the client
  secrets, `safuser`'s initial password) resolve from environment
  variables only.
- Vulcan 2.4.1 reads its database password (`config/database.yml`), its
  administrator's password (`lib/tasks/admin_bootstrap.rake`) and its
  client secret (`config/vulcan.default.yml`) from the environment, and
  Rails reads `SECRET_KEY_BASE` there. The image loads no `.env` file:
  `dotenv-rails` is one of its development and test gems, which the
  production image leaves out.

Mounting Heimdall's own values as a `.env` file and passing Keycloak's
bootstrap password through a configuration file are possible later; the
other secrets stay environment variables either way.

**Cloning a deployed box.** First boot runs once on each box
(`/var/lib/safbox/firstboot.done` marks it done), so a clone of a box
that has already booted runs none of it and keeps that box's per-install state: the same podman secrets, the
same local CA and its key (`/etc/safbox/ca`), the same TLS key
(`/etc/safbox/tls`), `safuser`'s generated password
(`/etc/safbox/safuser.env`, when first boot made one) and the databases
in the `heimdall-db`, `vulcan-db` and `keycloak-db` volumes. Make every
box from the sealed template, which holds none of these, never by
cloning a deployed one.

**Reading a secret.** As root, `podman secret ls` lists the secrets and
when each was made, and the description label of each says what it is;
`podman secret inspect --showsecret` prints a value, which nothing else on
the box keeps:

```
sudo podman secret inspect --format '{{.Spec.Labels.description}}' keycloak-safuser-password
sudo podman secret inspect --showsecret --format '{{.SecretData}}' heimdall-admin-password
```

To replace a secret, remove it (`sudo podman secret rm NAME`), run the
`clone_secrets` role again (`--tags secrets`; [Running it again](appliance.md#first-boot)),
and restart the pod that reads it. A new database password takes effect at
the database's next start (the image sets its role's password from the
variable on every start). A client secret is also stored in Keycloak's
realm at its first start, so change it there too (the client's
Credentials tab in the administration console). The administrators'
passwords and `safuser`'s initial Keycloak password are read on each
application's first start only, so replacing those secrets later changes
nothing.

**Renewal.** The certificate is valid for a year; the CA for ten. Daily
(at a random time within an hour of midnight, or at the next boot after a
day the box was off), `safbox-proxy-renew.timer` starts
`safbox-proxy-renew.service`, which runs the first-boot play with
`--tags renew`: only the `clone_proxy_tls` role's renewal runs, nothing
else. When the local CA signed the certificate the proxy serves and it is
valid for fewer than 30 more days (the role's `clone_proxy_tls_renew_days`), the
role signs a new key's certificate for the names in
`/etc/safbox/proxy-names` from the same CA, checks it verifies against the
CA, moves it into place, checks the system trust store verifies it and
restarts `safbox-proxy.service` if it was running. The CA does not change,
so the box, its applications and every machine that imported the CA keep
trusting the box; nothing else needs restarting. Otherwise it changes
nothing. Its log is `journalctl -u safbox-proxy-renew`, and
`systemctl list-timers safbox-proxy-renew.timer` shows its next run. A
renewal also picks up names added since the last one (an application
switched on later). Control `safbox-proxy-7` checks the timer is enabled
and waiting, that the proxy serves the certificate on disk, and that it
(and the local CA that signed it) has more than 14 days left.

**Renew now.** As root, either let the service decide, or renew whatever
the certificate's remaining validity:

```
systemctl start safbox-proxy-renew.service
export ANSIBLE_CONFIG=/usr/local/lib/safbox/firstboot/ansible.cfg
ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags renew -e clone_proxy_tls_renew_force=true
```

**Your own certificate.** Replace `safbox.crt` and `safbox.key` in
`/etc/safbox/tls/` with your certificate (PEM, with any intermediates
after it) and unencrypted key, owned by root, the key mode 0600, then
`systemctl restart safbox-proxy.service`. Its subject alternative names
must cover the names in `/etc/safbox/proxy-names`. The renewal recognises
the box's own certificate by its signature: it never replaces a
certificate the local CA did not sign, and its log says it left a site's
own certificate alone. Your site renews it: put the new pair in the same
place and restart the proxy again before it expires (`safbox-proxy-7`
fails once 14 days or fewer are left). Then retire the local CA, which
nothing needs any more:

```
rm -f /etc/safbox/ca/ca.key /etc/safbox/ca/ca.crt /etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt
(umask 022; update-ca-trust extract)
```

First boot trusts the local CA only while the proxy's certificate is one
it signed, so running its role again with your certificate in place does
not bring the CA back. Whenever the CA is trusted, the role checks that the
system trust store as extracted (the bundle every client reads) verifies
the certificate, and rebuilds the store when it does not. To go back to
the box's own certificate, delete `safbox.crt` and `safbox.key`, run the
`clone_proxy_tls` role again as root (`--tags proxy_tls`;
[Running it again](appliance.md#first-boot)), and restart the proxy;
it makes a new local CA if you retired the old one.

**Rotating the local CA.** Replace the CA itself only when it must go:
its key may have been copied, it nears the end of its ten years (the
renewal's log warns once it would expire before a new certificate), or
`safbox_domain` changed, since the CA may sign only names under the
domain it was made for (a renewal then stops without touching the
certificate in use and says so). It is disruptive: every machine that
imported the old CA must import the new one, and the applications, which
read the box's trust store when they start, must be restarted to trust it.
As root:

```
rm -f /etc/safbox/ca/ca.key /etc/safbox/ca/ca.crt /etc/safbox/tls/safbox.key /etc/safbox/tls/safbox.crt
rm -f /etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt
export ANSIBLE_CONFIG=/usr/local/lib/safbox/firstboot/ansible.cfg
ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags proxy_tls
systemctl restart safbox-proxy.service heimdall-pod.service vulcan-pod.service keycloak-pod.service
```

The role makes a new CA and certificate and puts the new CA in the
system trust store in place of the old one. Then hand out the new
`/etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt` to the
machines that imported the old one, and remove the old one from them.

**Accounts.** Each application is made with one local account, its
administrator, `admin@safbox.internal` (`admin@` the domain), made on its
first start with the password first boot made, as the way in while
Keycloak is down or switched off. Everyone else signs in through Keycloak
(below) and gets a regular account in each application on their first
sign-in. Registration is off in both, but only Heimdall refuses it
(`REGISTRATION_DISABLED=true`). Vulcan 2.4.1 still accepts
self-registration from anyone who can reach it, despite
`VULCAN_ENABLE_USER_REGISTRATION=false`: the setting only hides the
sign-up link, and a sign-up posted to `/users` makes a regular local
account (not an administrator) and signs it in, because Vulcan's
registration handler checks only that local login is on. This is an
upstream defect, accepted and not worked around; local login stays on
for the administrator. Read the administrators' passwords on the box:

```
sudo podman secret inspect --showsecret --format '{{.SecretData}}' heimdall-admin-password
sudo podman secret inspect --showsecret --format '{{.SecretData}}' vulcan-admin-password
```

Heimdall asks its administrator for a new password at the first sign-in.
It also prints the administrator's password in its log on the first start
(`journalctl -u heimdall.service`), even when given one: upstream
behaviour, so change it at that first sign-in. A box deployed before this
change made its administrators the old way (Heimdall's
`admin@heimdall.local` with a random password in its log; Vulcan's first
registered user), and keeps them. LDAP and SMTP are site settings
(`template_services_vulcan_settings` in the template_services role's defaults).

**The template's own scan results in Heimdall.** A fresh box's Heimdall
already holds the results the build gate took from the build VM just
before the seal: the `safbox` profile and the STIG overlay. Both are
public evaluations, which every user who signs in sees, `safuser`
included:

- **Names and tags.** Each is named
  `safbox-build-<run>-<profile>.json`, where `<run>` is the build's run ID
  (its directory under `.build/runs/` on the build machine). Each is
  tagged `safbox-build-scan`, `run <run>` and `scanned <date>` (UTC).
  The STIG overlay's evaluation is also tagged `STIG`.
- **Where they come from.** `scripts/build.sh` gives the build gate the
  run's `scans/` directory (`scripts/validate.sh --results-dir`). The
  seal installs the results in the template under
  `/usr/local/share/safbox/scans/`, root's alone, with `manifest.json`
  naming the run, the commit and each scan's profile, file, date and
  sha256. A template built without `scripts/build.sh` (Packer without
  `build_scans_dir`) holds none.
- **How they are imported.** `safbox-heimdall-scans.service` (with
  Heimdall, task group `safbox-services-1`) imports them once per box
  after Heimdall answers its healthcheck. It runs the first-boot play's
  `clone_heimdall_scans` role:

  ```
  ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags heimdall-scans
  ```

  The role signs in as Heimdall's administrator with the password first
  boot made. The password is read from the podman secret and sent in the
  request's body, never in a command line, and the tasks that hold it or
  the session token are `no_log`. It checks each file against the
  manifest's sha256 and uploads each scan Heimdall does not list yet. It
  makes no API key. Each file is sent as the upload's content, the HDF
  JSON itself, so Heimdall stores it as HDF and its viewer loads it.
  (Sent by path, Ansible's `uri` module base64-encodes the file part,
  which Heimdall does not decode: it would keep the encoded text under
  `originalResultsData`, and the evaluation would not load.)
- **Running once.** The role writes `/var/lib/safbox/heimdall-scans.done`,
  and the unit does not run again, so an evaluation the administrator
  deletes stays deleted. If Heimdall is not running, nothing is imported
  and no marker is written, and the next boot tries again.
- **Importing again.** As root, remove the marker and restart the unit
  (it stays active after its run, so `start` alone does nothing):
  `rm /var/lib/safbox/heimdall-scans.done && systemctl restart safbox-heimdall-scans.service`.
  This uploads what Heimdall does not hold, by name: to replace an
  evaluation, delete it in Heimdall first. Once the administrator has
  changed the password first boot made, Heimdall refuses the role's
  sign-in (HTTP 401). Upload the files from
  `/usr/local/share/safbox/scans/` in Heimdall's page instead.
- **Why they are public and not `safuser`'s.** Heimdall makes the account
  of a user who signs in through Keycloak at that user's first sign-in,
  matched by email. Before then, an evaluation can be owned only through
  a second local Heimdall account for `safuser@<domain>`. That account
  would be one more way to sign in, and Heimdall would then ask `safuser`
  for a password it never had before it edits its profile or makes its
  own API keys. The other way is Heimdall's group sync from Keycloak,
  which removes every user from any group made in Heimdall at their next
  sign-in. Heimdall's administrator owns the evaluations and can delete
  them.

`safbox-heimdall-7` and `safbox-heimdall-8` check the unit, the files,
the marker, and that each evaluation is public and has its tags. They
also check that Heimdall stores each one as HDF: the source file's
profiles, with as many controls in each. `safbox-client-keycloak-2`
fetches each one as `safuser` and checks that its content is HDF.

**Single sign-on (Keycloak).** Keycloak 26.8.1, in FIPS strict mode, signs
users in to both applications at `https://keycloak.safbox.internal/` (task
group `safbox-services-5`, switch `safbox_services_5`). It runs from an
image the build makes from Keycloak's image, pinned by digest, and the four
Bouncy Castle FIPS jars its FIPS guide asks for, pinned by sha256; the
Containerfile and the jars' sums stay on the box in `/etc/safbox-keycloak`.
Its realm, `safbox`, is imported on Keycloak's first start from
`/etc/safbox-keycloak/safbox-realm.json`: a client for each application
switched on, and one user, `safuser`, with the realm's default role (the
import grants it only to users that list it), whose Keycloak password is
its own (not the OS account's), generated at first boot:

```
sudo podman secret inspect --showsecret --format '{{.SecretData}}' keycloak-safuser-password
```

That password is one-time: the realm makes `safuser` choose a new one at
its first sign-in (the update-password required action), and the secret,
as its description says, keeps the initial password only. `safuser` signs
in at its account page, `https://keycloak.safbox.internal/realms/safbox/account/`
(the Keycloak bookmark), and changes its password there later (Account
security, Signing in, Password, Update; [Accounts](accounts.md#accounts-in-the-applications)).
`https://keycloak.safbox.internal/` sends the browser to that page. The
realm refuses registration, locks an account briefly after quick wrong
passwords, and asks for 15 characters, not the user name; FIPS strict
mode hashes passwords with PBKDF2-SHA512. Keycloak's administration
console and its master realm answer to the box itself only: open
`https://keycloak.safbox.internal/admin/master/console/` in the box's own
browser and sign in as `temp-admin` with the password in the
`keycloak-bootstrap-admin-password` secret, the temporary administrator
Keycloak makes on its first start. That sign-in is the master realm's:
`safuser` does not exist there. Inside the Heimdall and
Vulcan pods, Keycloak's name points at the host (`AddHost`), so they reach
it at the issuer URL the browser uses. Changing the realm file later does
not change a running box's realm: use the console. With Keycloak switched
off, both applications keep local sign-in for their administrators (and
Vulcan its self-registration, Accounts above).

**Why Keycloak, and how it sits behind the proxy.** Keycloak is the one
single sign-on server considered that both gives Heimdall and Vulcan real
sign-on (OIDC) and documents a FIPS mode that runs here. Authelia and
Kanidm are lighter but document no FIPS mode, so SAFBox would have to make
that claim for them; 389 Directory Server has a FIPS mode but is LDAP
only, so each application would still show its own login form. Keycloak
runs as one node (`KC_CACHE=local`): no cluster stack listens in its pod.
The proxy connects to the pod's loopback port, but Keycloak sees those
connections come from its pod network's gateway, not from 127.0.0.1. Its
network therefore has a fixed subnet (`template_services_keycloak_subnet`,
gateway `template_services_keycloak_gateway`) and Keycloak believes
forwarded headers from that gateway alone (`KC_PROXY_TRUSTED_ADDRESSES`).
Trusting 127.0.0.0/8 instead makes Keycloak ignore the proxy's headers:
sign-in still works, but it logs "Non-secure context detected" and its
session cookies lose `Secure`.

**Footprint.** Measured on a 2 vCPU, 4 GiB development clone with both
applications idle after the service tests: about 750 MB in the containers
(Heimdall 290 MB, Vulcan 280 MB, the databases 75 and 80 MB, nginx 25 MB),
2.5 GiB of the host's memory still available (before Keycloak). The
container memory limits (`template_services_heimdall_memory`,
`template_services_vulcan_memory`, 1g; `template_services_keycloak_memory`, 768m; the three
databases 512m each; nginx 512m) sum to about 4.8 GiB. Keycloak sizes its
Java heap from its limit (`kc.sh` gives the heap 70% of the container's
memory), so the limit sets its use: at 768m Keycloak peaked under 0.6 GiB
through 20 rounds of sign-ins to both applications, its database at about
35 MB; a 1536m limit only made the heap larger. Its images take about
0.5 GB of disk.

**Switching a service off applies at build time.** The services' switches
(`safbox_services_1` to `safbox_services_5`) decide what a template is
built with. Setting one to `false` and applying the roles again to a box
that already has the service does not remove it: no task deletes its
units, image or secrets, so it keeps running, and nothing
reconfigures the services left on to match. Keycloak switched off this
way keeps its units, image and secrets, and the proxy certificate keeps its
name. To drop a service, build a new template without it.

**Applying the roles to a box that has already booted.** The first-boot
play does nothing once `/var/lib/safbox/firstboot.done` exists, so on
such a box run it again with `firstboot_rerun`, which leaves the
marker alone, then start the services (or reboot):

```
sudo env ANSIBLE_CONFIG=/usr/local/lib/safbox/firstboot/ansible.cfg \
  ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml -e firstboot_rerun=true
sudo systemctl start heimdall.service vulcan.service safbox-proxy.service
```

**Testing.** The release gate's safbox profile checks the units, secrets,
loopback-only ports, each name over HTTPS, the start page,
the certificate's names, `/etc/hosts` and the firewall from a shell on the
box, and that Heimdall offers local log in and refuses a sign-up. Its
client profile, `verify/profiles/safbox-client`, then acts as a browser
would, from your workstation over HTTPS only: it checks the proxy's TLS
(TLS 1.3 negotiated with a certificate for each name; TLS 1.0, 1.1 and
ChaCha20 refused), that only ports 80 and 443 answer, that plain HTTP to
each name and the bare address, on port 80 and on 443, is redirected, and loads each application's page with its scripts and
stylesheets. Heimdall's administrator logs in and uploads the gate's own
safbox results; Vulcan's signs in through the sign-in form and creates a
project; a sign-up to Vulcan is tried and its result kept, as the known
upstream defect (Accounts above), Not Applicable rather than a failure.
Keycloak's discovery document must name the safbox realm, its
administration paths must refuse your workstation, and its bare name must
lead to the account page. `safuser` starts with the generated password
(`SAFUSER_PASSWORD`): its first sign-in must ask for a new one, the
realm's policy must refuse a short one and the user name, and the profile
sets one, kept in a file on your workstation, mode 0600
(`keycloak_safuser_password_file`; by default one that is removed after
the run, so each run expects a fresh box). Signed in, `safuser` must see each of
the template's build-gate scans the box imported as a public evaluation
tagged with its build run. With that password `safuser`
signs in to both applications through Keycloak as a regular user and to
the account console, whose profile loads, and changes its password there,
as `safuser` would; last, the generated password and a wrong one must be
refused. The profile sends each name to the box's address itself, so your
workstation needs no DNS or hosts entry. It creates data and changes
`safuser`'s password, so the release gate runs it against a clone only;
see [How SAFBox is validated](validation.md) to run it by hand. It needs
curl and OpenSSL 3 as `openssl` (not LibreSSL, as on macOS).

**FIPS.** SAFBox makes the effort to run every component in FIPS mode:
each one's crypto is meant to go through a FIPS provider, under the
host's FIPS crypto policy, except where noted below. That is not the same as every component being
FIPS-validated, its crypto module carrying a NIST CMVP certificate, and
SAFBox does not claim it: some of the modules below are validated, some
are not. Each container carries its own userspace crypto. Keycloak runs
its own FIPS provider, Bouncy Castle FIPS in Approved Mode (FIPS strict
mode), on Red Hat's OpenJDK 21 in UBI 9, which switches itself to its FIPS
configuration on a FIPS host. Its bc-fips is 2.1.3, the version Keycloak
26.8.1 requires: a patch release on the line NIST's CMVP certificate #4943
validates, which lists 2.1.1 (accepted, 2026-10-17). Keycloak supports FIPS
on RHEL 8 and 9 hosts; this EL10 host is outside that statement, though
the container is UBI 9.
Heimdall, Vulcan and the proxy are built on Red Hat UBI 9, whose OpenSSL loads its FIPS
provider on a FIPS host (MD5 is refused inside them), and podman gives
them the host's FIPS crypto policy, which the proxy's TLS follows. Their
FIPS module is the RHEL 9 one inside each image, not the host's RHEL 10
module; that is documented here rather than recorded as a finding, because
the containers run a FIPS provider under the host's policy. The proxy uses
`ubi9/nginx-126` rather than upstream Heimdall's `nginx:alpine` for this
reason: Alpine's OpenSSL has no FIPS provider. Each application container
mounts the host's CA trust store read-only, so it trusts the same CAs as the
host, a site's own included (see [Site CA bundles](site-config.md)).
The three databases run the sclorg PostgreSQL 18 image built on CentOS
Stream 9 (`quay.io/sclorg/postgresql-18-c9s`), in place of the upstream
compose files' `postgres:17` (Heimdall) and `postgres:18-alpine` (Vulcan),
whose OpenSSL has no FIPS provider at all. Its OpenSSL runs its FIPS
provider on a FIPS host under the host's policy, so PostgreSQL refuses
MD5 and computes its SCRAM-SHA-256 password hashes and its digest
functions in FIPS mode (`safbox-heimdall-5`, `safbox-vulcan-4`,
`safbox-keycloak-6`). That provider is an unvalidated CentOS Stream build
of the RHEL 9 module: it runs in FIPS mode, and it carries no CMVP
certificate. Red Hat's own PostgreSQL images, whose module is RHEL's,
need a Red Hat account to pull and may not be redistributed in a
template, so SAFBox does not use them. Each application signs in to its
database as a role of its own that owns that database, with its password
and SCRAM-SHA-256 only, over the pod's loopback; the image's own access
list, which trusts every connection over the socket and the loopback, is
replaced (`templates/pg_hba.conf.j2`). One weakness remains.
Heimdall hashes passwords and API keys with bcrypt in pure JavaScript,
outside any FIPS provider (upstream
[mitre/heimdall2#4145](https://github.com/mitre/heimdall2/issues/4145),
draft fix [#4850](https://github.com/mitre/heimdall2/pull/4850)).

## Upstream compose files

Heimdall's and Vulcan's pods and the TLS proxy follow the services of the
applications' upstream compose files
([mitre/heimdall2](https://github.com/mitre/heimdall2/blob/master/docker-compose.yml),
[mitre/vulcan](https://github.com/mitre/vulcan/blob/master/docker-compose.yml)).
This table says, once, how each upstream setting maps to the Quadlet units
in `ansible/roles/template_services/templates/`, so a review against a new
upstream release starts here. Keycloak has no upstream compose file; its
units follow Keycloak's server guides and say so in their comments.

| Upstream service and key | SAFBox (Quadlet unit) | Why |
|---|---|---|
| Heimdall `server`: `image mitre/heimdall2:release-latest` | the same image pinned by digest (`safbox_image_heimdall`), `heimdall.container` | a retagged image cannot change what ships |
| Heimdall `server`: `restart: unless-stopped` | `Restart=always` | systemd's nearest: it restarts the container whenever it exits, and a unit stopped with `systemctl stop` stays stopped, as `unless-stopped` does |
| Heimdall `server`: `NODE_ENV=production` | the same | same behaviour |
| Heimdall `server`: `DATABASE_HOST=database` | `DATABASE_HOST=127.0.0.1` | the pod shares one network namespace with its database |
| Heimdall `server`: `DATABASE_USERNAME` unset (postgres) | `DATABASE_USERNAME`, Heimdall's own role | it signs in as a role that owns its database, not as the superuser |
| Heimdall `server`: `DATABASE_PASSWORD`, `env_file .env` | podman secrets first boot makes (`DATABASE_PASSWORD`, `JWT_SECRET`, `API_KEY_SECRET`, `ADMIN_PASSWORD`), each an environment variable (`Secret=`); `JWT_EXPIRE_TIME`, which upstream's setup script asks for, and `EXTERNAL_URL`, the proxy's name for Heimdall, set in the unit | no secret in the template; `podman inspect` masks them |
| Heimdall `server`: `ports "3000"` | published by the `heimdall` pod on `127.0.0.1:3000` only | reachable only through the proxy |
| Heimdall `server`: `depends_on database (healthy)` | `Requires=` and `After=heimdall-db.service` | the database unit is ready only once healthy (`Notify=healthy`), so `After=` waits for a healthy database, as `condition: service_healthy` does |
| Heimdall `server`: no healthcheck | a healthcheck that fetches its page, and `Notify=healthy` | the end of boot waits for a Heimdall that serves |
| Heimdall `server`: `cert_bundles` volume at `/etc/pki/ca-trust/extracted` (ro), filled by a certs sidecar | the host's extracted trust store, read-only at the same path (`template_os_container_trust_volume`) | the `template_os` role puts the site's CA bundles there, DoD's included, instead of the sidecar |
| Heimdall `database`: `image postgres:17` | the sclorg PostgreSQL 18 image on CentOS Stream 9, pinned by digest (`safbox_image_postgresql`), `heimdall-db.container`; its variables are `POSTGRESQL_*`, its data `/var/lib/pgsql/data`, its user 26 | the Debian-based image's OpenSSL has no FIPS provider; this one's runs it on a FIPS host |
| Heimdall `database`: `restart: unless-stopped` | `Restart=always` | systemd's nearest: it restarts the container whenever it exits, and a unit stopped with `systemctl stop` stays stopped, as `unless-stopped` does |
| Heimdall `database`: `healthcheck pg_isready -U postgres`, every 30s, timeout 60s, 5 retries, start period 80s | `pg_isready` over the pod's loopback as Heimdall's role, the same timings, and `Notify=healthy` | the image's first start runs a socket-only server, so only TCP means ready |
| Heimdall `database`: `volumes ./data` | the `heimdall-db` named volume | kept under podman's storage, created on the first start after first boot |
| Heimdall `database`: `POSTGRES_DB`, `PGDATA` | `POSTGRESQL_DATABASE`, the same name; the image sets its own data path | the sclorg image names its variables and data path itself; same database name |
| Heimdall `database`: `POSTGRES_PASSWORD=${DATABASE_PASSWORD}` | `POSTGRESQL_PASSWORD` from the database password secret, which Heimdall reads too, with `POSTGRESQL_USER` | Heimdall's own role, not postgres |
| Heimdall `database`: `expose "5432"` | reachable inside the pod only | same behaviour: only the application reaches its database |
| Heimdall: the project's default network | the `heimdall` network, the pod alone on it | no other container reaches its database |
| Heimdall `nginx` | the TLS proxy, `safbox-proxy.container` (below) | one TLS proxy for every application |
| Vulcan `web`: image built from the Dockerfile | the published release image, pinned by digest (`safbox_image_vulcan`), `vulcan.container` | pulled and pinned like every other image, instead of building Vulcan from source at image build |
| Vulcan `web`: `restart: unless-stopped` | `Restart=always` | systemd's nearest: it restarts the container whenever it exits, and a unit stopped with `systemctl stop` stays stopped, as `unless-stopped` does |
| Vulcan `web`: `DATABASE_URL` with the password | `DATABASE_HOST=127.0.0.1`, `POSTGRES_USER` and `POSTGRES_PASSWORD`, which `config/database.yml` reads; the user is Vulcan's own role | the pod shares one network namespace; not the superuser |
| Vulcan `web`: `NODE_ENV=production` | the same | same behaviour |
| Vulcan `web`: `RAILS_FORCE_SSL` | `true` | the proxy terminates HTTPS and sends `X-Forwarded-Proto`, as upstream's proxy profiles do |
| Vulcan `web`: `env_file .env` | secrets: podman secrets first boot makes (`setup-docker-secrets.sh`'s four and the administrator's password), each an environment variable; settings: `template_services_vulcan_settings` | no secret in the template; `podman inspect` masks them; Vulcan reads its secrets from its environment, with no `.env` file in production |
| Vulcan `web`: `ports 3000` (expose behind a proxy) | published by the `vulcan` pod on `127.0.0.1:3001` only | the port upstream suggests beside another service on 3000 (`VULCAN_PORT=3001`) |
| Vulcan `web`: `depends_on db (healthy)` | `Requires=` and `After=vulcan-db.service` | as for Heimdall: `After=` waits for a healthy database |
| Vulcan `web`: `certs/` copied into the image's store at build | the host's extracted trust store, read-only where the image reads its own (`template_os_container_trust_volume`) | the site's CA bundles reach it without a rebuild |
| Vulcan `web`: healthcheck `curl /up`, every 30s, timeout 10s, 3 retries, start period 60s | the same, and `Notify=healthy` | with `RAILS_FORCE_SSL`, `/up` answers plain HTTP with a redirect, which `curl -f` accepts |
| Vulcan `db`: `image postgres:18-alpine` | the sclorg PostgreSQL 18 image, as Heimdall's (`vulcan-db.container`), with glibc's collations rather than musl's | Alpine's OpenSSL has no FIPS provider |
| Vulcan `db`: `restart: unless-stopped` | `Restart=always` | systemd's nearest: it restarts the container whenever it exits, and a unit stopped with `systemctl stop` stays stopped, as `unless-stopped` does |
| Vulcan `db`: `volumes vulcan_dbdata:/var/lib/postgresql` | the `vulcan-db` named volume | same behaviour: a named volume under podman's storage, created on the first start after first boot |
| Vulcan `db`: `POSTGRES_USER`, `POSTGRES_DB` (postgres, vulcan_production) | `POSTGRESQL_USER` and `POSTGRESQL_DATABASE` | Vulcan signs in as a role that owns `vulcan_production`, not as postgres |
| Vulcan `db`: `POSTGRES_PASSWORD` | `POSTGRESQL_PASSWORD` from the database password secret, which Vulcan reads too | the sclorg image's variable; one secret that Vulcan and its database both read |
| Vulcan `db`: `expose "5432"` | reachable inside the pod only | same behaviour: only the application reaches its database |
| Vulcan `db`: healthcheck `pg_isready`, every 30s, timeout 10s, 5 retries | `pg_isready` over the pod's loopback as Vulcan's role, the same timings, `Notify=healthy` | as for Heimdall's database |
| Vulcan: the project's default network | the `vulcan` network, the pod alone on it | no other container reaches its database |
| Vulcan `caddy` and `nginx` profiles | the TLS proxy (below) | one TLS proxy for every application |
| Heimdall `nginx` and Vulcan's `nginx` profile: `image nginx:alpine` | Red Hat UBI 9 nginx, pinned by digest (`safbox_image_proxy`), `safbox-proxy.container`, one container for every application | its OpenSSL runs the FIPS provider on a FIPS host; TLS terminates in one place |
| proxy: `ports 80, 443` | the same, on the host network; 443 serves each application by name, 80 redirects (`nginx.conf`) | the host network reaches the pods' loopback-only ports |
| proxy: templates and certs volumes | `nginx.conf` and the start page (`template_services` role) and the certificate first boot makes, all read-only | the configuration comes from the build and the certificate from first boot, so neither is baked into the image; read-only, since the proxy only reads them |
