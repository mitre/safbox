# Accounts

A deployed SAFBox has two accounts besides root. Neither is in the
template: cloud-init makes `admin` and first boot makes `safuser` on each
clone, and the seal asserts that no `safuser` account or password hash is
left in the template.

| Account | Made by | For | Logs in with | Password | sudo |
| --- | --- | --- | --- | --- | --- |
| `admin` | cloud-init, as its default user (`/etc/cloud/cloud.cfg.d/80-safbox-users.cfg`); first boot settles it (`/etc/safbox/firstboot.d/12-admin.sh`, task group `safbox-base-6`) | deploying and automation: Ansible, the release gate, recovering `safuser` | the deployer's SSH key only | none, ever: the field is a lock with no hash | passwordless |
| `safuser` | first boot (`/etc/safbox/firstboot.d/15-safuser.sh`, task group `safbox-base-5`) | using the tools day to day, at the console, over SSH and at the desktop login screen | the deployer's SSH key, or its password at the console and on the desktop | the deployer's, or one first boot generates; it expires and can be locked out | asks for its password (`/etc/sudoers.d/50-safuser`) |

SSH never accepts passwords (`PasswordAuthentication no` in
`/etc/ssh/sshd_config.d/40-safbox.conf`, written at install); a password is
for the console and the desktop.

## Deploying a clone

Set two fields in the clone's cloud-init before its first boot: on
Proxmox, the clone's **Cloud-Init** tab; with Terraform or a cloud, the
equivalent cloud-init settings (its provider's cloud-init SSH keys and
password, or `ssh_authorized_keys` and `password` in user data).

- **SSH public key(s)** go to `admin`. Key login is the only way in for
  `admin`: it has no password and passwordless sudo. First boot gives
  `safuser` the same keys.
