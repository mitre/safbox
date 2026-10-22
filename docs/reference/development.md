# Developing SAFBox

## Continuous integration

`.github/workflows/static.yml` runs on every push and pull request on
GitHub-hosted runners. It needs no hypervisor and no credentials.

One job, **static checks**, runs in order:

- gitleaks over the full history with `.gitleaks.toml`, which adds rules
  for Proxmox API token secrets to the defaults;
- `pre-commit run --all-files` (among its hooks the kickstart lint,
  `packer fmt` and shellcheck);
- `tests/ansible/lint.sh` (yamllint, ansible-lint, the playbook syntax
  check, shellcheck, `tests/packer/validate.sh`, `cinc-auditor check` on
  the three profiles and the [script tests](#script-tests), among them
  `tests/secrets/gitleaks-rules.bats`, which proves those rules catch a
  generated fake token and pass the repository's placeholders);
- `tests/platform-discipline.sh`;
- the documentation site's build.

Every input is pinned: actions by commit SHA, gitleaks and CINC Auditor by
version and sha256, the SAF CLI by version (the appliance's own pin), the Packer CLI by version (its plugins by
`packer/build.pkr.hcl`), the Python tools in `tests/requirements.txt`, bats
and its helper libraries by version and sha256 in `tests/bats/install.sh`, and
the pre-commit hooks by commit SHA. To run the same suite locally, install
`tests/requirements.txt` into a virtual environment, or run the workflow
under [act](https://github.com/nektos/act).

## Script tests

The runner scripts' tests are [bats](https://bats-core.readthedocs.io/)
suites, one test per scenario with all its checks, each in a temporary
directory of its own:

| Suite | What it tests |
|---|---|
| `tests/scripts/build-env.bats` | `scripts/build.sh` takes credentials only from an owner-only file (`scripts/lib.sh`, which `scripts/clone-and-ssh.sh` shares) |
| `tests/scripts/build-concurrency.bats` | two `build.sh` runs at once keep their own keys, logs and galaxy installs |
| `tests/scripts/build-cleanup.bats` | however a run ends (token leak, failed Packer, a signal), the key is deleted |
| `tests/scripts/clone-and-ssh.bats` | `scripts/clone-and-ssh.sh`: an owner-only credentials file, build keys offered, when the release gate runs, a kept clone's read-only client gate, extra SSH keys accepted or refused |
| `tests/scripts/validate.bats` | `scripts/validate.sh`: the client profile's inputs and threshold, full or read-only (`--client-read-only`), and the results directory |
| `tests/secrets/gitleaks-rules.bats` | the `.gitleaks.toml` rules catch Proxmox token secrets and pass the placeholders |

The `tests/scripts/` suites run the scripts in a scratch copy of the
repository layout with the stub programs in `tests/scripts/stubs/` (each
file says what it stands in for) and the fake credentials in
`tests/scripts/fixtures/packer.env`, so nothing touches the checkout's
`.build/`, `last.log` or a hypervisor. `BUILD_SH`, `CLONE_SH` and `VALIDATE_SH`
point them at another copy of a script, a scratch copy with a guard broken, say.

Run them with `tests/bats/run.sh`, which `tests/ansible/lint.sh` and a
pre-commit hook (on changes to the scripts, suites, stubs or fixtures)
also call:

```
tests/bats/run.sh                                  # every suite, TAP output
tests/bats/run.sh tests/scripts/build-env.bats     # one suite
```

`tests/bats/run.sh` first runs `tests/bats/install.sh`, which downloads
bats-core, bats-support, bats-assert and bats-file at the releases pinned
there, checks each tarball's sha256 and unpacks it into `.build/bats/`
(`SAFBOX_BATS_DIR` moves it). It downloads again only when a pin changes;
a checksum mismatch stops it. The tests' temporary directories go under
`$TMPDIR`. The gitleaks rules suite needs `gitleaks` on `PATH`. The
safbox-client profile's full and read-only modes are proven by the
combined build itself, whose clones run its release gate both ways.

## Workstation tools for contributors

Besides the build tools in the [Proxmox build guide](../guides/proxmox/build.md#prerequisites):

- `pipx install pykickstart` for the kickstart lint. The versions the
  static suite is verified with are pinned in `tests/requirements.txt`
- [gitleaks](https://github.com/gitleaks/gitleaks) on `PATH` for the
  gitleaks rules suite (the version in `.github/workflows/static.yml`)
- `pre-commit install` after cloning (gitleaks, shellcheck, packer fmt,
  kickstart lint, the script tests). If you also use beads, `bd init` sets `core.hooksPath`
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
