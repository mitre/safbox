# frozen_string_literal: true

require 'shellwords'

# Two controls per tools task group n (ADR-0001 Phase 3):
#   safbox-fips-exercise-n  the tool does TLS or SHA-256 hashing under FIPS
#                           enforcement (impact 1.0)
#   safbox-fips-provider-n  the tool's cryptography is the system OpenSSL
#                           FIPS provider (low)
# A tool left out of expected_tools skips both; an expected tool that is
# missing fails its exercise. Every control first asserts FIPS enforcement,
# so a host that does not enforce it fails the profile instead of skipping
# it, and no tool is exercised there.
#
# Each exercise is one scripted command: a scratch directory under /root (a
# hardened /tmp may be noexec, and Packer executes scripts from its temp
# directory) holds everything the tool writes, with HOME and TMPDIR pointing
# into it, and the script removes it on exit; a describe then asserts it is
# gone. The script prints each step as "### <step> rc=<n>" followed by the
# step's output, and each behaviour is asserted on that. One bash -c,
# because sudo (the profile's --sudo) applies to the first word of a command
# line only. Tools under /usr/local/bin are named by full path: sudo's
# secure_path does not include /usr/local/bin.

expected_tools = input('expected_tools').map(&:to_s)
tool_expected = ->(tool) { expected_tools.include?(tool) }
url = input('fips_exercise_url')

fips_enabled = file('/proc/sys/crypto/fips_enabled').content.to_s.strip
crypto_policy = command('update-crypto-policies --show').stdout.strip
fips_provider_active = command('openssl list -providers').stdout
                       .match?(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/)
fips_enforced = fips_enabled == '1' && crypto_policy.match?(/\AFIPS(:|\z)/) && fips_provider_active

fips_precondition = lambda do
  describe 'FIPS enforcement: /proc/sys/crypto/fips_enabled' do
    subject { fips_enabled }
    it { should cmp '1' }
  end
  describe 'FIPS enforcement: system-wide crypto policy' do
    subject { crypto_policy }
    it { should match(/\AFIPS(:|\z)/) }
  end
  describe 'FIPS enforcement: OpenSSL FIPS provider active' do
    subject { fips_provider_active }
    it { should eq true }
  end
end

prelude = <<~'SH'
  set -uo pipefail
  work=$(mktemp -d /root/safbox-fips-exercise.XXXXXX) || exit 1
  trap 'cd / && rm -rf "$work"' EXIT
  cd "$work" || exit 1
  export HOME=$work TMPDIR=$work LC_ALL=C.UTF-8
  printf 'scratch %s\n' "$work"
  step() {
    local name=$1 rc
    shift
    "$@" >"$work/step.log" 2>&1
    rc=$?
    printf '### %s rc=%d\n' "$name" "$rc"
    cat "$work/step.log"
    printf '\n'
  }
SH

