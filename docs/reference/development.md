# Developing SAFBox

## Checks

SAFBox is checked with standard linters and with the real build and its
gates:

- `tests/ansible/lint.sh`: yamllint, ansible-lint, the playbook syntax
  check, shellcheck, `tests/packer/validate.sh` and `cinc-auditor check`
  on the three profiles. No target host needed.
- `tests/packer/validate.sh`: `packer fmt`, `packer init` and a full
  `packer validate` with the example variables, then one bad and one good
  value for each variable rule.
- `tests/kickstart/ks-lint.sh`: renders the kickstart template and checks
  it against the RHEL 10 kickstart grammar with pykickstart.
- `tests/ansible/idempotence.sh`: runs `playbooks/safbox.yml` twice
  against a booted build VM or clone; the second run must change nothing
  (see [The idempotence check](#the-idempotence-check)). The first run on
  a fresh clone still changes these, by design or upstream:
  - the downloads in `/var/tmp` (the CA bundles, CINC Auditor, Packer and
    the Keycloak build context with its jars): the seal empties
    `/var/tmp`, so they are fetched again;
  - RHEL-10-200532 Setup Connections and its firewalld reload: Lockdown
    binds the clone's own interface (cloud-init names it `eth0`) into the
    drop zone, which is the default zone already;
  - RHEL-10-400240 group ACL and RHEL-10-600170 `.bashrc` PATH on
    `/home/admin` and `/home/safuser`: first boot creates both accounts
    from `/etc/skel` after the template was hardened;
  - desktop only, RHEL-10-600020 on `gnome-initial-setup` and `pipewire`:
    Lockdown's user task recreates their missing homes under `/run`
    (a Lockdown defect).
- The pre-commit hooks: gitleaks, whitespace and YAML checks, shellcheck,
  `packer fmt` and the kickstart lint.
- The build and its gates: `scripts/build.sh` scans the VM before sealing
  it, and clones run the release gate (see
  [How SAFBox is validated](validation.md)). However a run ends, the build
  deletes its key and fails if the API token reached Packer's debug log.

## The idempotence check

`tests/ansible/idempotence.sh [ansible-playbook args...]` runs
`playbooks/safbox.yml` twice against one box and fails if the second run
changes anything. It proves the playbook settles: once it has run on a box
made from the template, running it again changes nothing. It needs:

- A box of its own: a fresh clone of the template, not the release clone,
  since the first run may change it. Make one without the release gate,
  and delete it afterwards:

  ```
  SAFBOX_SKIP_VALIDATE=1 scripts/clone-and-ssh.sh <template-vmid> <clone-vmid> --keep
  ```

  That stops before the wait for first boot, so wait for it before the
  first run:

  ```
  ssh -i .build/clone_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    admin@<clone-ip> systemctl is-system-running --wait
  ```
- `SAFBOX_HOST` (the clone's address, printed as `clone IP:`),
  `SAFBOX_USER` (`admin`, who has passwordless sudo) and `SAFBOX_KEY`
  (`.build/clone_key`). Without all three the script skips with exit
  code 2.
- The pinned roles and collections. The build's own install, in
  `.build/run/galaxy/`, is replaced by the next build, so install a copy
  from the repository root; `--force` replaces one from an older pin:

  ```
  ansible-galaxy role install --force -r ansible/requirements.yml -p .build/cache/idem-galaxy/roles
  ansible-galaxy collection install --force -r ansible/requirements.yml -p .build/cache/idem-galaxy/collections
  export ANSIBLE_ROLES_PATH=$PWD/.build/cache/idem-galaxy/roles:$PWD/ansible/roles
  export ANSIBLE_COLLECTIONS_PATH=$PWD/.build/cache/idem-galaxy/collections
  ```

- Arguments, which go to both runs. The script runs the playbook from
  `ansible/`, so give file paths in full:
  - `-e template_services_site_src=$PWD/.build/run/site/`, the
    documentation site `scripts/build.sh` built from the same tree (the
    next build replaces it, so if one will run, copy it first to a
    git-ignored place such as `.build/cache/idem-site-<variant>/`, give
    that path, and remove the copy afterwards).
    Without it the play looks for `site/.vitepress/dist/` and stops.
  - On a desktop clone, also `-e @$PWD/ansible/local.yml`, the file that
    sets `safbox_desktop_enabled: true`.
- If the runner's SSH client config can't be read or used, add
  `-F /dev/null` to the first-boot `ssh` command above, and set
  `ANSIBLE_SSH_ARGS='-F /dev/null -o ControlMaster=auto -o ControlPersist=60s'`,
  which replaces `ssh_args` in `ansible/ansible.cfg`.

## Release checklist

A change that touches the box is done, and an image is ready to publish,
only when both variants pass these steps, built from one tree with the
shipped defaults:

1. Run `tests/ansible/lint.sh` and `pre-commit run --all-files`.
2. Build the headless template with `scripts/build.sh`, with no
   `safbox_desktop_enabled` in `ansible/local.yml` (the build loads that
   file whenever it exists), then the desktop template as the [desktop guide](../guides/proxmox/desktop.md) says
   (`safbox_desktop_enabled: true` in `ansible/local.yml`, the desktop
   inputs file named to the build gate in `packer/local.auto.pkrvars.hcl`
   or with `-var build_gate_site_inputs_file=verify/local/inputs.yml`). Build one after the other: each
   build replaces `.build/run/`, so copy the headless build's
   `.build/run/site/` aside for its idempotence check (step 6) before the
   desktop build starts. Each build's gate, the safbox profile and
   the STIG overlay against their `build` thresholds, must pass. Once
   the desktop lane is done, remove its `ansible/local.yml` and
   `verify/local/` files: left in place, they make the next headless
   build a desktop one.
3. Run the release gate on a clone of each template:
   `scripts/clone-and-ssh.sh <template-vmid> <clone-vmid> --keep`, with
   `SAFBOX_SITE_INPUTS` naming the desktop inputs file for the desktop
   clone. It runs `scripts/validate.sh --client`: both box profiles and
   the client profile, against their `release` thresholds. All must pass.
   If the gate fails with `Permission denied @ rb_sysopen -
   /etc/ssh/ssh_config`, the runner's SSH config can't be read: set
   `SAFBOX_SSH_CONFIG=/dev/null`.
4. Check that the STIG failures match [Known failures](hardening.md#known-failures).
   For each overlay results file, from both build gates and both release
   gates, list the failed controls:

   ```
   jq -r '.profiles[].controls[] | select(any(.results[]; .status == "failed")) | .id' \
     .build/validate-<label>-safbox-rhel10-stig-overlay-<time>.json | sort -u
   ```

   Every ID listed must be in the table, and every row the table says
   fails in that gate must be listed. A difference means updating the
   table and the comments in the STIG thresholds; a new choice not to
   meet a requirement is the owner's decision.
5. On each release clone, `systemctl --failed` lists no units.
6. Run [the idempotence check](#the-idempotence-check) on a separate fresh
   clone of each template. The second run must report `changed=0`.
7. Afterwards, keep the two new templates and the two release clones, on
   which sign-in is checked by hand, until the next release replaces
   them. Delete the idempotence clones with `scripts/delete-vm.sh`, and,
   once the new ones pass, the previous release's templates and clones
   that nobody is still using. A
   failed build keeps its VM for diagnosis; delete it once the cause is
   known. Scan results stay in `.build/` and are never committed.

## Continuous integration

`.github/workflows/static.yml` runs on every push and pull request on
GitHub-hosted runners. It needs no hypervisor and no credentials.

One job, **static checks**, runs in order:

- gitleaks over the full history with `.gitleaks.toml`, which adds rules
  for Proxmox API token secrets to the defaults;
- `pre-commit run --all-files`;
- `tests/ansible/lint.sh`;
- the documentation site's build.

Every input is pinned: actions by commit SHA, gitleaks and CINC Auditor by
version and sha256, the SAF CLI from the appliance's own lockfile, the
Packer CLI by version (its plugins by `packer/build.pkr.hcl`), the Python
tools in `tests/requirements.txt`, and
the pre-commit hooks by commit SHA. To run the same suite locally, install
`tests/requirements.txt` into a virtual environment, or run the workflow
under [act](https://github.com/nektos/act).

## Workstation tools for contributors

Besides the build tools in the [Proxmox build guide](../guides/proxmox/build.md#prerequisites):

- `pipx install pykickstart` for the kickstart lint. The versions the
  static suite is verified with are pinned in `tests/requirements.txt`
- `pre-commit install` after cloning (gitleaks, shellcheck, packer fmt,
  kickstart lint). If you also use beads, `bd init` sets `core.hooksPath`
  to `.beads/hooks` and `pre-commit install` refuses to run. Unset the
  option, install, set it back, and append a chain to the beads shim:

  ```
  git config --unset core.hooksPath && pre-commit install && git config core.hooksPath "$PWD/.beads/hooks"
  cat >> .beads/hooks/pre-commit <<'EOF'
  if [ -x "$(git rev-parse --show-toplevel)/.git/hooks/pre-commit" ]; then
    "$(git rev-parse --show-toplevel)/.git/hooks/pre-commit" "$@" || exit $?
  fi
  EOF
  ```

  Prove it with a staged file containing a fake AWS key: the commit must be
  refused.
