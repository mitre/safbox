# Spike: Keycloak as SAFBox's local single sign-on

Card: safbox-m5f.42. Run on 2026-10-16 (UTC) on clone 9170 of template 9006.
This is a spike. It ships no role. The throwaway units, realm and scripts it
used are reproduced below where they matter. The evidence, with timestamps,
is in the card's notes.

**Answer: yes.** Keycloak 26.8.1 ran on an EL10 FIPS host in FIPS strict
mode (BouncyCastle FIPS in Approved Mode), as a Quadlet pod with its own
PostgreSQL behind the box's nginx proxy. One initial user, `safuser`, with a
password generated on the clone, logged in to both Heimdall and Vulcan
through OIDC. That worked from the box itself, from another machine, after
reboots, and in 20 rounds of repeated logins. A wrong password and an
unknown user were refused.

**Recommendation: go**, subject to the owner decisions at the end, chiefly
the memory budget and the validated-module caveat (Findings 1 and 6).

## What was run

| Item | Value |
|---|---|
| Host | Clone 9170 of template 9006. Rocky Linux 10.2, kernel 6.12.0-211.66.1.el10_2, `fips_enabled=1`, crypto policy FIPS, podman 5.8.2, 8 vCPU, 15.3 GiB RAM |
| Appliance layer | The owner's review set (main f2acd43 plus the staged and unstaged changes), applied with the playbook. Recap: ok=509, changed=31, failed=0 |
| Keycloak | `quay.io/keycloak/keycloak@sha256:79c623a22abacf3fe6c00a5fb30f5b7843d717b234033b80995891c06116d244` (26.8.1, released 2026-10-13; UBI 9 micro; Red Hat OpenJDK 21.0.12.1), plus the four BCFIPS jars, built on the clone |
| Keycloak's database | The PostgreSQL 17.11 image Heimdall already pins (`docker.io/library/postgres@sha256:2d2b8998...`), as a second container in the pod |
| Apps | Heimdall 2.14.0 and Vulcan 2.4.1, the pinned images, unchanged; OIDC settings added through Quadlet drop-ins |
| Names | `keycloak.safbox.internal` beside `heimdall.` and `vulcan.safbox.internal`, behind the same nginx, with a certificate signed by the box's local CA |

The steps, in order:

1. **RED.** Both apps were configured for OIDC against a Keycloak that did
   not exist yet. Both logins failed.
2. The derived image was built and the Keycloak pod started.
3. **GREEN.** Both logins passed.
4. Negative checks, logins from another machine, two reboots, then
   measurements.

## Findings

### 1. FIPS strict mode works on the EL10 FIPS host

Keycloak's startup log, at every start (first start 2026-10-16 22:25:30Z,
the latest after the second reboot at 22:39:48Z):

```text
INFO  [org.keycloak.crypto.fips.FIPS1402Provider] (main) FIPS1402Provider created: KC(BCFIPS version 2.0103 Approved Mode, FIPS-JVM: enabled)
DEBUG [org.keycloak.common.crypto.CryptoIntegration] (main) Using the crypto provider: org.keycloak.crypto.fips.Fips1402StrictCryptoProvider
TRACE Java security providers: [ BCFIPS version 2.0103, BCJSSE version 2.0125, SunPKCS11-NSS-FIPS version 21, SUN, SunEC, SunJSSE, SunJCE, SunRsaSign, XMLDSig ]
```

`FIPS-JVM: enabled` means the JVM switched to its FIPS configuration by
itself. The container inherits FIPS mode from the host, and Red Hat's
OpenJDK in the UBI 9 image picks it up. No `java.security` changes were
needed. The SunPKCS11-NSS-FIPS provider is the strong random source:
"Strong secure random not available ... Using algorithm as a fallback for
strong secure random: PKCS11:SunPKCS11-NSS-FIPS".

