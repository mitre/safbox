# frozen_string_literal: true

# Vulcan through the proxy, from this machine, as a browser signs in: each
# form post carries the CSRF token Rails put in the page fetched in the
# same session.

services = input('expected_services')
domain = input('domain')
client = safbox_client(input('address'), domain, input('work_dir'))
vulcan = client.url('vulcan')
on = services.include?('vulcan') && services.include?('proxy')
admin = "admin@#{domain}"

control 'safbox-client-vulcan-1' do
  impact 1.0
  title "Vulcan's sign-in page loads here with its scripts and stylesheets"
  desc "Vulcan's sign-in page answers 200 at its name, and so does every script and stylesheet it references on its own origin, so the page can run in a browser here."
  only_if('Vulcan or the proxy is switched off', impact: 0.0) { on }
  next unless on

  client.new_session('vulcan-page')
  page = client.request("-w '%{stderr}%{http_code}' #{vulcan}/users/sign_in")
  assets = client.same_origin_assets(page.stdout)
  describe "GET #{vulcan}/users/sign_in" do
    subject { page }
    its('stderr') { should eq '200' }
  end
  describe "The scripts and stylesheets of #{vulcan}/users/sign_in" do
    subject { assets }
    it { should_not be_empty }
  end
  assets.each do |asset|
    describe "GET #{vulcan}#{asset}" do
      subject { command(client.curl("-o /dev/null -w '%{http_code}' #{client.quote(vulcan + asset)}")) }
      its('stdout') { should eq '200' }
    end
  end
end

control 'safbox-client-vulcan-2' do
  impact 0.0
  title 'Vulcan refuses a sign-up with registration off'
  desc 'A sign-up posted as a browser would (the CSRF token of a page fetched in the same session) must not make an account or a session: registration is off (VULCAN_ENABLE_USER_REGISTRATION=false, safbox-vulcan-1). Vulcan serves its sign-in page at /users/sign_up, so that page alone proves nothing; the session after the post shows whether an account was made.'
  desc 'justification', <<~JUSTIFICATION
    A known upstream defect, accepted and not worked around: Vulcan 2.4.1
    only hides the sign-up link when registration is off. Its registration
    handler checks only that local login is on, which it must be for the
    administrator, so the post makes a regular local account (not an
    administrator) and signs it in. The check still runs and its result is
    kept in the report; once an image's Vulcan refuses the sign-up, raise
    this control's impact to 1.0.
  JUSTIFICATION
  only_if('Vulcan or the proxy is switched off', impact: 0.0) { on }
  next unless on

  client.new_session('vulcan-signup')
  sign_up = client.request("-w '%{stderr}%{http_code}' #{vulcan}/users/sign_up")
  token = client.csrf_token(sign_up.stdout)
  email = client.random_email
  password = client.secret_file('vulcan-signup-password', client.random_password)
  client.request("-o /dev/null --data-urlencode authenticity_token=#{client.quote(token)} " \
                 "--data-urlencode 'user[name]=SAFBox Test' --data-urlencode #{client.quote("user[email]=#{email}")} " \
                 "--data-urlencode #{client.quote("user[password]@#{password}")} " \
                 "--data-urlencode #{client.quote("user[password_confirmation]@#{password}")} #{vulcan}/users")
  me = client.request("-H 'Accept: application/json' #{vulcan}/users/edit.json")

  describe "GET #{vulcan}/users/sign_up" do
    subject { sign_up }
    its('stderr') { should eq '200' }
  end
  describe "The session after #{email} signs up" do
    subject { json(content: me.stdout).params['email'] }
    it { should_not eq email }
  end
end

control 'safbox-client-vulcan-3' do
  impact 1.0
  title "Vulcan's administrator signs in through the sign-in form and creates a project"
  desc "admin@<domain>, Vulcan's only local account, signs in through the sign-in form with the password first boot generated and is redirected to the root; the session is the administrator's, which may list the users, and creates a discoverable project that is then listed. Creates a project on the box."
  only_if('Vulcan or the proxy is switched off', impact: 0.0) { on }
  next unless on

  client.new_session('vulcan-admin')
  token = client.csrf_token(client.request("#{vulcan}/users/sign_in").stdout)
  password = client.secret_file('vulcan-admin-password', input('vulcan_admin_password'))
  sign_in = client.request("-o /dev/null -w '%{http_code} %{redirect_url}' --data-urlencode authenticity_token=#{client.quote(token)} " \
                                "--data-urlencode #{client.quote("user[email]=#{admin}")} --data-urlencode #{client.quote("user[password]@#{password}")} " \
                                "#{vulcan}/users/sign_in")
  me = client.request("-H 'Accept: application/json' #{vulcan}/users/edit.json")
  users = client.request("-o /dev/null -w '%{http_code}' -H 'Accept: application/json' #{vulcan}/users.json")
  token = client.csrf_token(client.request("#{vulcan}/projects").stdout)
  name = "SAFBox test #{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
  project = client.secret_file('vulcan-project.json', JSON.generate(project: { name: name, description: 'Created by the safbox-client profile', visibility: 'discoverable' }))
  create = client.request("-w '%{stderr}%{http_code}' -H 'Accept: application/json' -H 'Content-Type: application/json' " \
                               "-H #{client.quote("X-CSRF-Token: #{token}")} --data-binary @#{project} #{vulcan}/projects")
  listed = json(content: client.request("-H 'Accept: application/json' #{vulcan}/projects.json").stdout).params

  describe "Sign in to #{vulcan} as #{admin}" do
    subject { sign_in }
    # Devise redirects to the root after a successful sign-in.
    its('stdout') { should eq "302 #{vulcan}/" }
  end
  describe "The session's user, #{vulcan}/users/edit.json" do
    subject { json(content: me.stdout) }
    its('email') { should eq admin }
    its('admin') { should eq true }
  end
  describe "The administrators' user list, #{vulcan}/users.json" do
    subject { users }
    its('stdout') { should eq '200' }
  end
  describe "Create project '#{name}'" do
    subject { create }
    its('stderr') { should eq '200' }
  end
  describe json(content: create.stdout) do
    its('redirect_url') { should match(%r{\A/projects/\d+\z}) }
  end
  describe "Projects named '#{name}' in #{vulcan}/projects.json" do
    subject { listed.to_a.count { |p| p['name'] == name } }
    it { should eq 1 }
  end
end
