# frozen_string_literal: true

require 'base64'
require 'openssl'

# Keycloak single sign-on through the proxy, from this machine, as a
# browser would, following each redirect: safuser changes its one-time
# password at its first sign-in, signs in to Heimdall, to Vulcan and to
# Keycloak's account console, and changes its password there; then the
# generated password and a wrong one are refused. The controls run in this
# order and hand safuser's password on in a file: the one this profile
# last gave it.

services = input('expected_services')
domain = input('domain')
work = input('work_dir')
client = safbox_client(input('address'), domain, work)
keycloak = client.url('keycloak')
heimdall = client.url('heimdall')
vulcan = client.url('vulcan')
account = "#{keycloak}/realms/safbox/account/"
oidc = "#{keycloak}/realms/safbox/protocol/openid-connect"
safuser = "safuser@#{domain}"
on = services.include?('keycloak') && services.include?('proxy')
sso = on && services.include?('heimdall') && services.include?('vulcan')
# safuser's password: first boot's one-time password, then the one this
# profile gives it, kept in password_file (0600; a new one is written to
# <file>.new first, so a run stopped mid-change leaves it there).
generated = client.secret_file('safuser-generated', input('keycloak_safuser_password'))
password_file = input('keycloak_safuser_password_file')
password_file = File.join(work, 'safuser-password') if password_file.empty?
first_run = !File.exist?(password_file)

# The sign-in form's action in a page, and posting safuser's password in
# SECRET to it with the redirects followed: the page and URL it ends at.
sign_in = lambda do |page, secret|
  action = client.form_action(page, 'kc-form-login')
  ended = client.request("-L -w '%{stderr}%{url_effective}' --data-urlencode username=safuser " \
                         "--data-urlencode password@#{secret} --data-urlencode credentialId= #{client.quote(action)}")
  { action: action, page: ended.stdout, url: ended.stderr }
end
# Keycloak's update-password form in PAGE gets the password in SECRET,
# twice; the redirects are followed.
new_password = lambda do |page, secret|
  action = client.form_action(page, 'kc-passwd-update-form')
  ended = client.request("-L -w '%{stderr}%{url_effective}' --data-urlencode password-new@#{secret} " \
                         "--data-urlencode password-confirm@#{secret} #{client.quote(action)}")
  { action: action, page: ended.stdout, url: ended.stderr }
end
# Heimdall's user for the session: its OIDC callback leaves userID and
# accessToken cookies.
heimdall_user = lambda do |name|
  auth = client.secret_file("#{name}-auth", "Authorization: Bearer #{client.cookie('accessToken')}\n")
  json(content: client.request("-H @#{auth} #{heimdall}/users/#{client.cookie('userID').to_i}").stdout)