# Runs a script after the prelude with the given shell variables set;
# returns the scratch directory and the steps, name => {rc, output}.
run_script = lambda do |vars, body|
  assignments = vars.map { |name, value| "#{name}=#{Shellwords.escape(value.to_s)}\n" }.join
  stdout = command("bash -c #{Shellwords.escape(assignments + prelude + body)}").stdout
  scratch = nil
  steps = {}
  current = nil
  stdout.each_line do |line|
    if (m = line.match(/\A### (\S+) rc=(\d+)$/))
      current = steps[m[1]] = { 'rc' => m[2].to_i, 'output' => String.new }
    elsif current
      current['output'] << line
    elsif (m = line.match(/\Ascratch (\S+)$/))
      scratch = m[1]
    end
  end
  [scratch, steps]
end

# The common part of every exercise: FIPS enforcement, the tool present,
# then the script, then the scratch directory gone. Returns the steps, or
# nil when the tool was not exercised (and the control has failed).
exercise = lambda do |label, path, vars, body|
  instance_exec(&fips_precondition)
  present = command(path).exist?
  describe "#{label} (#{path}) on the target" do
    subject { present }
    it { should eq true }
  end
  next nil unless fips_enforced && present

  scratch, steps = run_script.call(vars, body)
  describe "scratch directory #{scratch} removed after the exercise" do
    subject { scratch.nil? ? 'never created' : file(scratch).exist? }
    it { should eq false }
  end
  steps
end

# A step ran and exited 0; on failure the message carries its output.
step_succeeded = lambda do |steps, name, label|
  describe label do
    subject { steps.fetch(name, { 'rc' => nil, 'output' => 'step did not run' }) }
    it { should include('rc' => 0) }
  end
end

control 'safbox-fips-exercise-1' do
  impact 1.0
  title 'CINC Auditor does TLS and SHA-256 hashing under FIPS enforcement'
  desc 'ADR-0001 Phase 3: each shipped tool is exercised once under FIPS enforcement. CINC Auditor runs a profile whose http resource fetches the exercise URL over TLS and whose file resource computes a SHA-256 digest.'
  only_if('CINC Auditor is not in expected_tools (tools group safbox-tools-1 switched off)') do
    tool_expected.call('cinc-auditor')
  end

  steps = instance_exec('CINC Auditor', 'cinc-auditor', { url: url }, <<~'SH', &exercise)
    mkdir -p profile/controls
    printf 'name: fips-exercise\nversion: 0.1.0\nsupports:\n  - platform: os\n' >profile/inspec.yml
    cat >profile/controls/exercise.rb <<'RUBY'
    control 'fips-exercise-1' do
      describe http(ENV.fetch('EXERCISE_URL')) do
        its('status') { should cmp 200 }
      end
      describe file('/etc/os-release') do
        its('sha256sum') { should match(/\A\h{64}\z/) }
      end
    end
    RUBY
    step exec env EXERCISE_URL="$url" cinc-auditor exec "$work/profile" --no-color \
      --chef-license accept-no-persist --reporter "json:$work/results.json"
    step results cat "$work/results.json"
  SH
  if steps
    instance_exec(steps, 'exec', 'CINC Auditor exec of the exercise profile', &step_succeeded)
    results = begin
      JSON.parse(steps.dig('results', 'output').to_s).dig('profiles', 0, 'controls', 0, 'results') || []
    rescue JSON::ParserError
      []
    end
    { 'http' => 'CINC Auditor http resource: GET over TLS', 'file' => 'CINC Auditor file resource: sha256sum' }
      .each do |resource, label|
        describe label do
          subject { results.find { |r| r['resource_class'] == resource }&.fetch('status', nil) }
          it { should eq 'passed' }
        end
      end
  end
end

control 'safbox-fips-exercise-2' do
  impact 1.0
  title 'The SAF CLI converts results and hashes a profile with SHA-256 under FIPS enforcement'
  desc "ADR-0001 Phase 3: each shipped tool is exercised once under FIPS enforcement. The SAF CLI converts a recorded CINC Auditor result to a checklist and back; the checklist-to-HDF mapper hashes the profile with SHA-256 through Node.js crypto."
  only_if('the SAF CLI is not in expected_tools (tools group safbox-tools-2 switched off)') do
    tool_expected.call('saf-cli')
  end

  # files/saf-cli-input.json: the JSON result of safbox-fips-exercise-1's
  # CINC Auditor exercise profile (same files, flags and scratch layout, run
  # once by hand as root on a FIPS-mode clone), trimmed with
  # tests/verify/fixtures/trim-onbox.py.
  hdf = [inspec.profile.file('saf-cli-input.json')].pack('m0')
  steps = instance_exec('SAF CLI', '/usr/local/bin/saf', { hdf_b64: hdf }, <<~'SH', &exercise)
    printf '%s' "$hdf_b64" | base64 -d >input.json
    step hdf2ckl /usr/local/bin/saf convert hdf2ckl -i input.json -o exercise.ckl
    step ckl2hdf /usr/local/bin/saf convert ckl2hdf -i exercise.ckl -o roundtrip.json
    step digest node -e 'process.stdout.write(require(process.argv[1]).profiles[0].sha256 || "")' \
      "$work/roundtrip.json"
  SH
  if steps
    instance_exec(steps, 'hdf2ckl', 'SAF CLI convert hdf2ckl', &step_succeeded)
    instance_exec(steps, 'ckl2hdf', 'SAF CLI convert ckl2hdf', &step_succeeded)
    describe 'profile SHA-256 digest computed by the checklist-to-HDF mapper' do
      subject { steps.dig('digest', 'output').to_s.strip }
      it { should match(/\A\h{64}\z/) }
    end
  end
end

control 'safbox-fips-exercise-3' do
  impact 1.0
  title 'Ansible does TLS and SHA-256 hashing under FIPS enforcement'
  desc 'ADR-0001 Phase 3: each shipped tool is exercised once under FIPS enforcement. The uri module fetches the exercise URL over TLS and the stat module computes a SHA-256 checksum (Python ssl and hashlib).'
  only_if('Ansible is not in expected_tools (tools group safbox-tools-3 switched off)') do
    tool_expected.call('ansible')
  end

  steps = instance_exec('Ansible', 'ansible', { url: url }, <<~'SH', &exercise)
    export ANSIBLE_HOME=$work/ansible ANSIBLE_LOCAL_TEMP=$work/ansible/tmp ANSIBLE_REMOTE_TEMP=$work/ansible/tmp \
      ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False ANSIBLE_NOCOLOR=1
    step uri ansible localhost -c local -m ansible.builtin.uri -a "url=$url"
    step stat ansible localhost -c local -m ansible.builtin.stat -a 'path=/etc/os-release follow=true checksum_algorithm=sha256'
  SH
  if steps
    instance_exec(steps, 'uri', 'Ansible uri module: GET over TLS', &step_succeeded)
    describe 'Ansible uri module response status' do
      subject { steps.dig('uri', 'output').to_s }
      it { should match(/"status": 200\b/) }
    end
    instance_exec(steps, 'stat', 'Ansible stat module: sha256 checksum', &step_succeeded)
    describe 'Ansible stat module checksum' do
      subject { steps.dig('stat', 'output').to_s }
      it { should match(/"checksum": "\h{64}"/) }
    end
  end
end

control 'safbox-fips-exercise-4' do
  impact 1.0
  title 'Packer does TLS and SHA-256 hashing under FIPS enforcement'
  desc "ADR-0001 Phase 3: each shipped tool is exercised once under FIPS enforcement. Packer's http data source fetches the exercise URL over TLS and the HCL sha256() function hashes the body, with Go's FIPS 140-3 mode requested (GODEBUG=fips140=on)."
  only_if('Packer is not in expected_tools (tools group safbox-tools-4 switched off)') do
    tool_expected.call('packer')
  end

  steps = instance_exec('Packer', '/usr/local/bin/packer', { url: url }, <<~'SH', &exercise)
    cat >exercise.pkr.hcl <<'HCL'
    variable "url" {
      type = string
    }

    data "http" "exercise" {
      url = var.url
    }

    locals {
      digest = sha256(data.http.exercise.body)
    }

    source "null" "exercise" {
      communicator = "none"
    }

    build {
      sources = ["source.null.exercise"]

      post-processor "shell-local" {
        inline = ["echo exercise-digest=${local.digest}"]
      }
    }
    HCL
    export CHECKPOINT_DISABLE=1 PACKER_CONFIG_DIR=$work/packer PACKER_PLUGIN_PATH=$work/packer/plugins \
      PACKER_CACHE_DIR=$work/packer/cache
    step build env GODEBUG=fips140=on /usr/local/bin/packer build -color=false -var "url=$url" \
      "$work/exercise.pkr.hcl"
  SH
  if steps
    # The http data source fails the build on any non-2xx response.
    instance_exec(steps, 'build', 'Packer build with the http data source: GET over TLS', &step_succeeded)
    describe 'SHA-256 digest of the response computed by Packer' do
      subject { steps.dig('build', 'output').to_s }
      it { should match(/exercise-digest=\h{64}\b/) }
    end
  end
end

control 'safbox-fips-provider-1' do
  impact 0.3
  title "CINC Auditor's cryptography is the system OpenSSL FIPS provider"
  desc "Known finding. CINC Auditor runs on its own embedded Ruby and OpenSSL, so its TLS and hashing bypass the system's validated FIPS provider, even on a FIPS-enforcing host. Tracked as safbox-m5f.18."
  tag issue: 'safbox-m5f.18'
  only_if('CINC Auditor is not in expected_tools (tools group safbox-tools-1 switched off)') do
    tool_expected.call('cinc-auditor')
  end

  instance_exec(&fips_precondition)
  bin = command('readlink -f "$(command -v cinc-auditor)"').stdout.strip
  ruby = "#{File.dirname(bin)}/../embedded/bin/ruby"
  library = command("#{ruby} -ropenssl -e 'print OpenSSL::OPENSSL_LIBRARY_VERSION'").stdout.strip
  describe "OpenSSL FIPS mode in CINC Auditor's embedded Ruby (#{library})" do
    subject { command("#{ruby} -ropenssl -e 'print OpenSSL.fips_mode'").stdout.strip }
    it { should cmp 'true' }
  end
end

control 'safbox-fips-provider-2' do
  impact 0.3
  title "The SAF CLI's cryptography is the system OpenSSL FIPS provider"
  desc "The SAF CLI runs on the distribution's Node.js, which uses the system OpenSSL; in FIPS mode Node.js must report its FIPS provider in use."
  only_if('the SAF CLI is not in expected_tools (tools group safbox-tools-2 switched off)') do
    tool_expected.call('saf-cli')
  end

  instance_exec(&fips_precondition)
  describe command(%q(node -p "require('crypto').getFips()")) do
    its('exit_status') { should eq 0 }
    its('stdout.strip') { should cmp '1' }
  end
end

control 'safbox-fips-provider-3' do
  impact 0.3
  title "Ansible's cryptography is the system OpenSSL FIPS provider"
  desc "Ansible runs on the distribution's Python, whose ssl and hashlib use the system OpenSSL; in FIPS mode hashlib must report FIPS mode."
  only_if('Ansible is not in expected_tools (tools group safbox-tools-3 switched off)') do
    tool_expected.call('ansible')
  end

  instance_exec(&fips_precondition)
  python = command('head -n 1 "$(command -v ansible)"').stdout.sub(/\A#!\s*/, '').strip
  describe command("#{python} -c 'import _hashlib; print(_hashlib.get_fips_mode())'") do
    its('exit_status') { should eq 0 }
    its('stdout.strip') { should cmp '1' }
  end
end

control 'safbox-fips-provider-4' do
  impact 0.3
  title "Packer's cryptography is the system OpenSSL FIPS provider"
  desc "Known finding. Packer is a statically linked Go binary: its TLS and hashing use Go's own cryptographic module, not the system's validated FIPS provider, and whether Go's FIPS 140-3 mode is in effect cannot be verified from outside. Passing requires a Packer binary dynamically linked against the system libcrypto (ldd lists libcrypto.so); a build that loads OpenSSL at run time with dlopen, such as a golang-fips toolchain build, still fails, because the link cannot be shown without running it. Tracked as safbox-m5f.19."
  tag issue: 'safbox-m5f.19'
  only_if('Packer is not in expected_tools (tools group safbox-tools-4 switched off)') do
    tool_expected.call('packer')
  end

  instance_exec(&fips_precondition)
  describe 'shared libraries /usr/local/bin/packer links' do
    subject { command('ldd /usr/local/bin/packer 2>&1').stdout }
    it { should match(%r{libcrypto\.so\.\d+ => /\S+}) }
  end
end