- **Password** goes to `safuser`, and only to it: first boot applies it,
  and SAFBox keeps it from reaching `admin`. Give an `openssl passwd -6`
  hash (see [safuser](#safuser)).

With no password, first boot generates one and keeps it in
`/etc/safbox/safuser.env`, readable by root only. Read it as `admin`:

```
sudo cat /etc/safbox/safuser.env      # SAFUSER_PASSWORD=...
```

**After first boot.** Changing a cloud-init field later gives the clone a
new cloud-init instance ID. At the next boot cloud-init applies the keys
to `admin` again and regenerates the host keys, so SSH clients see a new
host key. SAFBox's first boot does not run again: a changed password does
not reach `safuser`, and changed keys do not reach `safuser`. Set or
change `safuser`'s password as `admin` with `sudo passwd safuser`.

**Key types.** The box runs in FIPS mode, and its sshd accepts only ECDSA
(nistp256, nistp384, nistp521) and RSA keys of at least 2048 bits
(`PubkeyAcceptedAlgorithms` and `RequiredRSASize` in `sshd -T`). It
refuses Ed25519 keys ("Ed25519 keys are not allowed in FIPS mode"), so a
deployer with only an Ed25519 key cannot log in. Make an accepted key:

```
ssh-keygen -t ecdsa -b 384        # or: ssh-keygen -t rsa -b 4096
```

**Clones made by `scripts/clone-and-ssh.sh`.** The script gives `admin`
its build key (`.build/clone_key`, or `SAFBOX_SSH_KEY`), then every `*.pub`
file in `.build/keys/`, then every file named in `SAFBOX_EXTRA_SSH_KEYS`
(colon-separated). Put your own public key in `.build/keys/` to log in to
the clones it makes; `.build/` is ignored by git. It refuses a key the box
would not accept, before it makes the clone. `.build/` is the one in the
checkout the script runs from: run from a git worktree, it uses that
worktree's `.build/`, and makes a new build key there, so point
`SAFBOX_SSH_KEY` and `SAFBOX_EXTRA_SSH_KEYS` at the main checkout's files.

## admin

`admin` is the account the deployer's automation uses, and the one that
repairs `safuser`. A deployment that leaves cloud-init's user name unset
(on Proxmox, the clone's **User** field left blank) gets `admin`, not the
distribution's `rocky` or `cloud-user`; a deployment that names its user
otherwise gets that name with the same settings, and the safbox profile is
then told the name (below).

- **No password.** cloud-init creates it locked and does not run its
  `set_passwords` module, so the password a deployment supplies never
  reaches it (that password is `safuser`'s). If a deployment's own users
  list gives it one anyway, first boot removes it.
- **Never expires.** First boot exempts it from password ageing and
  inactivity (`chage -M -1 -I -1`). Without that, the STIG's 60-day
  maximum would expire its unusable password, and sshd then refuses even
  its key login, demanding a change it cannot make. This is the deviation
  the STIG overlay records for SV-281170.
- **Cannot be locked out.** Failed passwords lock accounts through
  pam_faillock, but SSH key login and passwordless sudo run no password
  check, so a lock on `admin` stops neither.
- **Not on the login screen.** On a desktop build it is a system account
  to AccountsService (`SystemAccount=true` in
  `/var/lib/AccountsService/users/admin`), so GDM lists only `safuser`.
- **Passwordless sudo is a deviation.** The STIG requires a password for
  privilege escalation (SV-281211). `admin` keeps passwordless sudo
  because Ansible, the release gate and the idempotence check escalate
  through it unattended; the STIG overlay records this as a Not Applicable
  override scoped to `admin`, and the safbox profile's `safbox-accounts-4`
  fails if any other account has a `NOPASSWD` rule.

## safuser

**Its password.** The password a deployment gives cloud-init, as the
top-level `password` of the user data, is `safuser`'s and only
`safuser`'s. Give it as a SHA-512 crypt hash, so the plain password never
leaves your workstation and the hash is the kind the STIG requires:

```
openssl passwd -6        # prompts for the password, prints $6$...
```

On Proxmox this is the clone's cloud-init **Password** (`cipassword`); see
[Accounts on a clone](../guides/proxmox/build.md#accounts-on-a-clone). It
is not expired when it is set, so the first login does not force a change.
Without an SSH key in the user data, `safuser` gets none and logs in at the
console only; first boot logs a warning.

**A generated password.** With no password given (cloud-init's `RANDOM`
counts as none), first boot generates one that meets the box's password
quality policy (the STIG's 15 characters and four character classes), sets
it with a SHA-512 hash, and keeps it, like the services' first-boot
secrets, in a root-only file. Read it as `admin`:

```
sudo cat /etc/safbox/safuser.env      # SAFUSER_PASSWORD=...
```

`/etc/safbox/safuser.env` keeps the generated password and is not updated
by a change: delete it once the password is changed or noted.

**It expires.** `safuser`'s password follows the STIG: it must be changed
within 60 days of being set (`/etc/login.defs`), and 35 days after it
expires the account is disabled. When it has expired, the next console or
desktop login asks for a new one.

**It can be locked out.** Three wrong passwords within 15 minutes lock
`safuser` (pam_faillock), and the lock holds until an administrator
releases it; it does not time out.

**What admin does.** Over SSH as `admin`:

```
sudo passwd safuser                     # set a new password (the quality policy applies)
sudo faillock --user safuser            # show failed attempts and whether it is locked
sudo faillock --user safuser --reset    # release the lock
sudo chage -l safuser                   # when the password expires
```

`safuser` changes its own password with `passwd`.

**A deployment's own users list.** Off Proxmox (Terraform, a cloud), the
usual practice is a full user data `users:` list. List `default` in it, so
cloud-init still makes `admin`, and define `safuser` there if you want to
set its password and keys yourself:

```yaml
#cloud-config
users:
  - default
  - name: safuser
    lock_passwd: false
    passwd: $6$...                # openssl passwd -6
    ssh_authorized_keys: [ecdsa-sha2-nistp384 AAAA...]
ssh_authorized_keys: [ecdsa-sha2-nistp384 AAAA...]   # admin's
```

First boot then keeps the password and keys `safuser` already has. A
password counts only when it is usable: cloud-init locks a users-list
password unless the entry sets `lock_passwd: false`, and a locked one
counts as none, so `safuser` gets the top-level `password` or a generated
one as above. Without `set_passwords`, cloud-init ignores `chpasswd` and
`ssh_pwauth`; set passwords in the `users:` entries.

## Site inputs

A cloud-init user named something other than `admin` (including
`SAFBOX_CLONE_USER` for `scripts/clone-and-ssh.sh`) is given to the safbox
profile as its `admin_user` input in the site inputs file. A site that
switches `safbox_base_5` off sets the profile's `safuser` input to `false`,
and `safbox-accounts-3` is then Not Applicable. The STIG overlay lists the
accounts SAFBox creates, `admin` and `safuser`, as its `user_accounts`
input (SV-281199, no unauthorized accounts); a site with other accounts,
or another cloud-init user name, sets that input to its own list in the
same file. `safbox_base_6` should stay
on: without it `admin`'s key login ends when its password ages out.

## Accounts in the applications

`safuser` also has a Keycloak account, which signs it in to Heimdall and
Vulcan (single sign-on). Its Keycloak password is its own, not the OS
password above: first boot generates it, and an administrator reads it
with `sudo grep '^SAFUSER_PASSWORD=' /etc/safbox/keycloak.env`. `safuser`
changes it in Keycloak's account page,
`https://keycloak.safbox.internal/realms/safbox/account/`; the file keeps
the first password only. Each application starts with one local account,
its administrator, kept for when Keycloak is down. Heimdall refuses
registration. Vulcan 2.4.1 does not: with registration set off it only
hides the sign-up link, so anyone who can reach Vulcan can still register
a regular local account. That is an upstream defect, accepted and left as
it is. See [Services on the box](services.md), "Accounts" and "Single
sign-on".