end
# The account console's sign-in, as its page does it: the authorization
# code flow with PKCE (S256) back to the account page, with any extra
# parameters. Returns the page it ends at and the code verifier.
account_auth = lambda do |extra = {}|
  verifier = SecureRandom.hex(32)
  params = {
    client_id: 'account-console', redirect_uri: account, response_type: 'code', scope: 'openid',
    state: SecureRandom.hex(8), code_challenge_method: 'S256',
    code_challenge: Base64.urlsafe_encode64(OpenSSL::Digest.digest('SHA256', verifier), padding: false)
  }.merge(extra)
  args = params.map { |key, value| "--data-urlencode #{client.quote("#{key}=#{value}")}" }.join(' ')
  [client.request("-L -G #{args} #{oidc}/auth").stdout, verifier]
end
# Signs in to the account console in session NAME with the password in
# SECRET: the URL Keycloak sends the browser back to, the access token's
# claims, and the token, written to a header file for the Account API.
account_sign_in = lambda do |name, secret|
  client.new_session(name)
  page, verifier = account_auth.call
  back = client.request("-o /dev/null -w '%{redirect_url}' --data-urlencode username=safuser --data-urlencode password@#{secret} " \
                        "--data-urlencode credentialId= #{client.quote(client.form_action(page, 'kc-form-login'))}").stdout
  code = back[/[?&]code=([^&]+)/, 1].to_s
  token = json(content: client.request("--data-urlencode grant_type=authorization_code --data-urlencode client_id=account-console " \
                                       "--data-urlencode #{client.quote("code=#{code}")} --data-urlencode #{client.quote("redirect_uri=#{account}")} " \
                                       "--data-urlencode code_verifier=#{verifier} #{oidc}/token").stdout).params['access_token'].to_s
  claims = token.split('.')[1].to_s
  claims = claims.empty? ? {} : JSON.parse(Base64.urlsafe_decode64(claims))
  [back, claims, client.secret_file("#{name}-auth", "Authorization: Bearer #{token}\n")]
end

control 'safbox-client-keycloak-1' do
  impact 1.0
  title 'Keycloak names its issuer, sends its bare name to the account page, and refuses its administration paths to this machine'
  desc "Keycloak's discovery document, fetched from here, names the safbox realm at Keycloak's name as its issuer. Keycloak's own homepage leads to the master realm, where no safbox user exists, so the bare name is a temporary redirect to the safbox account page. The administration console (/admin/) and the master realm answer 403 to any client but the box (safbox-keycloak-5 checks the proxy's rule, and the master realm answering on the box)."
  only_if('Keycloak or the proxy is switched off', impact: 0.0) { on }
  next unless on

  client.new_session('keycloak-paths')
  discovery = client.request("-w '%{stderr}%{http_code}' #{keycloak}/realms/safbox/.well-known/openid-configuration")
  describe "#{keycloak}/realms/safbox/.well-known/openid-configuration" do
    subject { discovery }
    its('stderr') { should eq '200' }
  end
  describe json(content: discovery.stdout) do
    its('issuer') { should eq "#{keycloak}/realms/safbox" }
  end
  describe "GET #{keycloak}/ from here" do
    subject { client.request("-o /dev/null -w '%{http_code} %{redirect_url}' #{keycloak}/") }
    its('stdout') { should eq "302 #{account}" }
  end
  %w[/admin/ /realms/master/.well-known/openid-configuration].each do |path|
    describe "GET #{keycloak}#{path} from here" do
      subject { client.request("-o /dev/null -w '%{http_code}' #{keycloak}#{path}") }
      its('stdout') { should eq '403' }
    end
  end
end

control 'safbox-client-keycloak-2' do
  impact 1.0
  title "safuser's generated Keycloak password is one-time: its first sign-in asks for a new one, under the realm's policy"
  desc "On a fresh box, safuser's first sign-in (to Heimdall, through Keycloak) with the password first boot generated lands on Keycloak's update-password form instead of the application. A new password of 14 characters, or the user name, is refused there by the realm's policy; a valid one completes the sign-in to Heimdall as safuser, a regular user. With keycloak_safuser_password_file left from an earlier run, that change is done: the password in it signs in without being asked again. Changes safuser's password on the box."
  only_if('Keycloak, Heimdall, Vulcan or the proxy is switched off', impact: 0.0) { sso }
  next unless sso

  client.new_session('keycloak-first')
  form = client.request("-L #{heimdall}/authn/oidc").stdout
  if first_run
    first = sign_in.call(form, generated)
    # Each post answers with the form again, whose action the next one uses.
    page = first[:page]
    refusals = { 'of 14 characters' => client.random_password[0, 14], 'that is the user name' => 'safuser' }.map do |what, bad|
      result = new_password.call(page, client.secret_file("safuser-bad-#{bad.length}", bad))
      page = result[:page]
      [what, result]
    end
    File.write("#{password_file}.new", client.random_password, perm: 0o600)
    changed = new_password.call(page, "#{password_file}.new")
    me = heimdall_user.call('keycloak-first')
    # Kept only once Keycloak asked for it and took it.
    asked = first[:page].include?('id="kc-passwd-update-form"')
    File.rename("#{password_file}.new", password_file) if asked && changed[:url].start_with?("#{heimdall}/")

    describe 'The first sign-in with the generated password' do
      subject { first[:url] }
      it { should start_with "#{keycloak}/realms/safbox/login-actions/required-action?execution=UPDATE_PASSWORD" }
    end
    describe "The page the first sign-in shows" do
      subject { first[:page] }
      it { should include 'id="kc-passwd-update-form"' }
    end
    refusals.each do |what, result|
      describe "Keycloak's answer to a new password #{what}" do
        subject { result[:page] }
        it { should include 'id="kc-passwd-update-form"' }
        it { should include 'Invalid password' }
      end
    end
    describe 'Where a valid new password leaves the browser' do
      subject { changed[:url] }
      it { should start_with "#{heimdall}/" }
    end
  else
    again = sign_in.call(form, password_file)
    me = heimdall_user.call('keycloak-first')
    describe "The sign-in with the password in #{password_file}" do
      subject { again[:page] }
      it { should_not include 'id="kc-passwd-update-form"' }
    end
  end
  describe "Heimdall's user after the sign-in through Keycloak" do
    subject { me }
    its('email') { should eq safuser }
    its('role') { should eq 'user' }
  end
end

control 'safbox-client-keycloak-3' do
  impact 1.0
  title 'safuser signs in to Vulcan through Keycloak as a regular user'
  desc "Vulcan's OIDC sign-in, posted with the CSRF token of its sign-in page in a fresh session, leads to Keycloak's sign-in form; safuser's password posted there, and the redirects followed, bring the browser back to Vulcan, whose session is safuser@<domain>'s, not an administrator's. Makes safuser's Vulcan account on the first run."
  only_if('Keycloak, Heimdall, Vulcan or the proxy is switched off', impact: 0.0) { sso }
  next unless sso

  client.new_session('keycloak-vulcan')
  token = client.csrf_token(client.request("#{vulcan}/users/sign_in").stdout)
  form = client.request("-L --data-urlencode authenticity_token=#{client.quote(token)} #{vulcan}/users/auth/oidc").stdout
  signed_in = sign_in.call(form, File.exist?(password_file) ? password_file : generated)
  me = json(content: client.request("-H 'Accept: application/json' #{vulcan}/users/edit.json").stdout)

  describe "Vulcan's sign-in form" do
    subject { signed_in[:action] }
    it { should start_with "#{keycloak}/realms/safbox/login-actions/authenticate?" }
  end
  describe "Vulcan's user after the sign-in through Keycloak, #{vulcan}/users/edit.json" do
    subject { me }
    its('email') { should eq safuser }
    its('admin') { should eq false }
  end
end

control 'safbox-client-keycloak-4' do
  impact 1.0
  title "safuser signs in to Keycloak's account console and changes its password there"
  desc "The account console's sign-in (the authorization code flow with PKCE, as its page does it) gives safuser a token for the Account API (audience account), which answers the two calls the page makes first with safuser's profile. The console's password Update (kc_action=UPDATE_PASSWORD) shows Keycloak's update-password form; a new password there returns the browser to the account page with kc_action_status=success, and then signs in. Changes safuser's password on the box."
  only_if('Keycloak, Heimdall, Vulcan or the proxy is switched off', impact: 0.0) { sso }
  next unless sso

  current = File.exist?(password_file) ? password_file : generated
  back, claims, auth = account_sign_in.call('keycloak-account', current)
  locales = client.request("-o /dev/null -w '%{http_code}' -H @#{auth} -H 'Accept: application/json' #{account}supportedLocales")
  profile = client.request("-w '%{stderr}%{http_code}' -H @#{auth} -H 'Accept: application/json' '#{account}?userProfileMetadata=true'")
  page, = account_auth.call(kc_action: 'UPDATE_PASSWORD')
  File.write("#{password_file}.new", client.random_password, perm: 0o600)
  updated = client.request("-o /dev/null -w '%{redirect_url}' --data-urlencode password-new@#{password_file}.new " \
                           "--data-urlencode password-confirm@#{password_file}.new #{client.quote(client.form_action(page, 'kc-passwd-update-form'))}").stdout
  success = updated.start_with?("#{account}?") && updated.include?('kc_action_status=success')
  File.rename("#{password_file}.new", password_file) if success
  back_new, = account_sign_in.call('keycloak-account-new', password_file)

  describe 'Where the account console sign-in sends the browser back' do
    subject { back }
    it { should match(/\A#{Regexp.escape(account)}\?.*\bcode=/) }
  end
  describe "The account console's access token" do
    subject { claims }
    its(['preferred_username']) { should eq 'safuser' }
    its(['aud']) { should include 'account' }
  end
  describe "GET #{account}supportedLocales with that token" do
    subject { locales }
    its('stdout') { should eq '200' }
  end
  describe "GET #{account}?userProfileMetadata=true with that token" do
    subject { profile }
    its('stderr') { should eq '200' }
  end
  describe json(content: profile.stdout) do
    its('username') { should eq 'safuser' }
  end
  describe "The account console's password Update" do
    subject { page }
    it { should include 'id="kc-passwd-update-form"' }
  end
  describe 'Where the new password sends the browser' do
    subject { updated }
    it { should match(/\A#{Regexp.escape(account)}\?.*\bkc_action_status=success\b/) }
  end
  describe 'Where the account console sign-in with the new password sends the browser back' do
    subject { back_new }
    it { should match(/\A#{Regexp.escape(account)}\?.*\bcode=/) }
  end
end

control 'safbox-client-keycloak-5' do
  impact 1.0
  title "The generated password, once changed, and a wrong one are refused, and safuser's own password still signs in"
  desc "Each refused password leaves the browser on Keycloak's sign-in form, with no Heimdall session. The refusal of the generated password counts only once it has been changed, so the file of the password given in its place must exist; and safuser's current password, from that file, must still reach Heimdall afterwards, so neither refusal comes from a locked or broken account. Keycloak's brute-force protection locks an account for a minute after quick failures (two within a second count as an attack), so each sign-in runs once, 2 s apart, after every other sign-in."
  only_if('Keycloak, Heimdall, Vulcan or the proxy is switched off', impact: 0.0) { sso }
  next unless sso

  results = { 'The generated password, once changed,' => generated, 'A wrong password' => client.secret_file('safuser-wrong', client.random_password) }
  results = results.each_with_index.to_h do |(what, secret), i|
    sleep 2 if i.positive?
    client.new_session("keycloak-refused-#{i}")
    ended = sign_in.call(client.request("-L #{heimdall}/authn/oidc").stdout, secret)
    [what, ended.merge(token: client.cookie('accessToken'))]
  end
  sleep 2
  client.new_session('keycloak-current')
  current = sign_in.call(client.request("-L #{heimdall}/authn/oidc").stdout, password_file)
  me = heimdall_user.call('keycloak-current')

  describe "The file of the password safuser was given in place of the generated one (#{password_file})" do
    subject { File.exist?(password_file) }
    it { should eq true }
  end

  results.each do |what, ended|
    describe "Where #{what.downcase} leaves the browser" do
      subject { ended[:url] }
      it { should start_with "#{keycloak}/" }
    end
    describe "The page #{what.downcase} leaves the browser on" do
      subject { ended[:page] }
      it { should include 'id="kc-form-login"' }
      it { should_not include 'id="kc-passwd-update-form"' }
    end
    describe "The Heimdall session after #{what.downcase}" do
      subject { ended[:token] }
      it { should be_nil }
    end
  end
  describe "Where safuser's current password leaves the browser" do
    subject { current[:url] }
    it { should start_with "#{heimdall}/" }
  end
  describe "Heimdall's user after the sign-in with safuser's current password" do
    subject { me }
    its('email') { should eq safuser }
  end
end
