# Developing SAFBox

## Continuous integration

`.github/workflows/static.yml` runs on every push and pull request on
GitHub-hosted runners. It needs no hypervisor and no credentials.

- **secret scan:** gitleaks over the full history with `.gitleaks.toml`,
  which adds rules for Proxmox API token secrets to the defaults, then
  `tests/secrets/gitleaks-rules.sh`, which proves those rules catch a
  generated fake token and pass the repository's placeholders.
- **static checks:** `pre-commit run --all-files`, the `build.sh` tests in
  `tests/scripts/`, `tests/kickstart/ks-lint.sh`, `tests/ansible/lint.sh`
  (yamllint, ansible-lint, the playbook syntax check, shellcheck,
  `tests/packer/validate.sh` and `cinc-auditor check` on both profiles) and
  `tests/platform-discipline.sh`.

Every input is pinned: actions by commit SHA, gitleaks and CINC Auditor by
version and sha256, the SAF CLI by version (the appliance's own pin), the Packer CLI by version (its plugins by
`packer/build.pkr.hcl`), the Python tools in `tests/requirements.txt`, and
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
