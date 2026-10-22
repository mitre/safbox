# frozen_string_literal: true

require 'digest'

# Heimdall and Vulcan each run as a podman pod (the application and its
# PostgreSQL) on the loopback address, behind one nginx TLS proxy. The units
# are installed at build and start once first boot has made their secrets,
# so the build VM has units and no secrets, and a deployed clone has both
# and runs them. A secret's value is only ever read into a pipe on the box
# (grep's pattern file), and only counts reach the results.
#
# Quadlet units are systemd unit files: parse_config_file with
# multiple_values reads each [Section] and keeps every value of a key that
# repeats (Environment=), so each key is a list.

services = input('expected_services')
deployed = input('deployed')
domain = input('domain')
quadlet = '/etc/containers/systemd'
trust_store = '/etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro'
pinned = /@sha256:\h{64}$/
# Every database runs the CentOS Stream build of the sclorg PostgreSQL image,
# whose OpenSSL has a FIPS provider: safbox-heimdall-5, safbox-vulcan-4 and
# safbox-keycloak-6 check it in the running containers.
postgresql = %r{^quay\.io/sclorg/postgresql-\d+-c9s@sha256:\h{64}$}
# The names the proxy serves besides the domain, one per application.
served_apps = %w[heimdall vulcan keycloak]

# Each service's per-install secrets: podman secrets first boot makes, each
# given to the containers that read it as one environment variable each
# (Quadlet Secret=, type=env), by container. A client secret reaches the
# application and Keycloak, so it exists only while both are switched on.
keycloak = services.include?('keycloak')
secret_targets = {}
if services.include?('heimdall')
  secret_targets.merge!(
    'heimdall-database-password' => { 'heimdall' => 'DATABASE_PASSWORD', 'heimdall-db' => 'POSTGRESQL_PASSWORD' },
    'heimdall-jwt-secret' => { 'heimdall' => 'JWT_SECRET' },
    'heimdall-api-key-secret' => { 'heimdall' => 'API_KEY_SECRET' },
    'heimdall-admin-password' => { 'heimdall' => 'ADMIN_PASSWORD' }
  )
  secret_targets['heimdall-oidc-client-secret'] = { 'heimdall' => 'OIDC_CLIENT_SECRET', 'keycloak' => 'OIDC_CLIENT_SECRET' } if keycloak
end
if services.include?('vulcan')
  secret_targets.merge!(
    'vulcan-database-password' => { 'vulcan' => 'POSTGRES_PASSWORD', 'vulcan-db' => 'POSTGRESQL_PASSWORD' },
    'vulcan-secret-key-base' => { 'vulcan' => 'SECRET_KEY_BASE' },
    'vulcan-cipher-password' => { 'vulcan' => 'CIPHER_PASSWORD' },
    'vulcan-cipher-salt' => { 'vulcan' => 'CIPHER_SALT' },
    'vulcan-admin-password' => { 'vulcan' => 'VULCAN_ADMIN_PASSWORD' }
  )
  secret_targets['vulcan-oidc-client-secret'] = { 'vulcan' => 'VULCAN_OIDC_CLIENT_SECRET', 'keycloak' => 'VULCAN_OIDC_CLIENT_SECRET' } if keycloak
end
if keycloak
  secret_targets.merge!(
    'keycloak-database-password' => { 'keycloak' => 'KC_DB_PASSWORD', 'keycloak-db' => 'POSTGRESQL_PASSWORD' },
    'keycloak-bootstrap-admin-password' => { 'keycloak' => 'KC_BOOTSTRAP_ADMIN_PASSWORD' },
    'keycloak-safuser-password' => { 'keycloak' => 'SAFUSER_PASSWORD' }
  )
end
# What a container's unit declares: its Secret= lines, and an ExecCondition=
# per secret of the unit's containers, so it starts only once first boot
# has made them.
container_secrets = ->(container) { secret_targets.filter_map { |name, to| "#{name},type=env,target=#{to[container]}" if to.key?(container) } }
secret_conditions = ->(*containers) { secret_targets.filter_map { |name, to| "/usr/bin/podman secret exists #{name}" if containers.any? { |c| to.key?(c) } } }

