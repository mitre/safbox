# frozen_string_literal: true

require 'shellwords'

# Behaviour of the installed first-boot runner and secrets library, each
# control in its own scratch tree. A behaviour here is a sequence with state
# between steps (run, change a file, run again), which InSpec resources
# cannot hold between them, so each control runs one scripted command: it
# creates the tree under /root (a hardened /tmp may be noexec, and hooks
# must execute), points the runner's directories into it, prints each fact
# it observes as "<name>=<value>", and removes the tree on exit. Every
# behaviour is then its own describe on those facts, and a last describe
# asserts the tree is gone. The runner is called directly with a clean
# environment, never through systemd, so nothing reaches /etc/safbox,
# /var/lib/safbox or the journal. One bash -c, because sudo (the profile's
# --sudo) applies to the first word of a command line only.

runner = input('firstboot_runner')
lib_dir = input('firstboot_lib_dir')

prelude = <<~'SH'
  set -uo pipefail
  sandbox=$(mktemp -d /root/safbox-firstboot-test.XXXXXX) || exit 1
  trap 'rm -rf "$sandbox"' EXIT
  printf 'scratch=%s\n' "$sandbox"
  fact() { printf '%s=%s\n' "$1" "$2"; }
  # run DIR: the runner with every path inside DIR.
  run() {
    env -i PATH=/usr/sbin:/usr/bin SAFBOX_ETC_DIR="$1/etc" SAFBOX_STATE_DIR="$1/state" \
      SAFBOX_LIB_DIR="$lib_dir" "$runner"
  }
  # hook DIR NAME BODY [MODE]
  hook() {
    mkdir -p "$1/etc/firstboot.d"
    printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$3" >"$1/etc/firstboot.d/$2"
    chmod "${4:-0755}" "$1/etc/firstboot.d/$2"
  }
  present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
SH

# Runs a scenario after the prelude; returns its facts, name => value.
scenario = lambda do |body|
  vars = "runner=#{Shellwords.escape(runner)}\nlib_dir=#{Shellwords.escape(lib_dir)}\n"
  stdout = command("bash -c #{Shellwords.escape(vars + prelude + body)}").stdout
  stdout.each_line.with_object({}) do |line, facts|
    m = line.chomp.match(/\A(\w+)=(.*)\z/)
    facts[m[1]] = m[2] if m
  end
end

scratch_removed = lambda do |facts|
  scratch = facts['scratch']
  describe "scratch tree #{scratch} removed afterwards" do
    subject { scratch.nil? ? 'never created' : file(scratch).exist? }
    it { should eq false }
  end
end

control 'safbox-firstboot-runner-1' do
  impact 1.0
  title 'The first-boot runner creates its etc directory root-owned 0700'
  desc 'The etc directory holds the per-install secrets the hooks generate, so the runner creates it, and its hook directory, readable by root alone when they do not exist.'

  facts = instance_exec(<<~'SH', &scenario)
    d=$sandbox/create
    mkdir -p "$d"
    run "$d" >/dev/null 2>&1
    fact rc "$?"
    fact etc "$(stat -c '%a %U %G' "$d/etc" 2>&1)"
    fact hooks "$(stat -c '%a %U %G' "$d/etc/firstboot.d" 2>&1)"
  SH

  describe 'exit status of the runner with no etc directory' do
    subject { facts['rc'] }
    it { should cmp 0 }
  end
  describe 'mode, owner and group of the etc directory it created' do
    subject { facts['etc'] }
    it { should eq '700 root root' }
  end
  describe 'mode, owner and group of the hook directory it created' do
    subject { facts['hooks'] }
    it { should eq '700 root root' }
  end
  instance_exec(facts, &scratch_removed)
end

