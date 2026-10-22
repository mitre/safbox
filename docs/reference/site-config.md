# Site CA bundles

Task group `safbox-site-config-1` of the `template_os` role adds CA
certificates to the system trust store, so the box, its tools, and the
Heimdall and Vulcan containers trust servers those CAs sign. It runs right
after the OS contract (the base packages, firewall, container runtime,
journal and desktop), so everything after it (the package update, the tools downloads, the
container image pulls) already uses the new store; the base package
installs before it, and the group's own install of
OpenSSL and unzip, use the store the box had before. No certificate is
kept in the repository: each bundle is downloaded by the box or copied
from your workstation when the role runs.

**DoD PKI, on by default.** The DoD root and issuing CAs (DoD Root CA 3 to
6 and their subordinates) come from DISA's public PKI library at a pinned
URL, checked against a pinned sha256 (`safbox_trust_bundle_dod`), and the
default list trusts them:

```
safbox_trust_bundles:
  - "{{ safbox_trust_bundle_dod }}"
```

To build or run without them, set the list to `[]` (or to your own
bundles only) in `ansible/local.yml`. The role then removes any DoD anchor
a previous run installed.

**Network at build.** Because the DoD bundle is on by default, every build
and every run of this group downloads it from `dl.dod.cyber.mil`, so the
build VM (or the box) needs outbound HTTPS to that host. On a network
without it, give the same file as a local path instead: download the zip
once on a connected machine, check it with `sha256sum` against the pin,
carry it to the machine that runs Ansible, and put in `ansible/local.yml`:

```
safbox_trust_bundles:
  - name: dod
    path: /absolute/path/to/unclass-certificates_pkcs7_DoD.zip
    sha256: "{{ safbox_trust_bundle_dod.sha256 }}"
    format: "{{ safbox_trust_bundle_dod.format }}"
    member: "{{ safbox_trust_bundle_dod.member }}"
```

The role copies it to the box and checks the same sha256, so the result is
identical to the download.

**When DISA releases a new bundle.** DISA replaces the file behind the
pinned URL with each release. The download then no longer matches the pin
and, with the DoD bundle on by default, every build and every run of this
group fails rather than trust content nobody reviewed, until the pin is
updated as the comment above `safbox_trust_bundle_dod` describes (DISA's
signed manifest inside the zip, then the version, sha256 and member, and
the root fingerprints of the profile's `trust_bundle_anchors` input). A
site that cannot wait can build from a local copy of the pinned release as
above, or remove the DoD bundle.

**Your own bundle.** Add an entry beside the DoD one (or instead of it):

```
safbox_trust_bundles:
  - "{{ safbox_trust_bundle_dod }}"
  - name: example-org           # lowercase letters, digits, hyphens
    path: /home/me/pki/example-org-ca.pem   # absolute, on the machine running Ansible
    sha256: <sha256sum of that file>
    format: pem                 # pem, der, pkcs7-der or pkcs7-pem
```

or `url: https://...` instead of `path` for a file the box downloads, and
`member: <path inside the zip>` (relative, without `..`) when the file is
a zip archive, as DISA's is. Every entry needs its sha256: a download or
file that does not match fails the run, and nothing from any bundle is
trusted. A malformed entry (an unknown format or key, both or neither of
`url` and `path`, a relative `path`, two bundles with one name) is refused
before anything is fetched.

**What the role does.** It reads each bundle with OpenSSL, writes one
anchor file per certificate (`safbox-<bundle>-<id>.pem` in
`/etc/pki/ca-trust/source/anchors`), runs `update-ca-trust`, and removes
the anchors of any certificate no longer configured, so dropping a bundle
from the list untrusts it. Before installing anything it verifies every
certificate under the system crypto policy (`openssl verify` at the
policy's security level, each signature checked, a root's own included,
expiry not judged): a root the FIPS policy would refuse in use, such as a
SHA-1 signature, an RSA key shorter than 2048 bits or an elliptic curve
FIPS mode does not offer, fails the run and is named, rather than trusted
on paper and rejected silently later. Every certificate of the DoD bundle
passes on a FIPS-mode SAFBox.

**Containers.** Heimdall and Vulcan mount the host's extracted trust store
(`/etc/pki/ca-trust/extracted`) read-only where their Red Hat UBI images
read their own, so their Node.js and Ruby trust exactly what the host
trusts. When the store changes on a running box, the role restarts
`heimdall.service` and `vulcan.service`, which read it at start.

SELinux labels the host's certificate files `cert_t`, which a container
(`container_t`) may not read; the `template_os` role turns on the
container-selinux boolean `container_read_certs` to allow it. The boolean
is host-wide: it lets every container read every `cert_t` file mounted
into it, and `cert_t` covers private keys too (`/etc/pki/tls/private`,
for example), so a future unit that mounted such a directory would expose
those keys to its container without any SELinux denial. SAFBox accepts
this because a container reaches only what its unit mounts, the units are
the appliance's own (reviewed here, checked by the validation profile),
the only `cert_t` path any of them mounts is the public extracted store,
and the proxy's private key lives in `/etc/safbox/tls`, labelled for its
container alone. The alternative, relabelling the store for containers,
would change the label the host's own programs rely on. Mount nothing
else under `/etc/pki` into a container.

**At build or on a deployed box.** The list in effect at build (the
default, or `ansible/local.yml` named to the build, see [Site overrides](../guides/proxmox/build.md#site-overrides))
is baked into the image. On a box that is already deployed, apply only
this group from the repository root on your workstation, with the same
`ansible/local.yml` if you use one (drop `-e @ansible/local.yml` for the
repository defaults; `ANSIBLE_CONFIG` names the project's configuration,
which finds the roles):

```
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i <box>, -u <user> --private-key <key> \
  ansible/playbooks/safbox.yml -e @ansible/local.yml --tags safbox-site-config-1
```

A second run changes nothing.

**Validation.** `safbox-trust-1` checks that the CA roots named in the
input `trusted_roots` (by default the four DoD roots, by label, as `trust
list` shows them) are in the system trust store. A site that changes the
list names its roots in its site inputs file, for the build gate and the
release gate alike: `trusted_roots: []` without the DoD bundle, or the
labels of its own roots.