control 'safbox-secrets-1' do
  impact 1.0
  title "The services' secrets are podman secrets made on first boot only, root's alone, and no container's configuration shows one"
  desc "First boot makes each switched-on service's secrets as podman secrets (Heimdall's database password, JWT secret, API key secret and administrator password; Vulcan's database password, Rails secret key base, cipher password and salt and administrator password; Keycloak's database password, bootstrap administrator's password and safuser's initial Keycloak password; and, with Keycloak on, each application's Keycloak client secret) in the root-only secret store (its file driver keeps them in one 0600 file under /var/lib/containers), and each container receives its secrets as environment variables through Quadlet Secret=, which podman inspect masks. No env file under /etc/safbox holds them; safuser's generated OS password, in safuser.env, is the one plaintext secret there. The build VM holds no podman secret (the seal asserts the same of the template). Each container's podman inspect is searched for every secret's value, read on the box into grep's pattern file, and for any password or secret variable that is not masked; only counts are reported. safuser's initial Keycloak password carries a note (its description label) that it must be changed at the first sign-in and that the secret is not updated when it is, and the realm file holds placeholders only."
  only_if('Heimdall, Vulcan and Keycloak are switched off', impact: 0.0) { secret_targets.any? }

  secret_targets.each_key do |name|
    describe command("podman secret exists #{name}") do
      its('exit_status') { should eq(deployed ? 0 : 1) }
    end
  end
  describe command("find /etc/safbox -maxdepth 1 -name '*.env' ! -name safuser.env -print") do
    its('stdout') { should eq '' }
  end
  if deployed
    describe file('/var/lib/containers/storage/secrets/filedriver/secretsdata.json') do
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0600' }
    end
    secret_values = 'for n in $(podman secret ls --noheading --format "{{.Name}}"); do podman secret inspect --showsecret --format "{{.SecretData}}" "$n"; echo; done | grep .'
    secret_targets.values.flat_map(&:keys).uniq.each do |container|
      describe "Lines of podman inspect #{container} holding a secret's value" do
        subject { command(%(bash -c 'podman inspect #{container} | grep -cF -f <(#{secret_values})')).stdout.strip }
        it { should cmp 0 }
      end
      describe "Password and secret variables podman inspect #{container} shows unmasked" do
        subject { command(%(bash -c 'podman inspect --format "{{range .Config.Env}}{{println .}}{{end}}" #{container} | grep -E "^[A-Z_]*(PASSWORD|SECRET)[A-Z_]*=" | grep -cv "=[*][*]*$"')).stdout.strip }
        it { should cmp 0 }
      end
    end
  else
    describe command('podman secret ls --quiet') do
      its('stdout') { should eq '' }
    end
  end
  # Keycloak's: counted with grep, so no report ever shows the secret.
  if keycloak && deployed
    describe command(%q(sh -c 'podman secret inspect --showsecret --format "{{.SecretData}}" keycloak-safuser-password | grep -cxE "[0-9a-f]{32}"')) do
      its('stdout') { should eq "1\n" }
    end
    describe command(%q(podman secret inspect --format '{{index .Spec.Labels "description"}}' keycloak-safuser-password)) do
      its('stdout') { should match(/\Asafuser's initial Keycloak password\. It must be changed at the first sign-in, and this secret is not updated when it changes\.$/) }
    end
  end
  if keycloak
    describe file('/etc/safbox-keycloak/safbox-realm.json') do
      its('content') { should_not match(/"(secret|value)": "(?!\$\{)/) }
    end
  end
end

control 'safbox-heimdall-1' do
  impact 1.0
  title 'The Heimdall Quadlet units are installed'
  desc 'Heimdall and its database run from images pinned by digest, the database from the CentOS Stream PostgreSQL image, with memory limits, no new privileges and the host CA trust store mounted read-only. The pod publishes 127.0.0.1:3000 only and waits for first boot to make its secrets, which each container receives as podman secrets (no env file); the unit is ready only once Heimdall answers its healthcheck. Registration is off: the only local account is the administrator, admin@<domain>, made on the first start with the password first boot made. With Keycloak on, everyone else signs in through it.'
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  describe parse_config_file("#{quadlet}/heimdall.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3000:3000'] }
    its('Unit.ConditionPathExists') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('heimdall', 'heimdall-db') }
    # Inside a pod 127.0.0.1 is the pod: Keycloak's name must reach the proxy on the host.
    if services.include?('keycloak')
      its('Pod.AddHost') { should eq ["keycloak.#{domain}:host-gateway"] }
    else
      its('Pod.AddHost') { should be_nil }
    end
  end
  describe parse_config_file("#{quadlet}/heimdall.container", multiple_values: true) do
    # Ready only once it answers, so the end of boot waits for it.
    its('Container.HealthCmd') { should eq ['curl -fsS -o /dev/null http://localhost:3000/'] }
    its('Container.Notify') { should eq ['healthy'] }
    its('Container.Image') { should all match(pinned) }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Volume') { should include trust_store }
    its('Container.Environment') { should include "EXTERNAL_URL=https://heimdall.#{domain}" }
    its('Container.Environment') { should include 'REGISTRATION_DISABLED=true' }
    its('Container.Environment') { should include "ADMIN_EMAIL=admin@#{domain}" }
    if services.include?('keycloak')
      its('Container.Environment') { should include "OIDC_ISSUER=https://keycloak.#{domain}/realms/safbox" }
      its('Container.Environment') { should include 'OIDC_USES_PKCE_S256=true' }
    else
      its('Container.Environment') { should_not include(a_string_starting_with('OIDC_')) }
    end
    its('Container.Secret') { should match_array container_secrets.call('heimdall') }
    its('Container.EnvironmentFile') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('heimdall') }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/heimdall-db.container", multiple_values: true) do
    its('Container.Image') { should all match(postgresql) }
    its('Container.Memory') { should_not be_empty }
    its('Container.Secret') { should match_array container_secrets.call('heimdall-db') }
    its('Container.EnvironmentFile') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('heimdall-db') }
  end
end

control 'safbox-heimdall-3' do
  impact 1.0
  title 'Heimdall is up on the loopback address only, with FIPS-mode crypto'
  desc 'Heimdall and its database run, Heimdall answers on 127.0.0.1:3000 for the proxy and nowhere else, and Node.js inside the container runs in FIPS mode.'
  only_if('Heimdall is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('heimdall') && deployed }

  %w[heimdall heimdall-db].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe port(3000) do
    its('addresses') { should eq ['127.0.0.1'] }
  end
  describe http('http://127.0.0.1:3000/') do
    its('status') { should eq 200 }
  end
  describe command(%q(podman exec heimdall node -p "require('crypto').getFips()")) do
    its('stdout.strip') { should eq '1' }
  end
end

control 'safbox-heimdall-5' do
  impact 1.0
  title "Heimdall's PostgreSQL runs its crypto in FIPS mode"
  desc "PostgreSQL computes its password hashes (SCRAM-SHA-256) and digest functions with the OpenSSL in its container. That OpenSSL has its FIPS provider active under the host's FIPS crypto policy, so PostgreSQL refuses MD5; it stores passwords as SCRAM-SHA-256 only, and accepts no password method other than SCRAM-SHA-256 over TCP and no unauthenticated connection: only its own administrator signs in, over the container's local socket (peer). The provider is the CentOS Stream build of OpenSSL's FIPS provider, which runs in FIPS mode but carries no CMVP certificate."
  only_if('Heimdall is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('heimdall') && deployed }

  # As the database's own administrator, over the container's local socket.
  psql = 'podman exec -u postgres heimdall-db psql -X -A -t -c'
  describe command('podman exec heimdall-db openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec heimdall-db cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
  describe command(%(#{psql} "SELECT md5('safbox')")) do
    its('exit_status') { should_not eq 0 }
    its('stderr') { should match(/could not compute MD5 hash/) }
  end
  describe command(%(#{psql} "SELECT encode(sha256('abc'), 'hex')")) do
    its('stdout.strip') { should eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
  end
  describe command(%(#{psql} "SHOW password_encryption")) do
    its('stdout.strip') { should eq 'scram-sha-256' }
  end
  describe command(%(#{psql} "SELECT DISTINCT type || ' ' || auth_method FROM pg_hba_file_rules ORDER BY 1")) do
    its('stdout') { should eq "host scram-sha-256\nlocal peer\n" }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword NOT LIKE 'SCRAM-SHA-256%'")) do
    its('exit_status') { should eq 0 }
    its('stdout') { should eq '' }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'SCRAM-SHA-256%'")) do
    its('stdout') { should eq "heimdall\n" }
  end
end

control 'safbox-heimdall-6' do
  impact 1.0
  title 'Heimdall offers local log in and refuses sign-ups'
  desc "Through the proxy, Heimdall's /server document says local log in is on and registration is off, and a sign-up posted to its API is refused with 403, so the administrator, admin@<domain>, is its only local account. Heimdall checks a sign-up's fields before the registration switch (a weak password answers 400), so the sign-up's password meets its complexity rules (15 characters or more, upper and lower case, digits and symbols, never four of one class in a row) and only the switch can refuse it. That password is made on the box from openssl rand and handed to curl on its standard input, so it is in no command line, no resource parameter and no report."
  only_if('Heimdall or the proxy is switched off, or this is not a deployed clone', impact: 0.0) do
    services.include?('heimdall') && services.include?('proxy') && deployed
  end

  describe "https://heimdall.#{domain}/server" do
    subject { json(content: http("https://heimdall.#{domain}/server").body) }
    its('registrationEnabled') { should eq false }
    its('localLoginEnabled') { should eq true }
  end
  # Each of 24 random hex digits followed by Qa7!: 120 characters. One
  # pipeline, so no step needs a shell variable (with --sudo, CINC Auditor
  # puts sudo before the first command only).
  json = '{"email":"safbox-test-signup@example.invalid","password":"&","passwordConfirmation":"&",' \
         '"firstName":"SAFBox","lastName":"Test","role":"user","creationMethod":"local"}'
  sign_up = "openssl rand -hex 12 | sed -e 's/./&Qa7!/g' -e 's/.*/#{json}/' " \
            "| curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- https://heimdall.#{domain}/users"
  describe "A sign-up posted to https://heimdall.#{domain}/users" do
    subject { command(sign_up) }
    its('stdout') { should eq '403' }
  end
end

# The build gate's results the seal installs in the template, and their
# import into Heimdall once per box, after first boot
# (safbox-heimdall-scans.service).
scans_dir = '/usr/local/share/safbox/scans'
scans_marker = '/var/lib/safbox/heimdall-scans.done'
scans_unit = '/etc/systemd/system/safbox-heimdall-scans.service'

control 'safbox-heimdall-7' do
  impact 0.5
  title "The unit that imports the template's scan results into Heimdall is installed and enabled"
  desc "safbox-heimdall-scans.service runs the first-boot play's clone_heimdall_scans role (the heimdall-scans tag) once per box. It runs after Heimdall answers its healthcheck, and only while the template holds the build gate's results and the box has not imported them yet. A preset keeps it enabled through a First Boot."
  only_if('Heimdall is switched off', impact: 0.0) { services.include?('heimdall') }

  describe file(scans_unit) do
    it { should be_file }
  end
  describe parse_config_file(scans_unit, multiple_values: true) do
    its('Unit.After') { should eq ['heimdall.service safbox-firstboot.service'] }
    its('Unit.ConditionPathExists') { should match_array ["!#{scans_marker}", "#{scans_dir}/manifest.json"] }
    its('Service.Type') { should eq ['oneshot'] }
    its('Service.ExecStart') { should eq ['/usr/bin/ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags heimdall-scans'] }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe 'safbox-heimdall-scans.service: its state and its preset' do
    subject { command('systemctl list-unit-files --no-legend --no-pager safbox-heimdall-scans.service').stdout.split[1, 2] }
    it { should eq %w[enabled enabled] }
  end
end

control 'safbox-heimdall-8' do
  impact 0.5
  title "Heimdall holds the template's build-gate scan results, public to every signed-in user"
  desc "The seal installs the build gate's results for the safbox and STIG overlay profiles in the template, root's alone, under #{scans_dir}. Their manifest names the build run, and each scan's profile, file, date and sha256. Once after first boot, Heimdall's administrator uploads each one as a public evaluation, so every user who signs in sees it, safuser included at its first sign-in through Keycloak. Each evaluation is named safbox-build-<run>-<profile>.json and tagged safbox-build-scan, run <run> and scanned <date>, and the STIG overlay's also STIG. Heimdall stores each as the HDF itself, which its viewer loads: the source file's profiles with as many controls in each, not the file's text. The import leaves a marker, so it runs once. The check reads Heimdall's database as its own administrator over the container's local socket, with no credential."
  only_if('Heimdall is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('heimdall') && deployed }
  only_if('The template was built without the build gate (input build_scans)', impact: 0.0) { input('build_scans') } if services.include?('heimdall') && deployed

  describe directory(scans_dir) do
    it { should be_owned_by 'root' }
    its('mode') { should cmp '0700' }
  end
  # Root's alone, so read through a command (sudo), not the file resource.
  manifest = json(content: command("cat #{scans_dir}/manifest.json").stdout)
  describe manifest do
    its('run_id') { should match(/\A\S+\z/) }
    its('git_commit') { should match(/\A\S+\z/) }
    its(['scans']) { should_not be_empty }
  end
  scans = manifest.params.is_a?(Hash) ? Array(manifest.params['scans']) : []
  describe 'The profiles the manifest names' do
    subject { scans.map { |scan| scan['profile'] } }
    it { should match_array %w[safbox safbox-rhel10-stig-overlay] }
  end
  describe file(scans_marker) do
    it { should be_file }
  end
  # As the database's own administrator, over the container's local socket.
  # The literals are dollar-quoted, so the command needs no quoting layer
  # but the shell's single quotes.
  psql = 'podman exec -u postgres heimdall-db psql -X -A -t -d heimdall-server-production -c'
  run_id = manifest.params.is_a?(Hash) ? manifest.params['run_id'].to_s : ''
  scans.each do |scan|
    describe file("#{scans_dir}/#{scan['file']}") do
      it { should be_file }
      it { should be_owned_by 'root' }
      its('mode') { should cmp '0600' }
      its('sha256sum') { should eq scan['sha256'] }
    end
    name = "safbox-build-#{run_id}-#{scan['profile']}.json"
    # The tags in byte order (COLLATE "C"), whatever the database's locale.
    query = 'SELECT e.public, u.email, string_agg(t.value, $s$,$s$ ORDER BY t.value COLLATE "C") FROM "Evaluations" e ' \
            'JOIN "Users" u ON u.id = e."userId" LEFT JOIN "EvaluationTags" t ON t."evaluationId" = e.id ' \
            "WHERE e.filename = $f$#{name}$f$ GROUP BY e.id, u.email"
    tags = ["run #{run_id}", 'safbox-build-scan', "scanned #{scan['scanned']}"]
    tags << 'STIG' if scan['profile'] == 'safbox-rhel10-stig-overlay'
    # safbox-client-keycloak-2 reads the evaluation's name from this
    # description in the results: keep "Heimdall's evaluation <name>:".
    describe "Heimdall's evaluation #{name}: public, its owner, its tags" do
      subject { command("#{psql} '#{query}'").stdout }
      it { should eq "t|admin@#{domain}|#{tags.sort.join(',')}\n" }
    end
    # What Heimdall stores is the HDF itself, which its viewer loads: the
    # source file's profiles, with as many controls in each. A file Heimdall
    # could not parse as JSON is kept as text under originalResultsData,
    # with no profiles.
    source = json(content: command("cat #{scans_dir}/#{scan['file']}").stdout).params
    source_profiles = source.is_a?(Hash) && source['profiles'].is_a?(Array) ? source['profiles'] : []
    counts = source_profiles.map { |profile| profile.is_a?(Hash) ? profile['controls'].to_a.length : 0 }
    stored = 'SELECT json_array_length(e.data->$k$profiles$k$) || $s$|$s$ || ' \
             '(SELECT string_agg(json_array_length(p->$k$controls$k$)::text, $s$,$s$ ORDER BY n) ' \
             'FROM json_array_elements(e.data->$k$profiles$k$) WITH ORDINALITY AS x(p, n)) ' \
             "FROM \"Evaluations\" e WHERE e.filename = $f$#{name}$f$"
    describe "The source of #{name}, #{scans_dir}/#{scan['file']}: the controls in each profile" do
      subject { counts }
      it { should_not be_empty }
    end
    describe "The HDF Heimdall stores for #{name}: its profiles, and the controls in each" do
      subject { command("#{psql} '#{stored}'").stdout }
      it { should eq "#{counts.length}|#{counts.join(',')}\n" }
    end
  end
end

control 'safbox-vulcan-1' do
  impact 1.0
  title 'The Vulcan Quadlet units are installed'
  desc 'Vulcan and its database run from images pinned by digest, the database from the CentOS Stream PostgreSQL image, with memory limits, no new privileges and the host CA trust store mounted read-only. The pod publishes 127.0.0.1:3001 only and waits for first boot to make its secrets, which each container receives as podman secrets (no env file); the unit is ready only once Vulcan answers its healthcheck. Local login is on and registration is set off (VULCAN_ENABLE_USER_REGISTRATION=false). The administrator, admin@<domain>, is made on the first start with the password first boot made, and no user becomes admin by being first. With Keycloak on, everyone else signs in through it. Known upstream defect, accepted: Vulcan 2.4.1 only hides the sign-up link, so anyone who can reach it can still register a regular local account; this control checks the setting, not that registration is refused.'
  only_if('Vulcan is switched off', impact: 0.0) { services.include?('vulcan') }

  describe parse_config_file("#{quadlet}/vulcan.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3001:3000'] }
    its('Unit.ConditionPathExists') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('vulcan', 'vulcan-db') }
    # Inside a pod 127.0.0.1 is the pod: Keycloak's name must reach the proxy on the host.
    if services.include?('keycloak')
      its('Pod.AddHost') { should eq ["keycloak.#{domain}:host-gateway"] }
    else
      its('Pod.AddHost') { should be_nil }
    end
  end
  describe parse_config_file("#{quadlet}/vulcan.container", multiple_values: true) do
    # Ready only once it answers, so the end of boot waits for it.
    its('Container.HealthCmd') { should eq ['curl -f http://localhost:3000/up || exit 1'] }
    its('Container.Notify') { should eq ['healthy'] }
    its('Container.Image') { should all match(pinned) }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Volume') { should include trust_store }
    its('Container.Environment') { should include 'VULCAN_ENABLE_LOCAL_LOGIN=true' }
    its('Container.Environment') { should include 'VULCAN_ENABLE_USER_REGISTRATION=false' }
    its('Container.Environment') { should include 'VULCAN_FIRST_USER_ADMIN=false' }
    its('Container.Environment') { should include "VULCAN_ADMIN_EMAIL=admin@#{domain}" }
    if services.include?('keycloak')
      its('Container.Environment') { should include 'VULCAN_ENABLE_OIDC=true' }
      its('Container.Environment') { should include "VULCAN_OIDC_ISSUER_URL=https://keycloak.#{domain}/realms/safbox" }
    else
      its('Container.Environment') { should_not include 'VULCAN_ENABLE_OIDC=true' }
    end
    its('Container.Environment') { should include 'RAILS_FORCE_SSL=true' }
    its('Container.Environment') { should include "VULCAN_APP_URL=https://vulcan.#{domain}" }
    its('Container.Secret') { should match_array container_secrets.call('vulcan') }
    its('Container.EnvironmentFile') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('vulcan') }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/vulcan-db.container", multiple_values: true) do
    its('Container.Image') { should all match(postgresql) }
    its('Container.Memory') { should_not be_empty }
    its('Container.Secret') { should match_array container_secrets.call('vulcan-db') }
    its('Container.EnvironmentFile') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('vulcan-db') }
  end
end

control 'safbox-vulcan-3' do
  impact 1.0
  title 'Vulcan is up on the loopback address only, with FIPS-mode crypto'
  desc "Vulcan and its database run, Vulcan answers on 127.0.0.1:3001 for the proxy and nowhere else, and Ruby's OpenSSL inside the container runs in FIPS mode."
  only_if('Vulcan is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('vulcan') && deployed }

  %w[vulcan vulcan-db].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe port(3001) do
    its('addresses') { should eq ['127.0.0.1'] }
  end
  # Vulcan redirects plain HTTP unless the proxy says the client used HTTPS.
  describe http('http://127.0.0.1:3001/up', headers: { 'X-Forwarded-Proto' => 'https' }) do
    its('status') { should eq 200 }
  end
  describe command(%q(podman exec vulcan ruby -ropenssl -e 'print OpenSSL.fips_mode')) do
    its('stdout') { should eq 'true' }
  end
end

control 'safbox-vulcan-4' do
  impact 1.0
  title "Vulcan's PostgreSQL runs its crypto in FIPS mode"
  desc "PostgreSQL computes its password hashes (SCRAM-SHA-256) and digest functions with the OpenSSL in its container. That OpenSSL has its FIPS provider active under the host's FIPS crypto policy, so PostgreSQL refuses MD5; it stores passwords as SCRAM-SHA-256 only, and accepts no password method other than SCRAM-SHA-256 over TCP and no unauthenticated connection: only its own administrator signs in, over the container's local socket (peer). The provider is the CentOS Stream build of OpenSSL's FIPS provider, which runs in FIPS mode but carries no CMVP certificate."
  only_if('Vulcan is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('vulcan') && deployed }

  # As the database's own administrator, over the container's local socket.
  psql = 'podman exec -u postgres vulcan-db psql -X -A -t -c'
  describe command('podman exec vulcan-db openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec vulcan-db cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
  describe command(%(#{psql} "SELECT md5('safbox')")) do
    its('exit_status') { should_not eq 0 }
    its('stderr') { should match(/could not compute MD5 hash/) }
  end
  describe command(%(#{psql} "SELECT encode(sha256('abc'), 'hex')")) do
    its('stdout.strip') { should eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
  end
  describe command(%(#{psql} "SHOW password_encryption")) do
    its('stdout.strip') { should eq 'scram-sha-256' }
  end
  describe command(%(#{psql} "SELECT DISTINCT type || ' ' || auth_method FROM pg_hba_file_rules ORDER BY 1")) do
    its('stdout') { should eq "host scram-sha-256\nlocal peer\n" }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword NOT LIKE 'SCRAM-SHA-256%'")) do
    its('exit_status') { should eq 0 }
    its('stdout') { should eq '' }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'SCRAM-SHA-256%'")) do
    its('stdout') { should eq "vulcan\n" }
  end
end

control 'safbox-keycloak-1' do
  impact 1.0
  title "Keycloak's FIPS image is built on the template from pinned inputs"
  desc "Keycloak runs in FIPS strict mode from an image the build makes from Keycloak's image, pinned by digest, and the four Bouncy Castle FIPS jars Keycloak's FIPS guide asks for, pinned by sha256. The build keeps its Containerfile and the jars' sums in /etc/safbox-keycloak; the jars in the image must have those sums, and the image must have been built with the FIPS strict options."
  only_if('Keycloak is switched off', impact: 0.0) { services.include?('keycloak') }

  # The one tag the build made; the pin itself lives in group_vars.
  images = command(%q(podman images --noheading --format "{{.Repository}}:{{.Tag}}" --filter reference=localhost/safbox-keycloak-fips)).stdout.lines.map(&:strip).reject(&:empty?)
  conf = '/etc/safbox-keycloak'
  describe file("#{conf}/Containerfile") do
    its('content') { should match(%r{^FROM quay\.io/keycloak/keycloak@sha256:\h{64}( AS builder)?$}) }
    its('content') { should_not match(/^FROM (?!quay\.io\/keycloak\/keycloak@sha256:\h{64})/) }
  end
  describe "The derived Keycloak image" do
    subject { images }
    its('length') { should eq 1 }
  end
  image = images.first.to_s
  # Each jar is read out of a created, never started, container. --sudo
  # prefixes sudo to the command's first word only, so each pipeline runs
  # in one root shell (sh -c) to reach root's images.
  file("#{conf}/providers.sha256").content.to_s.lines.map(&:split).each do |sum, jar|
    describe command(%(sh -c 'c=$(podman create #{image}) && podman cp "$c:/opt/keycloak/providers/#{jar}" - | tar -xO | sha256sum; podman rm -f "$c" >/dev/null')) do
      its('stdout') { should start_with sum }
    end
  end
  # kc.sh build records the build options it persists in
  # META-INF/keycloak-persisted.properties inside generated-bytecode.jar.
  # The FIPS mode is compiled into the generated code instead, so strict
  # mode is checked in the build command here and at run time by its
  # Approved Mode log line (safbox-keycloak-4).
  describe file("#{conf}/Containerfile") do
    its('content') { should match(/^RUN \S*kc\.sh build .*--features=fips .*--fips-mode=strict/) }
  end
  describe command(%(sh -c 'm=$(podman image mount #{image}) && unzip -p "$m/opt/keycloak/lib/quarkus/generated-bytecode.jar" META-INF/keycloak-persisted.properties; podman image unmount #{image} >/dev/null')) do
    its('stdout') { should match(/^kc\.features=fips$/) }
    its('stdout') { should match(/^kc\.db=postgres$/) }
    its('stdout') { should match(/^kc\.health-enabled=true$/) }
  end
end

control 'safbox-keycloak-2' do
  impact 1.0
  title 'The Keycloak Quadlet units are installed'
  desc "Keycloak runs from the image built on the template and its database from the CentOS Stream PostgreSQL image, pinned by digest, with memory limits and no new privileges. The pod publishes Keycloak's HTTP port on 127.0.0.1 only, for the proxy, and waits for first boot to make its secrets, which each container receives as podman secrets (no env file), with each enabled application's client secret; the unit is ready only once Keycloak reports itself ready. Keycloak runs a single node (local cache), imports the safbox realm on its first start, and believes forwarded headers only from its network's gateway, where the proxy's connections arrive. The realm's one user, safuser, holds the realm's default role (so its account console works) and must change its generated password at its first sign-in."
  only_if('Keycloak is switched off', impact: 0.0) { services.include?('keycloak') }

  network = parse_config_file("#{quadlet}/keycloak.network", multiple_values: true)
  describe network do
    its('Network.Subnet') { should_not be_empty }
    its('Network.Gateway') { should_not be_empty }
  end
  describe parse_config_file("#{quadlet}/keycloak.pod", multiple_values: true) do
    its('Pod.PublishPort') { should eq ['127.0.0.1:3002:8080'] }
    its('Unit.ConditionPathExists') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('keycloak', 'keycloak-db') }
  end
  describe parse_config_file("#{quadlet}/keycloak.container", multiple_values: true) do
    # Ready only once /health/ready answers, so the end of boot waits for it.
    its('Container.HealthCmd') { should eq [%q({ printf 'HEAD /health/ready HTTP/1.0\r\n\r\n' >&0; grep -q 'HTTP/1.0 200'; } 0<>/dev/tcp/localhost/9000)] }
    its('Container.Notify') { should eq ['healthy'] }
    its('Container.Image') { should all match(%r{^localhost/safbox-keycloak-fips:}) }
    its('Container.Exec') { should eq ['start --optimized --import-realm'] }
    its('Container.Environment') { should include 'KC_CACHE=local' }
    its('Container.Environment') { should include "KC_HOSTNAME=https://keycloak.#{domain}" }
    its('Container.Environment') { should include 'KC_PROXY_HEADERS=xforwarded' }
    its('Container.Environment') { should include "KC_PROXY_TRUSTED_ADDRESSES=#{network.params.dig('Network', 'Gateway')&.first}" }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Container.Memory') { should_not be_empty }
    its('Container.Secret') { should match_array container_secrets.call('keycloak') }
    its('Container.EnvironmentFile') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('keycloak') }
    its('Install.WantedBy') { should eq ['multi-user.target'] }
  end
  describe parse_config_file("#{quadlet}/keycloak-db.container", multiple_values: true) do
    its('Container.Image') { should all match(postgresql) }
    its('Container.Memory') { should_not be_empty }
    its('Container.Secret') { should match_array container_secrets.call('keycloak-db') }
    its('Container.EnvironmentFile') { should be_nil }
    its('Service.ExecCondition') { should match_array secret_conditions.call('keycloak-db') }
  end
  describe json('/etc/safbox-keycloak/safbox-realm.json') do
    its('realm') { should eq 'safbox' }
    its('registrationAllowed') { should eq false }
    its('bruteForceProtected') { should eq true }
    its('passwordPolicy') { should match(/hashAlgorithm\(pbkdf2-sha512\)/) }
  end
  # The import grants an imported user neither the realm's default role nor
  # a required action unless the user lists them.
  safuser = Array(json('/etc/safbox-keycloak/safbox-realm.json').params['users']).find { |u| u['username'] == 'safuser' } || {}
  describe 'safuser in the realm file' do
    subject { safuser }
    its(['realmRoles']) { should eq ['default-roles-safbox'] }
    its(['requiredActions']) { should eq ['UPDATE_PASSWORD'] }
  end
end

control 'safbox-keycloak-4' do
  impact 1.0
  title 'Keycloak is up on the loopback address only, in FIPS strict mode'
  desc "Keycloak and its database run; Keycloak answers on 127.0.0.1:3002 for the proxy and nowhere else, serves the safbox realm, and logged at this boot's start that Bouncy Castle FIPS runs in Approved Mode with the JVM in FIPS mode (strict mode is built into the image: safbox-keycloak-1)."
  only_if('Keycloak is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('keycloak') && deployed }

  %w[keycloak keycloak-db].each do |name|
    describe service(name) do
      it { should be_running }
    end
  end
  describe port(3002) do
    its('addresses') { should eq ['127.0.0.1'] }
  end
  describe http('http://127.0.0.1:3002/realms/safbox/.well-known/openid-configuration') do
    its('status') { should eq 200 }
  end
  describe command('journalctl -b -u keycloak.service --no-pager -o cat') do
    its('stdout') { should match(/FIPS1402Provider created: KC\(BCFIPS version [\d.]+ Approved Mode, FIPS-JVM: enabled\)/) }
  end
end

control 'safbox-keycloak-5' do
  impact 1.0
  title "Keycloak's administration paths answer to the box itself only"
  desc "Keycloak's reverse-proxy guide advises against exposing /admin/ and the master realm. The proxy serves them to requests from the box's own address and refuses every other client; the safbox realm, which the applications and browsers use, is served to all. Keycloak's homepage, its welcome page, would lead to that console and the master realm's sign-in, so the bare name is sent to the safbox account page with a temporary redirect. Refusal from another machine, and the redirect, are checked from outside (safbox-client-keycloak-1 in the safbox-client profile)."
  only_if('Keycloak or the proxy is switched off', impact: 0.0) { services.include?('keycloak') && services.include?('proxy') }

  conf = file('/etc/safbox-proxy/nginx.conf').content.to_s
  %w[/admin/ /realms/master/].each do |path|
    describe "nginx's location for #{path}" do
      subject { conf[/location \^~ #{Regexp.escape(path)} \{[^}]*\}/m] }
      it { should match(/allow 127\.0\.0\.1;/) }
      it { should match(/deny all;/) }
    end
  end
  # Keycloak's homepage leads to the console; the bare name goes to the
  # safbox account page instead.
  account = "https://keycloak.#{domain}/realms/safbox/account/"
  describe "nginx's location for / on Keycloak's name" do
    subject { conf[/location = \/ \{[^}]*\}/m] }
    it { should match(/return 302 #{Regexp.escape(account)};/) }
  end
  if deployed
    describe http("https://keycloak.#{domain}/realms/master/.well-known/openid-configuration") do
      its('status') { should eq 200 }
    end
    describe http("https://keycloak.#{domain}/") do
      its('status') { should eq 302 }
      its('headers.Location') { should eq account }
    end
  end
end

control 'safbox-keycloak-6' do
  impact 1.0
  title "Keycloak's PostgreSQL runs its crypto in FIPS mode"
  desc "PostgreSQL computes its password hashes (SCRAM-SHA-256) and digest functions with the OpenSSL in its container. That OpenSSL has its FIPS provider active under the host's FIPS crypto policy, so PostgreSQL refuses MD5; it stores passwords as SCRAM-SHA-256 only, and accepts no password method other than SCRAM-SHA-256 over TCP and no unauthenticated connection: only its own administrator signs in, over the container's local socket (peer). The provider is the CentOS Stream build of OpenSSL's FIPS provider, which runs in FIPS mode but carries no CMVP certificate."
  only_if('Keycloak is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('keycloak') && deployed }

  # As the database's own administrator, over the container's local socket.
  psql = 'podman exec -u postgres keycloak-db psql -X -A -t -c'
  describe command('podman exec keycloak-db openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec keycloak-db cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
  describe command(%(#{psql} "SELECT md5('safbox')")) do
    its('exit_status') { should_not eq 0 }
    its('stderr') { should match(/could not compute MD5 hash/) }
  end
  describe command(%(#{psql} "SELECT encode(sha256('abc'), 'hex')")) do
    its('stdout.strip') { should eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
  end
  describe command(%(#{psql} "SHOW password_encryption")) do
    its('stdout.strip') { should eq 'scram-sha-256' }
  end
  describe command(%(#{psql} "SELECT DISTINCT type || ' ' || auth_method FROM pg_hba_file_rules ORDER BY 1")) do
    its('stdout') { should eq "host scram-sha-256\nlocal peer\n" }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword NOT LIKE 'SCRAM-SHA-256%'")) do
    its('exit_status') { should eq 0 }
    its('stdout') { should eq '' }
  end
  describe command(%(#{psql} "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'SCRAM-SHA-256%'")) do
    its('stdout') { should eq "keycloak\n" }
  end
end

control 'safbox-proxy-1' do
  impact 1.0
  title 'The TLS proxy unit and its nginx configuration are installed'
  desc "An nginx container from a Red Hat UBI 9 image pinned by digest terminates TLS on port 443, with ciphers from the system crypto policy and TLS 1.2 or later. Each application has its own name under #{domain}; port 80 only redirects to HTTPS, and nothing listens on any other port."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe parse_config_file("#{quadlet}/safbox-proxy.container", multiple_values: true) do
    its('Container.Image') { should all match(%r{^registry\.access\.redhat\.com/ubi9/nginx-\d+@sha256:\h{64}$}) }
    its('Container.Network') { should eq ['host'] }
    its('Container.ReadOnly') { should eq ['true'] }
    its('Container.NoNewPrivileges') { should eq ['true'] }
    its('Container.DropCapability') { should eq ['all'] }
    its('Unit.ConditionPathExists') { should eq ['/etc/safbox/tls/safbox.key'] }
  end
  describe file('/etc/safbox-proxy/nginx.conf') do
    its('content') { should match(/^\s*ssl_ciphers PROFILE=SYSTEM;$/) }
    its('content') { should match(/^\s*ssl_protocols TLSv1\.2 TLSv1\.3;$/) }
    its('content') { should match(/^\s*listen 80 default_server;$/) }
    its('content') { should match(/^\s*listen 443 ssl default_server;$/) }
    its('content') { should_not match(/^\s*listen\s+(?!(80|443)[\s;])/) }
    served_apps.each do |app|
      if services.include?(app)
        its('content') { should match(/^\s*server_name #{Regexp.escape("#{app}.#{domain}")};$/) }
      else
        its('content') { should_not match(/^\s*server_name #{Regexp.escape("#{app}.#{domain}")};$/) }
      end
    end
  end
end

control 'safbox-proxy-2' do
  impact 1.0
  title 'Each name serves its page over HTTPS, with a certificate the box trusts'
  desc "#{domain} and the bare address serve the SAFBox documentation site as the start page, and its status.json lists each shipped application, up, at its own name, and was written after each of them and the proxy last started, with its refresh timer running; each application answers at that name on port 443. The names verify; the bare address does not, as the certificate names only the box's names. First boot adds the local CA that signs the proxy's certificate to the system trust store, so clients on the box verify it."
  only_if('The proxy is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('proxy') && deployed }

  apps = served_apps.select { |app| services.include?(app) }
  # The certificate names only the box's names, so the bare address is
  # fetched without verifying it.
  { "https://#{domain}/" => true, 'https://127.0.0.1/' => false }.each do |url, verify|
    describe http(url, ssl_verify: verify) do
      its('status') { should eq 200 }
      its('body') { should match(%r{<title>SAFBox}) }
    end
  end
  status = json(content: http("https://#{domain}/status.json").body)
  apps.each do |app|
    describe "#{app} in the start page's status.json" do
      subject { status['services'].to_a.find { |s| s['url'].to_s.start_with?("https://#{app}.#{domain}/") } }
      it { should_not be_nil }
      its(['state']) { should eq 'up' }
    end
  end
  # The status is current: each listed unit's start pulls in a rewrite
  # ordered after it, and the timer rewrites it every minute.
  written = file('/etc/safbox-proxy/html/status.json').mtime.to_i
  (apps.map { |app| "#{app}.service" } + ['safbox-proxy.service']).each do |unit|
    started = command("systemctl show --timestamp=unix -P ActiveEnterTimestamp #{unit}").stdout[/\A@(\d+)/, 1]
    describe "The start page's status.json, written at @#{written}, after #{unit} last became active (@#{started})" do
      subject { !started.nil? && written >= started.to_i }
      it { should eq true }
    end
  end
  describe service('safbox-site-status.timer') do
    it { should be_enabled }
    it { should be_running }
  end
  {
    'heimdall' => ['/', %r{<title>Heimdall</title>}],
    'vulcan' => ['/users/sign_in', /Vulcan/],
    'keycloak' => ['/realms/safbox/.well-known/openid-configuration', %r{"issuer":"https://keycloak\.#{Regexp.escape(domain)}/realms/safbox"}],
  }.each do |app, (path, page)|
    next unless apps.include?(app)

    describe http("https://#{app}.#{domain}#{path}") do
      its('status') { should eq 200 }
      its('body') { should match(page) }
    end
  end
end

control 'safbox-proxy-3' do
  impact 1.0
  title 'The box resolves its names to itself, and its first-boot certificate names them'
  desc "/etc/hosts maps #{domain} and each shipped application's name to 127.0.0.1, and a switched-off application's name is not mapped. First boot writes a certificate for exactly those names, signed by a local CA of the box's own that may sign only server certificates for names under #{domain}, and no IP address, and the system trust store, as extracted for every client on the box, verifies it. Both keys are readable by root only, and the CA's key is kept outside the directory the proxy container mounts. The template and the build VM hold no certificate. A site may replace the certificate and its key with its own and retire the local CA; the exact names and the CA's limits are then not checked."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  apps = served_apps.select { |app| services.include?(app) }
  describe host(domain) do
    its('ipv4_address') { should eq ['127.0.0.1'] }
  end
  served_apps.each do |app|
    describe host("#{app}.#{domain}") do
      if apps.include?(app)
        its('ipv4_address') { should eq ['127.0.0.1'] }
      else
        it { should_not be_resolvable }
      end
    end
  end
  if deployed
    describe file('/etc/safbox/tls/safbox.key') do
      its('owner') { should eq 'root' }
      its('mode') { should cmp '0600' }
    end
    # The proxy container mounts /etc/safbox/tls; the CA's key stays out of it.
    describe file('/etc/safbox/tls/ca.key') do
      it { should_not exist }
    end
    describe x509_certificate('/etc/safbox/tls/safbox.crt') do
      its('validity_in_days') { should be > 0 }
    end
    # A site that installs its own certificate retires the local CA (its key
    # and certificate); the checks below are for the local CA and the
    # certificate it signed on first boot.
    if file('/etc/safbox/ca/ca.key').exist?
      describe file('/etc/safbox/ca') do
        its('mode') { should cmp '0700' }
      end
      describe file('/etc/safbox/ca/ca.key') do
        its('owner') { should eq 'root' }
        its('mode') { should cmp '0600' }
      end
      local_ca = x509_certificate('/etc/safbox/ca/ca.crt')
      describe local_ca do
        its('extensions.nameConstraints') do
          should eq ['critical', 'Permitted:', "DNS:#{domain}", "DNS:.#{domain}",
                     'Excluded:', 'IP:0.0.0.0/0.0.0.0', 'IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0']
        end
        its('extensions.extendedKeyUsage') { should eq ['TLS Web Server Authentication'] }
      end
      served = x509_certificate('/etc/safbox/tls/safbox.crt')
      if served.issuer_dn == local_ca.subject_dn
        describe served do
          its('subject_alt_names') { should match_array(([domain] + apps.map { |app| "#{app}.#{domain}" }).map { |name| "DNS:#{name}" }) }
        end
        # The local CA is in the extracted store every client reads, not
        # only among the anchors it is built from.
        describe command('openssl verify -purpose sslserver -CAfile /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/safbox/tls/safbox.crt') do
          its('exit_status') { should eq 0 }
        end
      end
    end
  else
    %w[/etc/safbox/tls/safbox.key /etc/safbox/ca].each do |path|
      describe file(path) do
        it { should_not exist }
      end
    end
  end
end

control 'safbox-proxy-4' do
  impact 1.0
  title 'The firewall opens HTTP and HTTPS and no other port'
  desc 'Apart from the services firewalld allows by name (ssh and the like), only http (80, which redirects) and https (443) are open, and the proxy listens on those two ports and no others.'
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe firewalld do
    it { should have_service_enabled_in_zone('http') }
    it { should have_service_enabled_in_zone('https') }
  end
  describe command('firewall-cmd --list-ports') do
    its('stdout.split') { should be_empty }
  end
  [8443, 9443].each do |number|
    describe port(number) do
      it { should_not be_listening }
    end
  end
  if deployed
    [80, 443].each do |number|
      describe port(number) do
        it { should be_listening }
      end
    end
  end
end

control 'safbox-proxy-5' do
  impact 1.0
  title "The proxy's TLS uses the OpenSSL FIPS provider under the FIPS crypto policy"
  desc 'nginx uses the OpenSSL in its image, which loads its FIPS provider on a FIPS host, and podman gives the container the host FIPS policy.'
  only_if('The proxy is switched off, or this is not a deployed clone', impact: 0.0) { services.include?('proxy') && deployed }

  describe command('podman exec safbox-proxy openssl list -providers') do
    its('stdout') { should match(/^\s+fips\n\s+name: .*FIPS Provider\n(\s+\w+: .*\n)*?\s+status: active$/) }
  end
  describe command('podman exec safbox-proxy cat /etc/crypto-policies/config') do
    its('stdout.strip') { should eq 'FIPS' }
  end
end

control 'safbox-proxy-7' do
  impact 1.0
  title "The proxy's certificate is renewed before it expires"
  desc "A daily timer, safbox-proxy-renew.timer, runs the first-boot play's clone_proxy_tls role with the renew tag: a certificate the local CA signed is signed again from the same CA, with a new key, once it is within 30 days of expiry, and the proxy restarted; a site's own certificate is left for the site to renew. The certificate the proxy serves is the one on disk, and it has more than 14 days left, as does the local CA that signed it."
  only_if('The proxy is switched off', impact: 0.0) { services.include?('proxy') }

  describe service('safbox-proxy-renew.timer') do
    it { should be_enabled }
    it { should be_running } if deployed
  end
  describe parse_config_file('/etc/systemd/system/safbox-proxy-renew.service', multiple_values: true) do
    its('Service.Type') { should eq ['oneshot'] }
    its('Service.ExecStart') { should eq ['/usr/bin/ansible-playbook -c local -i localhost, /usr/local/lib/safbox/firstboot/firstboot.yml --tags renew'] }
  end
  if deployed
    cert = '/etc/safbox/tls/safbox.crt'
    describe x509_certificate(cert) do
      its('validity_in_days') { should be > 14 }
    end
    # What the proxy serves now, not only what is on disk: a renewal that
    # did not restart the proxy shows here.
    fingerprint = 'openssl x509 -noout -fingerprint -sha256'
    served = command("openssl s_client -connect 127.0.0.1:443 -servername #{domain} </dev/null 2>/dev/null | #{fingerprint}").stdout.strip
    describe "The certificate the proxy serves (#{served})" do
      subject { served }
      it { should_not be_empty }
      it { should eq command("#{fingerprint} -in #{cert}").stdout.strip }
    end
    local_ca = '/etc/safbox/ca/ca.crt'
    if file(local_ca).exist? && x509_certificate(cert).issuer_dn == x509_certificate(local_ca).subject_dn
      describe x509_certificate(local_ca) do
        its('validity_in_days') { should be > 14 }
      end
    end
  end
end

control 'safbox-firefox-1' do
  impact 0.5
  title 'Firefox puts the box bookmarks on the toolbar, each with its logo, and opens the start page'
  desc "On a desktop build Firefox's system-wide enterprise policy shows the bookmarks toolbar, drops the distribution's default bookmarks, makes the start page the home page (users may change it) and the page a new profile and an update open (no page without the proxy), never Firefox's Welcome page, sends Mozilla no telemetry and shows no data-reporting notice (tab or bar), and puts the box's bookmarks on the toolbar: each application behind the proxy (Heimdall, Vulcan, Keycloak's account page), SAF, SAF Training and the start page. Each bookmark's icon is embedded as a data: URI, the only kind of icon Firefox's Bookmarks policy accepts: Heimdall's and Keycloak's own logos, taken from their upstream releases, and the SAF logo the desktop installs for the others (Vulcan has no logo of its own)."
  only_if('This is not a desktop build', impact: 0.0) { input('desktop') }

  policy_file = '/etc/firefox/policies/policies.json'
  # Each icon's sha256, that of the file the build installs: the SAF logo
  # (template_os role, files/desktop/saf-logo.svg) and Heimdall's and
  # Keycloak's (template_services role, files/firefox/), as their upstreams
  # publish them.
  saf_sha256 = 'cab58731383e39ded37dc908960fecc996760bd8a2e22033ed4605ba125afe0f'
  app_sha256 = {
    'heimdall' => 'a114629038f9f9fd97cb6291dd80e84ae7a272e2b679bb56ceb38b0c4eafc73f',
    'keycloak' => '0322bce1a9f2409cdee4a2921e287e112f277a6e7774b983f8fcd32fbae19285'
  }
  icon_prefix = 'data:image/svg+xml;base64,'
  proxy = services.include?('proxy')
  app_paths = { 'heimdall' => '/', 'vulcan' => '/', 'keycloak' => '/realms/safbox/account/' }
  # Each bookmark: title, URL, placement, and its icon's sha256.
  expected = []
  if proxy
    served_apps.select { |app| services.include?(app) }.each do |app|
      expected << [app.capitalize, "https://#{app}.#{domain}#{app_paths[app]}", 'toolbar', app_sha256.fetch(app, saf_sha256)]
    end
  end
  expected << ['SAF', 'https://saf.mitre.org', 'toolbar', saf_sha256]
  expected << ['SAF Training', 'https://mitre.github.io/saf-training/', 'toolbar', saf_sha256]
  expected << ['SAFBox - Start Here', "https://#{domain}/", 'toolbar', saf_sha256] if proxy

  describe file(policy_file) do
    it { should be_file }
    its('owner') { should eq 'root' }
    its('group') { should eq 'root' }
    its('mode') { should cmp '0644' }
  end
  describe json(policy_file) do
    its(%w[policies DisplayBookmarksToolbar]) { should eq 'always' }
    its(%w[policies NoDefaultBookmarks]) { should eq true }
  end
  if proxy
    describe json(policy_file) do
      its(%w[policies Homepage URL]) { should eq "https://#{domain}/" }
      its(%w[policies Homepage StartPage]) { should eq 'homepage' }
      its(%w[policies Homepage Locked]) { should eq false }
    end
  end
  # Never Firefox's Welcome page: the start page with the proxy, else no
  # page ("" is Firefox's value for none).
  first_page = proxy ? "https://#{domain}/" : ''
  describe json(policy_file) do
    its(%w[policies OverrideFirstRunPage]) { should eq first_page }
    its(%w[policies OverridePostUpdatePage]) { should eq first_page }
  end
  # Firefox sends Mozilla no telemetry (the Firefox STIG's FFOX-00-000014
  # asks for DisableTelemetry true), so it gives no data-reporting notice: no
  # privacy-notice tab on a new profile, no notice bar. The empty first-run
  # address and the notification bypass keep the notice away on their own
  # too; both are locked, so a profile cannot bring it back.
  describe json(policy_file) do
    its(%w[policies DisableTelemetry]) { should eq true }
    its(['policies', 'Preferences', 'datareporting.policy.firstRunURL', 'Value']) { should eq '' }
    its(['policies', 'Preferences', 'datareporting.policy.firstRunURL', 'Status']) { should eq 'locked' }
    its(['policies', 'Preferences', 'datareporting.policy.dataSubmissionPolicyBypassNotification', 'Value']) { should eq true }
    its(['policies', 'Preferences', 'datareporting.policy.dataSubmissionPolicyBypassNotification', 'Status']) { should eq 'locked' }
  end

  bookmarks = Array(json(policy_file).params.dig('policies', 'Bookmarks'))
  describe 'Firefox policy bookmarks (title, URL, placement)' do
    subject { bookmarks.map { |b| b.values_at('Title', 'URL', 'Placement') } }
    it { should eq(expected.map { |b| b.first(3) }) }
  end
  bookmarks.each do |bookmark|
    icon = bookmark['Favicon'].to_s
    pin = expected.find { |b| b.first == bookmark['Title'] }&.last
    describe "Firefox policy bookmark #{bookmark['Title']}: its icon" do
      subject { icon }
      it { should start_with icon_prefix }
    end
    describe "Firefox policy bookmark #{bookmark['Title']}: its icon's sha256" do
      subject { Digest::SHA256.hexdigest(icon.delete_prefix(icon_prefix).unpack1('m')) }
      it { should eq pin }
    end
  end
end