control 'safbox-firstboot-runner-2' do
  impact 1.0
  title 'The first-boot runner runs executable hooks in lexical order and skips the rest'
  desc 'Hooks run in byte order of their names, so a hook can rely on an earlier one; a file that is not executable is skipped and logged, not run.'

  facts = instance_exec(<<~'SH', &scenario)
    d=$sandbox/order
    hook "$d" 20-second 'echo second >>"$SAFBOX_STATE_DIR/order"'
    hook "$d" 05-first 'echo first >>"$SAFBOX_STATE_DIR/order"'
    hook "$d" 10-skipped 'echo skipped >>"$SAFBOX_STATE_DIR/order"' 0644
    run "$d" >"$sandbox/out" 2>&1
    fact rc "$?"
    fact order "$(paste -sd, "$d/state/order" 2>&1)"
    fact skip_logged "$(grep -c '^safbox-firstboot: skipping 10-skipped: not an executable file$' "$sandbox/out")"
  SH

  describe 'exit status of the runner with three hooks' do
    subject { facts['rc'] }
    it { should cmp 0 }
  end
  describe 'hooks that ran, in order (05-first and 20-second; 10-skipped is mode 0644)' do
    subject { facts['order'] }
    it { should eq 'first,second' }
  end
  describe 'log lines reporting the non-executable hook skipped' do
    subject { facts['skip_logged'] }
    it { should cmp 1 }
  end
  instance_exec(facts, &scratch_removed)
end

control 'safbox-firstboot-runner-3' do
  impact 1.0
  title 'The first-boot runner records completion and does nothing on the next run'
  desc 'After its hooks succeed the runner writes a root-only marker holding the UTC completion time; a later run sees the marker, reports completion, runs no hook and leaves the marker as it was.'

  facts = instance_exec(<<~'SH', &scenario)
    d=$sandbox/once
    hook "$d" 10-count 'echo ran >>"$SAFBOX_STATE_DIR/count"'
    run "$d" >/dev/null 2>&1
    fact first_rc "$?"
    fact marker "$(cat "$d/state/firstboot.done" 2>&1)"
    fact marker_mode "$(stat -c '%a %U' "$d/state/firstboot.done" 2>&1)"
    before=$(stat -c '%i %y' "$d/state/firstboot.done" 2>/dev/null)
    run "$d" >"$sandbox/out" 2>&1
    fact second_rc "$?"
    fact second_output "$(tr '\n' ' ' <"$sandbox/out")"
    fact hook_runs "$(wc -l <"$d/state/count")"
    after=$(stat -c '%i %y' "$d/state/firstboot.done" 2>/dev/null)
    fact marker_untouched "$([ -n "$before" ] && [ "$after" = "$before" ] && echo yes || echo no)"
  SH

  describe 'exit status of the first run' do
    subject { facts['first_rc'] }
    it { should cmp 0 }
  end
  describe 'completion marker after the first run' do
    subject { facts['marker'] }
    it { should match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) }
  end
  describe 'mode and owner of the completion marker' do
    subject { facts['marker_mode'] }
    it { should eq '600 root' }
  end
  describe 'exit status of the second run' do
    subject { facts['second_rc'] }
    it { should cmp 0 }
  end
  describe 'output of the second run' do
    subject { facts['second_output'] }
    it { should match(/already completed at /) }
  end
  describe 'times the hook ran over both runs' do
    subject { facts['hook_runs'] }
    it { should cmp 1 }
  end
  describe 'completion marker untouched by the second run' do
    subject { facts['marker_untouched'] }
    it { should eq 'yes' }
  end
  instance_exec(facts, &scratch_removed)
end

