# Services on the box

The `services` role runs each application and its PostgreSQL as a podman
pod of Quadlet units (`tasks/heimdall.yml`, `tasks/vulcan.yml`), in the
service shape of the application's upstream `docker-compose.yml` (each unit
file cites the compose service it reproduces), Keycloak and its PostgreSQL
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
opens with; users can change it. The applications' bookmarks follow
their switches, and they and the start page's need the proxy. Users keep
their own bookmarks beside them. The distribution's default bookmarks
(Rocky Linux's links, for example) are dropped (`NoDefaultBookmarks`):
Firefox imports them on first run at the same time as it creates the
box's, and one of the box's was lost.

**First boot.** The units are installed and enabled at build but start only
once their secrets exist (`ConditionPathExists`, ordered after
`safbox-firstboot.service`). First boot ([First boot](appliance.md#first-boot))
runs one step per service, the only place its secrets are generated:

- `20-heimdall.sh` writes `/etc/safbox/heimdall.env` (`DATABASE_PASSWORD`,
  `JWT_SECRET`, `API_KEY_SECRET`, `ADMIN_PASSWORD`),
  `/etc/safbox/heimdall-db.env`, and `/etc/safbox/heimdall-oidc.env`
  (`OIDC_CLIENT_SECRET`, Heimdall's client secret in Keycloak, which
  Keycloak reads too);
- `30-vulcan.sh` writes `/etc/safbox/vulcan.env` (`POSTGRES_PASSWORD`,
  `SECRET_KEY_BASE`, `CIPHER_PASSWORD`, `CIPHER_SALT`,
  `VULCAN_ADMIN_PASSWORD`), `/etc/safbox/vulcan-db.env`, and
  `/etc/safbox/vulcan-oidc.env` (`VULCAN_OIDC_CLIENT_SECRET`);
- `50-keycloak.sh` writes `/etc/safbox/keycloak.env` (`KC_DB_PASSWORD`,
  `KC_BOOTSTRAP_ADMIN_PASSWORD`, `SAFUSER_PASSWORD`) and
  `/etc/safbox/keycloak-db.env`;
- the `40-proxy` step (the first-boot play's `proxy_tls` role) writes a
  local CA (`/etc/safbox/ca/ca.crt` and its key `ca.key`, valid ten
  years, in a root-only directory the proxy container does not mount,
  limited to names under `safbox_domain`) and a certificate it signs for
  exactly the served names (listed in `/etc/safbox/proxy-names`) to
  `/etc/safbox/tls/safbox.crt`, its RSA 3072 key to `safbox.key` (root
  only), and adds the CA to the system
  trust store (`/etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt`,
  outside the `safbox-*` anchors the site_config role manages).

All of them are root-owned and mode 0600 (the certificate 0644), use the
same random strength as the upstream setup scripts, and never overwrite an
existing value. The seal removes and then asserts the absence of every
`/etc/safbox/*.env` file, of `/etc/safbox/tls` and `/etc/safbox/ca`, and
of the local CA's trust anchor, so the template holds none.

**Your own certificate.** Replace `safbox.crt` and `safbox.key` in
`/etc/safbox/tls/` with your certificate (PEM, with any intermediates
after it) and unencrypted key, owned by root, the key mode 0600, then
`systemctl restart safbox-proxy.service`. Then retire the local CA, which
nothing needs any more:

```
rm -f /etc/safbox/ca/ca.key /etc/safbox/ca/ca.crt /etc/pki/ca-trust/source/anchors/local-ca-safbox-proxy.crt
(umask 022; update-ca-trust extract)
```

First boot trusts the local CA only while the proxy's certificate is one
it signed, so running its step again with your certificate in place does
not bring the CA back. Whenever the CA is trusted, the step checks that the
system trust store as extracted (the bundle every client reads) verifies
the certificate, and rebuilds the store when it does not. To regenerate the box's own certificate after
switching an application on later (the certificate names only the
applications that were on at first boot), delete `safbox.crt` and
`safbox.key`, run the `40-proxy` step again as root
([Running steps again](appliance.md#first-boot)), and restart the proxy. The local CA is kept, so machines that already trust
it keep trusting the box. After changing `safbox_domain`, delete the
local CA's two files in `/etc/safbox/ca/` as well, since it may sign only
names under the old domain; the step then makes and trusts a new one.

**A box deployed from an older template** (one that served each
application on its own port) keeps its old self-signed certificate,
without the names and not trusted by the box, and its 8443 and 9443
firewall entries after the roles are applied again. As root, regenerate
the certificate as above (which also creates and trusts the local CA),
then close the old ports:

```
firewall-cmd --permanent --remove-port=8443/tcp --remove-port=9443/tcp && firewall-cmd --reload
```

**Accounts.** Each application is made with one local account, its
administrator, `admin@safbox.internal` (`admin@` the domain), made on its
first start with the password first boot wrote, as the way in while
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
sudo grep '^ADMIN_PASSWORD=' /etc/safbox/heimdall.env
sudo grep '^VULCAN_ADMIN_PASSWORD=' /etc/safbox/vulcan.env
```

Heimdall asks its administrator for a new password at the first sign-in.
It also prints the administrator's password in its log on the first start
(`journalctl -u heimdall.service`), even when given one: upstream
behaviour, so change it at that first sign-in. A box deployed before this
change made its administrators the old way (Heimdall's
`admin@heimdall.local` with a random password in its log; Vulcan's first
registered user), and keeps them. LDAP and SMTP are site settings
(`services_vulcan_settings` in the services role's defaults).

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
sudo grep '^SAFUSER_PASSWORD=' /etc/safbox/keycloak.env
```

That password is one-time: the realm makes `safuser` choose a new one at
its first sign-in (the update-password required action), and the file,
as a comment in it says, keeps the initial password only. `safuser` signs
in at its account page, `https://keycloak.safbox.internal/realms/safbox/account/`
(the Keycloak bookmark), and changes its password there later (Account
security, Signing in, Password, Update; [Accounts](accounts.md#accounts-in-the-applications)).
`https://keycloak.safbox.internal/` sends the browser to that page. The
realm refuses registration, locks an account briefly after quick wrong
passwords, and asks for 15 characters, not the user name; FIPS strict
mode hashes passwords with PBKDF2-SHA512. Keycloak's administration
console and its master realm answer to the box itself only: open
`https://keycloak.safbox.internal/admin/master/console/` in the box's own
browser and sign in as `temp-admin` with `KC_BOOTSTRAP_ADMIN_PASSWORD`
from the same file, the temporary administrator Keycloak makes on its
first start. That sign-in is the master realm's: `safuser` does not exist
there. Inside the Heimdall and
Vulcan pods, Keycloak's name points at the host (`AddHost`), so they reach
it at the issuer URL the browser uses. Changing the realm file later does
not change a running box's realm: use the console. With Keycloak switched
off, both applications keep local sign-in for their administrators (and
Vulcan its self-registration, Accounts above).

**Footprint.** Measured on a 2 vCPU, 4 GiB development clone with both
applications idle after the service tests: about 750 MB in the containers
(Heimdall 290 MB, Vulcan 280 MB, the databases 75 and 80 MB, nginx 25 MB),
2.5 GiB of the host's memory still available (before Keycloak). The
container memory limits (`services_heimdall_memory`,
`services_vulcan_memory`, 1g; `services_keycloak_memory`, 768m; the three
databases 512m each; nginx 512m) sum to about 4.8 GiB. Keycloak sizes its
Java heap from its limit; at 768m it used about 0.6 GiB with its database
under repeated sign-ins (docs/spikes/keycloak-sso.md, Finding 6).

**Switching a service off applies at build time.** The services' switches
(`safbox_services_1` to `safbox_services_5`) decide what a template is
built with. Setting one to `false` and applying the roles again to a box
that already has the service does not remove it: no task deletes its
units, image or first-boot hook, so it keeps running, and nothing
reconfigures the services left on to match. Keycloak switched off this
way keeps its units, image and hook, and the proxy certificate keeps its
name. To drop a service, build a new template without it.

**Applying the roles to a box that has already booted.** The first-boot
play does nothing once `/var/lib/safbox/firstboot.done` exists, so on
such a box run every step again with `firstboot_rerun`, which leaves the
marker alone, then start the services (or reboot):

```
sudo env ANSIBLE_CONFIG=/usr/local/lib/safbox/firstboot/ansible.cfg \
  ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml -e firstboot_rerun=true
sudo systemctl start heimdall.service vulcan.service safbox-proxy.service
```

**A box built before the databases moved to the sclorg PostgreSQL image
loses their data.** The new image keeps its data in another layout, owned
by another user, at PostgreSQL 18 (Heimdall's and Keycloak's were 17), and
takes its password from another variable, so it cannot start on the old
volumes. There is no migration: like the switches, the change is meant
for a new template. To apply it to such a box anyway, accept that
Heimdall's evaluations, Vulcan's projects and Keycloak's realm and users
are lost (each application starts again as on first boot, with the same
secrets), and remove the old databases and their password files before
applying the roles, then run every first-boot step again as above and
restart the pods:

```
sudo systemctl stop heimdall-pod.service vulcan-pod.service keycloak-pod.service \
  heimdall-db-volume.service vulcan-db-volume.service keycloak-db-volume.service
sudo podman volume rm heimdall-db vulcan-db keycloak-db
sudo rm /etc/safbox/heimdall-db.env /etc/safbox/vulcan-db.env /etc/safbox/keycloak-db.env
# apply the roles, run first boot as above, then:
sudo systemctl restart heimdall-pod.service vulcan-pod.service keycloak-pod.service
```

**Testing.** The release gate's safbox profile checks the units, secrets,
loopback-only ports, each name over HTTPS, the redirects, the start page,
the certificate's names, `/etc/hosts` and the firewall from a shell on the
box, and that Heimdall offers local log in and refuses a sign-up. Its
client profile, `verify/profiles/safbox-client`, then acts as a browser
would, from your workstation over HTTPS only: it checks the proxy's TLS
(TLS 1.3 negotiated with a certificate for each name; TLS 1.0, 1.1 and
ChaCha20 refused), that only ports 80 and 443 answer, that plain HTTP is
redirected, and loads each application's page with its scripts and
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
the run, so each run expects a fresh box). With that password `safuser`
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