**What it takes** (Keycloak's FIPS guide, [K1]):

- The four BouncyCastle FIPS jars at exactly the versions Keycloak's
  `pom.xml` names for 26.8.1 [K2]: bc-fips 2.1.3, bctls-fips 2.1.25,
  bcpkix-fips 2.1.13 and bcutil-fips 2.1.8.
  - They are downloaded from Maven Central and checked against these sums,
    which match Maven Central's own `.sha256` files:

    ```text
    f55fc476ede820d5c03fe87e6ced5bb0095e1dc30b387445846a3ff0274f8c0e  bc-fips-2.1.3.jar
    af604aa5b337725872651067a819ebc03aa298685572b0b2ad5343c786faad0a  bctls-fips-2.1.25.jar
    cf161ba2f6b4505816f4661663b3e0771184a50ee5b178a0018c817b336f0e5c  bcpkix-fips-2.1.13.jar
    f44904f61552c823bcc3686a24052ee3135212d547754eaa2ff6532e210103cb  bcutil-fips-2.1.8.jar
    ```

- A derived image, after the guide's container example. The base is pinned
  by digest and the build runs `kc.sh build` with the FIPS options, so the
  server starts with `start --optimized`:

  ```dockerfile
  FROM quay.io/keycloak/keycloak@sha256:79c623a2... AS builder
  COPY --chown=1000:0 --chmod=0644 bc-fips-2.1.3.jar bctls-fips-2.1.25.jar bcpkix-fips-2.1.13.jar bcutil-fips-2.1.8.jar /opt/keycloak/providers/
  RUN /opt/keycloak/bin/kc.sh build --features=fips --fips-mode=strict --db=postgres --health-enabled=true
  FROM quay.io/keycloak/keycloak@sha256:79c623a2...
  COPY --from=builder /opt/keycloak/ /opt/keycloak/
  ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
  ```

  - `podman build` on the clone took 16 s.
  - The first attempt failed with `Failed to read .../providers/bc-fips-2.1.3.jar
    (Permission denied)`. The box's STIG umask (077) had made the
    downloaded jars 0600, and the build step runs as uid 1000. Hence the
    explicit `--chown`/`--chmod`. Upstream's example uses `cp` as the
    image's user, which hides this.
  - The built image is not bit-for-bit reproducible (build timestamps), so
    the build-out pins its inputs, not its output digest.

**Is it distributable?** Yes, on the licences.

- The BouncyCastle FIPS jars are published under the Bouncy Castle Licence,
  which is MIT [B1, B2].
- Keycloak is Apache-2.0, and the UBI 9 micro base is freely
  redistributable.
- Keycloak's guide says the FIPS library "is not shipped with Keycloak as
  Keycloak cannot provide official support of it" [K1]. That is a support
  statement, not a licence restriction.
- Redistributing is fine only while the jars are unmodified: the CMVP
  validation covers the jar as published.

**Caveats to track** (not defects worked around here):

- **The certified jar version and the required one differ.** CMVP
  certificate #4943 (BC-FJA, FIPS 140-3, Active, interim validation, sunset
  2030-01-16) lists software version **2.1.1** only. Its tested
  environments are Java 8, 11, 17 and 21 on Ubuntu 22.04 [B3]. Keycloak
  26.8.1 requires bc-fips **2.1.3** [K2], a later patch release of the
  same 2.1 line. A strict reading of "uses a validated module" needs either
  2.1.3 added to the certificate or a Keycloak release on 2.1.1. This is an
  owner decision (Decision 6); nothing here pins a different version than
  Keycloak's.
- **EL10 hosts are outside Keycloak's support statement.** The guide says
  Keycloak "is supported and tested on a FIPS enabled RHEL 8 system and
  `ubi8` image. It is supported with RHEL 9 (and `ubi9` image) as well"
  [K1]. The container is UBI 9. The EL10 host only supplies the kernel FIPS
  flag and the crypto policy podman maps in. The other appliance images
  (nginx, Heimdall, Vulcan) are UBI 9 or RHEL 9 the same way.
- **Kerberos is off.** The log warns "Kerberos feature not supported by
  JDK" (no SunJGSS in FIPS mode), as the guide says it would be. SAFBox does
  not use Kerberos.
- **Strict-mode limits that shape the build-out** [K1]:
  - user passwords must be at least 14 characters;
  - argon2, Keycloak's default password hash, is not allowed (the realm
    sets `hashAlgorithm(pbkdf2-sha512)`);
  - RSA keys must be at least 2048 bits;
  - `jks` and `pkcs12` keystores are not allowed. Keycloak here serves
    plain HTTP on loopback behind the proxy, so it needs no keystore.

### 2. safuser logs in to Heimdall and Vulcan through Keycloak

The test drives the real browser flow with curl (`login.sh`, below):

1. start the app's OIDC sign-in;
2. follow the redirect to Keycloak's login form;
3. post the credentials;
4. follow the redirects back to the app;
5. ask the app who is signed in.

The password is read from the root-only `/etc/safbox/keycloak.env` and is
never printed.

| When (UTC) | Where from | Heimdall | Vulcan |
|---|---|---|---|
| 22:23:03 (RED) | the box | FAIL: redirected to `https://keycloak.safbox.internal/realms/safbox/protocol/openid-connect/auth?...` and got 404 (no provider) | FAIL: `OpenIDConnect::Discovery::DiscoveryFailed, Not Found` |
| 22:26:15 | the box | PASS: `signed in as safuser@safbox.internal (creationMethod oidc, user id 2)` | PASS: `GET / answered 200 and names safuser@safbox.internal` |
| 22:27:02 | the box, wrong password or unknown user | FAIL (stays on Keycloak's form) | FAIL (stays on Keycloak's form) |
| 22:29:17 | another machine (names resolved to the clone, box CA trusted) | PASS | PASS |
| 22:30:54 to 22:31:37 | the box, 20 rounds of both apps, 4 at a time | 20 passed | 20 passed |
| 22:40:02 | the box, after the second reboot | PASS | PASS |