control 'safbox-firstboot-runner-4' do
  impact 1.0
  title 'A failing hook leaves no completion marker, and the next run retries and keeps its secrets'
  desc 'A hook that fails aborts the run without a marker, so the next boot retries every hook; a secret the failed run generated is kept, not regenerated.'

  facts = instance_exec(<<~'SH', &scenario)
    d=$sandbox/retry
    hook "$d" 10-secret 'source "$SAFBOX_LIB_DIR/secrets.sh"; safbox_ensure_secret "$SAFBOX_ETC_DIR/test.env" TOKEN'
    hook "$d" 20-flaky 'test -e "$SAFBOX_STATE_DIR/ready"'
    run "$d" >/dev/null 2>&1
    fact failed_rc "$?"
    fact marker_after_failure "$(present "$d/state/firstboot.done")"
    fact secret_after_failure "$(grep -cE '^TOKEN=[0-9a-f]{64}$' "$d/etc/test.env" 2>/dev/null)"
    first=$(cat "$d/etc/test.env" 2>/dev/null)
    touch "$d/state/ready"
    run "$d" >/dev/null 2>&1
    fact retry_rc "$?"
    fact marker_after_retry "$(present "$d/state/firstboot.done")"
    fact secret_kept "$([ -n "$first" ] && [ "$(cat "$d/etc/test.env")" = "$first" ] && echo yes || echo no)"
  SH

  describe 'exit status of the run whose second hook fails' do
    subject { facts['failed_rc'] }
    it { should match(/\A[1-9][0-9]*\z/) }
  end
  describe 'completion marker after the failed run' do
    subject { facts['marker_after_failure'] }
    it { should eq 'absent' }
  end
  describe 'secrets the first hook generated before the failure' do
    subject { facts['secret_after_failure'] }
    it { should cmp 1 }
  end
  describe 'exit status of the retry once the hook can succeed' do
    subject { facts['retry_rc'] }
    it { should cmp 0 }
  end
  describe 'completion marker after the retry' do
    subject { facts['marker_after_retry'] }
    it { should eq 'present' }
  end
  describe 'secret unchanged by the retry' do
    subject { facts['secret_kept'] }
    it { should eq 'yes' }
  end
  instance_exec(facts, &scratch_removed)
end

control 'safbox-firstboot-secrets-1' do
  impact 1.0
  title 'safbox_ensure_secret writes a root-only random secret, keeps an existing one and rejects bad input'
  desc 'Hooks generate per-install credentials with safbox_ensure_secret: a new key gets 32 random bytes from openssl rand as hex in a root-only 0600 file; a key already present keeps its value, so a retried first boot never changes a credential a service uses.'

  facts = instance_exec(<<~'SH', &scenario)
    source "$lib_dir/secrets.sh" || exit 1
    f=$sandbox/test.env
    safbox_ensure_secret "$f" TOKEN
    fact create_rc "$?"
    fact file_mode "$(stat -c '%a %U %G' "$f" 2>&1)"
    fact token_lines "$(grep -cE '^TOKEN=[0-9a-f]{64}$' "$f")"
    first=$(cat "$f")
    safbox_ensure_secret "$f" TOKEN
    fact again_rc "$?"
    fact generated_kept "$([ "$(cat "$f")" = "$first" ] && echo yes || echo no)"
    printf 'EXISTING=value-set-before\n' >>"$f"
    safbox_ensure_secret "$f" EXISTING
    fact existing_rc "$?"
    fact existing "$(grep '^EXISTING=' "$f")"
    safbox_ensure_secret "$f" bad-key 2>/dev/null
    fact bad_key_rc "$?"
    safbox_ensure_secret "$f" SHORT 8 2>/dev/null
    fact short_rc "$?"
    fact short_lines "$(grep -c '^SHORT=' "$f")"
  SH

  describe 'exit status creating TOKEN' do
    subject { facts['create_rc'] }
    it { should cmp 0 }
  end
  describe 'mode, owner and group of the env file' do
    subject { facts['file_mode'] }
    it { should eq '600 root root' }
  end
  describe 'TOKEN lines holding 64 hex characters' do
    subject { facts['token_lines'] }
    it { should cmp 1 }
  end
  describe 'exit status ensuring TOKEN again' do
    subject { facts['again_rc'] }
    it { should cmp 0 }
  end
  describe 'env file unchanged by ensuring TOKEN again' do
    subject { facts['generated_kept'] }
    it { should eq 'yes' }
  end
  describe 'exit status ensuring a key that is already set' do
    subject { facts['existing_rc'] }
    it { should cmp 0 }
  end
  describe 'a key set before the call' do
    subject { facts['existing'] }
    it { should eq 'EXISTING=value-set-before' }
  end
  describe 'exit status for an invalid key name' do
    subject { facts['bad_key_rc'] }
    it { should match(/\A[1-9][0-9]*\z/) }
  end
  describe 'exit status for fewer than 16 random bytes' do
    subject { facts['short_rc'] }
    it { should match(/\A[1-9][0-9]*\z/) }
  end
  describe 'lines written for the rejected request' do
    subject { facts['short_lines'] }
    it { should cmp 0 }
  end
  instance_exec(facts, &scratch_removed)
end