In the apps afterwards:

- Heimdall has `safuser@safbox.internal | user | oidc` beside its seeded
  `admin@heimdall.local | admin | local`.
- Vulcan has `safuser@safbox.internal | admin=t | oidc`. Vulcan's
  `VULCAN_FIRST_USER_ADMIN=true` made the first account an administrator.

Keycloak's brute-force protection works. Two wrong passwords within a
second triggered its quick-login check and locked safuser for 60 s
(`user_temporarily_disabled`), which briefly failed a test that followed.

### 3. One issuer URL from the browser and from both app containers

The issuer is `https://keycloak.safbox.internal/realms/safbox` for every
party. It is the URL in the discovery document and the one both apps are
configured with.

- **On the box (its browser):** `/etc/hosts` maps the name to 127.0.0.1,
  where nginx listens. The name must also go in cloud-init's hosts template
  (`/etc/cloud/templates/hosts.redhat.tmpl`), as the services role already
  does for the other names. The spike first edited only `/etc/hosts`; after
  the next reboot the box could not resolve the name (cloud-init rewrote
  the file), while the containers still could. Editing both files fixed it,
  and the second reboot proved that.
- **Inside the app containers:** podman copies the host's `/etc/hosts` line
  into each container, so the name also maps to 127.0.0.1 there. Inside a
  pod, that is the pod itself, where nothing listens on 443. Each app pod
  therefore gets a Quadlet drop-in:

  ```ini
  [Pod]
  AddHost=keycloak.safbox.internal:host-gateway
  ```

  podman puts this line first, so it wins: 10.89.1.1 in the heimdall pod,
  10.89.0.1 in the vulcan pod. Those are the host's addresses on each pod
  network, where nginx (host network) answers on 443 and the firewall lets
  it through.
- **Proof:** from inside each container, the discovery document was
  fetched over verified TLS and printed the same issuer.
  - Heimdall: Node `fetch`.
  - Vulcan: Ruby `Net::HTTP` with `VERIFY_PEER`.
  - Vulcan's own OIDC discovery and Heimdall's token and userinfo calls go
    the same way.
- **Another machine** reaches the box by the same names through its own DNS
  or hosts file (`docs/reference/services.md`, "Names"). The run from this workstation
  passed with `curl --resolve`.

Only the two app pods need the `AddHost` drop-in, and only for the
provider's name: the browser never talks to the app containers.

### 4. Both apps trust the box's first-boot CA

1. `40-proxy.sh` (first boot) signs the proxy certificate with the box's
   local CA and anchors that CA in the host trust store. Adding
   `keycloak.safbox.internal` to `/etc/safbox/proxy-names` and running the
   hook again (with the old certificate removed, as its header says) gave a
   certificate naming all four names, signed by `CN=SAFBox local CA
   (safbox.internal)`.
2. Both app units already mount the host's extracted trust store read-only
   (`platform_container_trust_volume`, `/etc/pki/ca-trust/extracted`). Both
   images are RHEL 9.8, so they read that path. The local CA was present in
   each container's `tls-ca-bundle.pem`.
3. How each runtime reaches the store:
   - Vulcan's Ruby: `OpenSSL::X509::DEFAULT_CERT_FILE` is
     `/etc/pki/tls/cert.pem`, a link into it.
   - Heimdall's Node 22.23.1: built against the shared system OpenSSL
     (`node_shared_openssl: true`, OpenSSL 3.5.5, `getFips()` 1). It
     verified the CA with no `NODE_EXTRA_CA_CERTS` and no `NODE_OPTIONS`.

No change to either app's trust was needed.

### 5. The proxy route, and a trusted-address trap

The route is a fourth name-based server in the proxy's `nginx.conf`, after
Keycloak's reverse-proxy guide [K3]:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name keycloak.safbox.internal;
    location / {
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
```

Keycloak runs with these settings:

- `KC_HOSTNAME=https://keycloak.safbox.internal`
- `KC_HTTP_ENABLED=true`
- `KC_PROXY_HEADERS=xforwarded`
- `KC_PROXY_TRUSTED_ADDRESSES`, which limits the addresses whose forwarded
  headers it believes.

**The trap:** the proxy connects to the pod's port published on
127.0.0.1, but Keycloak sees the connection come from the pod network's
gateway, not from 127.0.0.1. With `KC_PROXY_TRUSTED_ADDRESSES=127.0.0.0/8`,
Keycloak ignored the forwarded headers. Logins still worked, but the log
said "Non-secure context detected; cookies are not secured" and the session
cookies lacked `Secure`.

**The fix:**

- the keycloak network gets a fixed subnet (`Subnet=10.89.42.0/24`,
  `Gateway=10.89.42.1` in `keycloak.network`);
- Keycloak trusts that gateway alone
  (`KC_PROXY_TRUSTED_ADDRESSES=10.89.42.1`).

After the fix, the cookies are `Secure;HttpOnly;SameSite=None` and the
warning is gone. The build-out must keep this.

### 6. Footprint

Measured on the clone. "podman stats" is the container's view; "cgroup" is
the systemd unit's `memory.current` and `memory.peak`.

| | Keycloak | Its PostgreSQL | Both |
|---|---|---|---|
| Idle (22:29:53Z): podman stats | 601 MB | 34 MB | 635 MB |
| Idle: cgroup current / peak | 574 / 704 MiB (peak at startup) | 50 / 62 MiB | 624 / 766 MiB |
| During 20 login rounds (22:30:54Z to 22:31:37Z) | max 634 MB, max 41 % of one CPU | 34 MB | about 670 MB |
| Memory limit set in the spike | 1536 MiB | 512 MiB | 2 GiB |
| Disk: images | 478 MB base + 14 MB derived layers | 0 (Heimdall's image, already on the box) | 492 MB |
| Disk: data volume | | 69 MiB after the realm import and the logins | 69 MiB |
| Disk: `/var` before the build to after the measurements | | | 3189 to 3760 MiB (+571 MiB) |

For scale, on the same clone: Heimdall 204 MB and Vulcan 240 MB.

**Against the references:**

**Most of Keycloak's figure follows from the limit, not from need.** In a
container, Keycloak 26.8.1's `kc.sh` sets the heap from the container's
memory: `-XX:MaxRAMPercentage=70 -XX:MinRAMPercentage=70
-XX:InitialRAMPercentage=50` [K5]. With the spike's 1536 MiB limit, the
heap starts at 768 MiB. A lower limit gives a smaller heap.

**A lower limit, measured** (22:44:31Z to 22:46:03Z): with Keycloak's limit
at 768 MiB, Approved Mode as before:

- idle 530 MB;
- the same 20 login rounds all passed;
- max 595 MB in the 1 s samples, cgroup `memory.peak` 569 MiB;
- no out-of-memory lines.

So 768 MiB plus the database's 512 MiB (1.25 GiB of limits, about 0.6 GiB
used) is a workable budget for a single-user appliance. Lower limits were
not tried.

**Against the references, with the spike's limits:**

- **16 GiB (the card's reference, this clone):** Keycloak and its database
  use about 0.75 GiB at peak, under 5 % of RAM. Their limits (2 GiB) bring
  the box's total of container memory limits from 3.5 GiB (Heimdall 1g +
  512m, Vulcan 1g + 512m, proxy 512m) to 5.5 GiB.
- **8 GB (the reference footprint):** it fits, but the limits then
  claim about 70 % of RAM before a scan runs.
- **4 GiB (the services role's comment on limits):** the limits would sum
  to 5.5 GiB, so Keycloak does not fit there with these limits.

**Other savings for the build-out:**

- Keycloak started its embedded cluster stack (JGroups `jdbc-ping`, with
  mTLS, listening on 7800 and 57800 inside the pod). A single node needs
  none of it: `KC_CACHE=local` should drop it. Not measured here.

### 7. What first boot must generate

The spike's hook `50-keycloak.sh` follows `20-heimdall.sh` and
`30-vulcan.sh`:

- it uses the base role's `secrets.sh` (`safbox_ensure_secret`,
  `openssl rand -hex`, the FIPS DRBG);
- it writes root-only 0600 files under `/etc/safbox`;
- it is idempotent, and safbox-firstboot runs it once.

| Secret or setting | Generated | Written to | Read by | safbox-m5f.16 note |
|---|---|---|---|---|
| Keycloak database password | `rand -hex 33` | `keycloak.env` (`KC_DB_PASSWORD`), `keycloak-db.env` (`POSTGRES_PASSWORD`) | Keycloak, PostgreSQL (env only) | env file today; a podman secret later: the official postgres image takes `POSTGRES_PASSWORD_FILE`, while Keycloak reads env or its config keystore |
| Keycloak bootstrap admin password | `rand -hex 24` | `keycloak.env` (`KC_BOOTSTRAP_ADMIN_PASSWORD`; user `temp-admin`) | Keycloak, first start only | Keycloak creates a *temporary* admin in the master realm. The build-out either documents retrieving it, or replaces it with a permanent admin and deletes the temporary one |
| Heimdall client secret | `rand -hex 32` (64 characters; strict mode needs 14 or more) | `keycloak.env` (`HEIMDALL_CLIENT_SECRET`) and `heimdall.env` (`OIDC_CLIENT_SECRET`) | the realm import (placeholder), Heimdall | the same value in two env files |
| Vulcan client secret | `rand -hex 32` | `keycloak.env` (`VULCAN_CLIENT_SECRET`) and `vulcan.env` (`VULCAN_OIDC_CLIENT_SECRET`) | the realm import, Vulcan | the same |
| safuser's Keycloak password | `rand -hex 16` (32 characters) | `keycloak.env` (`SAFUSER_PASSWORD`) | the realm import, on first start only | see Finding 8. After the import it lives hashed (pbkdf2-sha512) in Keycloak's database, and the env file holds the initial value |
| Realm | not a secret | `/etc/safbox-keycloak/safbox-realm.json`, with `${...}` placeholders filled from Keycloak's environment [K4] | Keycloak `--import-realm` (strategy IGNORE_EXISTING; later starts skip it) | |
| Host name, issuer, redirect URIs | from `safbox_domain` at build | the realm file, the apps' settings, `proxy-names`, both hosts files | everything | one place: `services_proxy_apps` |
| Certificate naming the new host | `40-proxy.sh`, unchanged | `/etc/safbox/tls` | the proxy | the new name only has to be in `services_proxy_names` before first boot |

Notes:

- The realm needs no IP address: everything is by name.
- Every value above is an env-file secret, the pattern safbox-m5f.16
  measured as plaintext in `podman inspect` (`Config.Env`). The build-out
  should follow whatever m5f.16 decides for Heimdall and Vulcan, not invent
  a third way.
- Keycloak's realm import reads secrets only from its environment, so
  `type=env` podman secrets are the natural fit for it.

### 8. The initial user, safuser

Owner addition: "Configure it so there is one initial user (safuser) who
can log into Heimdall or Vulcan with that account. It gets a unique password
on clone just like the os user."

- **One user, created by the realm import:** `safuser`, email
  `safuser@safbox.internal`, marked verified, first and last name "SAF
  User".
  - Heimdall refuses an OIDC login unless the provider says
    `email_verified` (`apps/backend/src/authn/oidc.strategy.ts`, unless
    `OIDC_USES_VERIFIED_EMAIL=false`) [H2].
  - Both apps key the account on the email.
- **No forced change at first login** (`temporary: false`), matching the
  owner's rule for the OS account (safbox-m5f.45).
- **Unique per clone:** the password is drawn on the clone by the
  first-boot hook, never at build. The template has no Keycloak data at all,
  because the database volume is created on first start.
- **How the operator gets it:** `sudo grep ^SAFUSER_PASSWORD=
  /etc/safbox/keycloak.env`. The build-out should share one retrieval
  method with the OS safuser, the GRUB password and m5f.16 (safbox-m5f.45's
  open question).
- **A deployer-supplied password** would follow m5f.45's pattern: the
  deployer supplies it, else first boot generates it.
  - Proxmox's `cipassword` reaches the guest only as a crypt hash
    (m5f.45's notes: `$5$`, or a `$6$` passed through), and Keycloak cannot
    take a crypt hash.
  - So a supplied Keycloak password needs a plaintext channel: cloud-init
    `write_files` to a root-only file that the hook reads before
    generating. Not exercised in the spike.

## Comparison: Keycloak, Authelia, Kanidm, 389 Directory Server

Every FIPS statement below is from the cited source, fetched on 2026-10-16.

| | Keycloak 26.8.1 | Authelia 4.39 | Kanidm 1.11 | 389 Directory Server (LDAP only) |
|---|---|---|---|---|
| Documented FIPS mode | Yes: `--features=fips --fips-mode=strict`, BCFIPS in approved mode on a FIPS-enabled RHEL-family host [K1]. Proven here on EL10 | None found. Its password guide mentions FIPS once: "PBKDF2 is practically the only choice when it comes to FIPS-140 compliance" [A1]. A search of its issues finds no FIPS mode [A2]. It is Go, so Go's FIPS 140-3 module (CMVP #5247 for v1.0.0) could in principle be switched on with `GODEBUG=fips140=on` [G1], but Authelia neither documents nor tests this | None found. Its crypto is the RustCrypto ecosystem through its `crypto-glue` crate ("A facade over the RustCrypto ecosystem"), and TLS is rustls with `aws_lc_rs` [N1, N2]. RustCrypto has no CMVP validation, and the `aws_lc_rs` feature used is not its FIPS build | Yes. Red Hat Directory Server "fully supports ... FIPS 140-2": with RHEL in FIPS mode, `modutil -dbdir /etc/dirsrv/slapd-<instance>/ -fips true` and a restart [D1]. Crypto is NSS. `389-ds-base` 3.2.0 is in EL10 AppStream (checked on the clone with `dnf list`) |
| Gives Heimdall and Vulcan single sign-on | Yes: OIDC, both apps, proven | Yes: an OIDC provider, OpenID Certified, though Authelia still calls it beta on its roadmap [A3] | Yes: an OIDC provider | No: both apps support LDAP (Heimdall `LDAP_*`, Vulcan `VULCAN_LDAP_*`), so one password works for both, but each app shows its own login form. Same credentials, no SSO session |
| User store and admin | Own database (PostgreSQL); admin console and account console (the user changes their own password) | YAML file or an LDAP backend; no admin UI | Own (embedded); CLI and web | It is the store; CLI tools `dsconf`/`dsctl` (Python, from the distribution) |
| Footprint | Measured: about 0.65 GiB RAM with its PostgreSQL, 0.56 GiB disk | Not measured; one Go binary | Not measured; one Rust binary with embedded storage | Not measured; a native daemon |
| Operability on SAFBox | One more Quadlet pod in the existing pattern; a derived image built from pinned inputs; realm-as-file import | Small; config file plus a user file; no FIPS story | Small; no FIPS story | Host RPM or container; no web SSO |

**Conclusion of the comparison:**

- Keycloak is the only candidate that gives both apps real single sign-on
  and has a documented FIPS mode that runs here.
- 389 DS has a FIPS story but gives no SSO.
- Authelia and Kanidm are lighter, but neither documents FIPS. Choosing
  either would mean making the FIPS claim for them.

**For the later Kubernetes trigger** (the planned upgrade path is k3s):

- RKE2 documents FIPS 140-2 compliance: its components are built with Go
  BoringCrypto (CMVP #4407), and its ingress nginx uses a FIPS-validated
  OpenSSL [R1]. Rancher's overview says "RKE2 complies with the FIPS 140-2
  standard using FIPS-validated crypto modules for its components" [R2].
- The same overview says nothing about FIPS for K3s [R2].
- On a FIPS appliance, RKE2 is therefore the Kubernetes to name if the
  trigger is ever met. A third service (Keycloak) does not meet it: it fits
  the Quadlet pattern unchanged.

## Upstream defects and gaps (tracked, not worked around)

- **BCFIPS version gap** (Finding 1): Keycloak 26.8.1 requires bc-fips
  2.1.3, while CMVP #4943 lists 2.1.1. To raise with Keycloak or Bouncy
  Castle, or to accept (Decision 6).
- **Keycloak support statement** (Finding 1): it names RHEL 8 and 9 hosts
  only. EL10 worked, but it is unsupported upstream.
- **Vulcan:** `VULCAN_OIDC_HOST` is still in upstream's
  `vulcan.default.yml`, but Vulcan 2.4.1 logs it as deprecated ("Use
  VULCAN_OIDC_ISSUER_URL instead"). Do not set it. Docs only, no defect.
- **Heimdall's local passwords are bcrypt**, outside the FIPS boundary
  (`docs/upstream/heimdall2-4145.md`). Relevant to Decision 3: with SSO,
  Heimdall users need no local password at all.

## Recommendation

**Go**, with Keycloak as the provider, as a fourth Quadlet pod in the
services role, built the way this spike ran it. Before the build-out, the
owner settles the decisions below, chiefly the memory budget (Decision 4)
and the validated-module caveat (Decision 6).

## Decision points for the owner

1. **Go/no-go and provider.** The recommendation is go, with Keycloak.
   - The alternative with a FIPS story is 389 DS, which gives a shared
     password but no single sign-on.
   - Authelia and Kanidm have no documented FIPS mode.
2. **safuser's Keycloak password: share the OS safuser's, or its own?**
   **Recommendation: its own,** generated at first boot like the OS one
   and retrieved the same way.
   - The OS password may reach the box only as a crypt hash (Proxmox
     `cipassword`), which Keycloak cannot use. Sharing would need the
     plaintext at first boot through another channel.
   - The two drift apart the first time either is changed: in Keycloak's
     account console, or with `passwd`.
   - A stolen app password should not be a shell password with sudo.
   - Their policies differ: Keycloak strict mode needs 14 or more
     characters, the OS STIG policy 15 or more with complexity.
   - If the owner prefers one secret: the hook can seed Keycloak from a
     deployer-supplied plaintext when one is given. It is then equal only
     until the first change.
3. **Heimdall's and Vulcan's local logins: keep as break-glass?**
   - In the spike they stay on, beside the SSO button. Heimdall's
     `/server` shows `localLoginDisabled: null` (on) and
     `enabledOAuth: ["oidc"]`. Vulcan's sign-in page has both the local
     form and "Sign in with SAFBox".
   - **Recommendation: keep local login for each app's administrator only,
     as break-glass for a Keycloak outage, and turn self-registration off:**
     - Heimdall: `REGISTRATION_DISABLED=true`;
     - Vulcan: `VULCAN_ENABLE_USER_REGISTRATION=false`.
     - Everyone else signs in through Keycloak.
   - Turning local login off entirely (Heimdall `LOCAL_LOGIN_DISABLED=true`,
     Vulcan `VULCAN_ENABLE_LOCAL_LOGIN=false`) removes Heimdall's bcrypt
     passwords from use, but leaves no way in while Keycloak is down.
   - A related choice: should safuser be an administrator in the apps?
     - Today Vulcan made it admin, as the first user.
     - Heimdall made it a plain user. `ADMIN_EMAIL=safuser@safbox.internal`
       with `ADMIN_USES_EXTERNAL_AUTH=true` would make it Heimdall's admin,
       but that converts the break-glass admin into an SSO account.
4. **Memory budget.** Keycloak and its database use about 0.65 GiB, with
   2 GiB of limits in the spike, and Keycloak's use scales with its limit.
   - That fits the 16 GiB reference easily and the 8 GB reference tightly.
   - It does not fit the 4 GiB figure in the services role's comments with
     these limits.
   - A 768 MiB Keycloak limit served the same login load (Finding 6).
     That makes Keycloak plus its database 1.25 GiB of limits, and the box's
     total 4.75 GiB. That is still over the 4 GiB figure, unless the
     database limit shrinks too.
   - Choose the reference the build-out sizes for, and whether Keycloak
     gets its own switch (`safbox_services_N`) so a small site can leave it
     off and keep the local logins.
5. **Where the derived image is built.**
   - (a) At image build, in the role, from the pinned base digest and the
     four sha256-pinned jars. This is how the tools role pins downloads.
     The build host needs quay.io and Maven Central.
   - (b) Once, published to a registry the appliance pulls from by digest.
   - **Recommendation: (a)**, since SAFBox runs no registry, and the
     licences permit (b) later.
6. **Validated-module version.** Choose one:
   - accept bc-fips 2.1.3, Keycloak's tested pin, a patch release on the
     certified 2.1 line whose certificate lists 2.1.1; or
   - require a CMVP-listed version and wait.
   - Pinning 2.1.1 against Keycloak 26.8.1 is untested and unsupported.
7. **Admin console exposure.** Keycloak's guide recommends not exposing
   `/admin/` and `/realms/master/` publicly [K3]. Recommendation: the proxy
   allows those paths from the box itself only.

## Proposed card breakdown for the build-out (after go)

Each card follows the project template and stays open until a full build
including it passes (clone-validated meanwhile).

1. **Build the Keycloak FIPS image in the services role.**
   - Pins in group_vars: the base digest and the four jars by version and
     sha256. The jars are fetched and checked, the derived image is built
     at image build, and the pins are recorded beside the other image pins.
   - Docs: the README's licence table (Bouncy Castle Licence, Keycloak
     Apache-2.0).
2. **Run Keycloak as a Quadlet pod.**
   - Units: `keycloak.network` with the fixed subnet,
     `keycloak.pod` (loopback port), `keycloak-db`, and `keycloak`
     (`start --optimized`, `KC_CACHE=local`, the trusted proxy address,
     memory limits).
   - Its own task group and `safbox_services_N` switch.
   - First-boot hook `50-keycloak.sh` (Finding 7) and the realm file.
3. **Proxy and names for Keycloak.**
   - A `services_proxy_apps` entry, so the names, both hosts files, the
     certificate and the start-page link follow.
   - An nginx server block per Keycloak's guide, with `/admin/` and
     `/realms/master/` limited to the box.
   - `AddHost=<keycloak host>:host-gateway` on the Heimdall and Vulcan pods
     when Keycloak is on.
4. **Heimdall and Vulcan as OIDC clients.**
   - OIDC settings when Keycloak is on: Heimdall `OIDC_*` with PKCE S256,
     Vulcan `VULCAN_OIDC_*` with discovery, no `VULCAN_OIDC_HOST`.
   - Client secrets from first boot.
   - Registration off and the break-glass choice (Decision 3).
5. **The initial safuser account in Keycloak.**
   - The password is generated at first boot or supplied by the deployer,
     with retrieval shared with safbox-m5f.45, m5f.16 and m5f.34
     (Decision 2).
   - The app roles follow Decision 3.
6. **Validation.**
   - Infrastructure controls, as plain InSpec resources: the Keycloak
     units, the port on loopback only, the env files 0600, the image pinned.
   - A `tests/services/` login test in the shape of `heimdall-upload.sh`
     (`login.sh` already uses the same `--resolve` client approach). The
     password is passed in, not fetched over SSH.
   - Thresholds and the release gate updated.
7. **Docs.** `docs/reference/services.md` and `docs/reference/accounts.md`: names, logging in, the safuser password,
   rotating client secrets, and a Keycloak outage with break-glass. Plus
   the deviations, if any.

## Reproducing the spike

The throwaway files are not in the repository. On a clone with the services
role applied, as root:

1. Install `50-keycloak.sh` in `/etc/safbox/firstboot.d/` and run it.
2. Add `keycloak.safbox.internal` to:
   - `/etc/safbox/proxy-names`;
   - `/etc/hosts` and `/etc/cloud/templates/hosts.redhat.tmpl`.
3. Remove `/etc/safbox/tls/safbox.{crt,key}`, run `40-proxy.sh`, and
   restart safbox-proxy.
4. Add the Quadlet drop-ins: `[Container]` OIDC environment for Heimdall
   and Vulcan, and the `[Pod]` `AddHost` above for both pods.
5. Build the derived image with the Containerfile and checksums from
   Finding 1.
6. Install the five Keycloak units (network with fixed subnet, pod, db
   volume, db container, keycloak container), the realm file and the nginx
   server block from Finding 5.
7. `systemctl daemon-reload` and start the pods.

## Sources

- [K1] Keycloak, "FIPS 140-2 support", https://www.keycloak.org/server/fips, and its source at tag 26.8.1, https://github.com/keycloak/keycloak/blob/26.8.1/docs/guides/server/fips.adoc
- [K2] Keycloak 26.8.1 `pom.xml` (`bouncycastle.bcfips.version` 2.1.3, `bctls-fips` 2.1.25, `pkixfips` 2.1.13, `bcutilfips` 2.1.8), https://github.com/keycloak/keycloak/blob/26.8.1/pom.xml
- [K3] Keycloak, "Configuring a reverse proxy", https://github.com/keycloak/keycloak/blob/26.8.1/docs/guides/server/reverseproxy.adoc
- [K4] Keycloak, "Importing and exporting realms", "Using Environment Variables within the Realm Configuration Files", https://github.com/keycloak/keycloak/blob/26.8.1/docs/guides/server/importExport.adoc
- [K5] Keycloak 26.8.1 `kc.sh` (heap defaults when `KC_RUN_IN_CONTAINER=true`), https://github.com/keycloak/keycloak/blob/26.8.1/quarkus/dist/src/main/content/bin/kc.sh
- [B1] bc-fips 2.1.3 POM, licence "Bouncy Castle Licence", https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/2.1.3/bc-fips-2.1.3.pom
- [B2] Bouncy Castle licence (MIT), https://www.bouncycastle.org/about/license/
- [B3] NIST CMVP certificate #4943, BC-FJA, https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4943
- [H1] Heimdall 2.14.0 `apps/backend/.env-example`, "Custom OIDC Service", https://github.com/mitre/heimdall2/blob/v2.14.0/apps/backend/.env-example
- [H2] Heimdall 2.14.0 `apps/backend/src/authn/oidc.strategy.ts`, https://github.com/mitre/heimdall2/blob/v2.14.0/apps/backend/src/authn/oidc.strategy.ts
- [V1] Vulcan 2.4.1 `.env.production.example` and `lib/oidc_provider_registry.rb`, https://github.com/mitre/vulcan/tree/v2.4.1
- [A1] Authelia, "Passwords" reference guide, https://www.authelia.com/reference/guides/passwords/
- [A2] Authelia issue search for "FIPS" (no FIPS mode issue or feature), https://github.com/authelia/authelia/issues?q=FIPS
- [A3] Authelia 4.39.28 README, "OpenID Connect 1.0 / OAuth 2.0", https://github.com/authelia/authelia/blob/v4.39.28/README.md
- [G1] Go, "FIPS 140-3 Compliance", https://go.dev/doc/security/fips140
- [N1] Kanidm `Cargo.toml` (rustls with `aws_lc_rs`; `crypto-glue`), https://github.com/kanidm/kanidm/blob/master/Cargo.toml
- [N2] kanidm/crypto-glue `Cargo.toml` ("A facade over the RustCrypto ecosystem"), https://github.com/kanidm/crypto-glue/blob/main/Cargo.toml
- [D1] Red Hat Directory Server 12, "Running Directory Server in FIPS mode", https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html/securing_red_hat_directory_server/assembly_running-directory-server-in-fips-mode_securing-rhds
- [R1] RKE2, "FIPS 140-2 Enablement", https://docs.rke2.io/security/fips_support
- [R2] Rancher, "Kubernetes Distributions", https://ranchermanager.docs.rancher.com/integrations-in-rancher/kubernetes-distributions
