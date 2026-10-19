# frozen_string_literal: true

# Heimdall through the proxy, from this machine. Its registration and
# local-login flags are checked on the box (safbox-heimdall-6).

services = input('expected_services')
domain = input('domain')
client = safbox_client(input('address'), domain, input('work_dir'))
heimdall = client.url('heimdall')
on = services.include?('heimdall') && services.include?('proxy')

control 'safbox-client-heimdall-1' do
  impact 1.0
  title "Heimdall's page loads here with its scripts and stylesheets"
  desc "Heimdall's page answers 200 at its name, and so does every script and stylesheet it references on its own origin, so the page can run in a browser here."
  only_if('Heimdall or the proxy is switched off', impact: 0.0) { on }
  next unless on

  client.new_session('heimdall-page')
  page = client.request("-w '%{stderr}%{http_code}' #{heimdall}/")
  assets = client.same_origin_assets(page.stdout)
  describe "GET #{heimdall}/" do
    subject { page }
    its('stderr') { should eq '200' }
  end
  describe "The scripts and stylesheets of #{heimdall}/" do
    subject { assets }
    it { should_not be_empty }
  end
  assets.each do |asset|
    describe "GET #{heimdall}#{asset}" do
      subject { command(client.curl("-o /dev/null -w '%{http_code}' #{client.quote(heimdall + asset)}")) }
      its('stdout') { should eq '200' }
    end
  end
end

control 'safbox-client-heimdall-2' do
  impact 1.0
  title "Heimdall's administrator logs in, uploads an HDF file and reads the evaluation back"
  desc "admin@<domain>, Heimdall's only local account, logs in through the API with the password first boot generated (its first session lasts ten minutes and the UI asks for a new password; the API serves it meanwhile), uploads an HDF results file, and reads the evaluation back with the same profiles. Creates an evaluation on the box."
  only_if('Heimdall or the proxy is switched off', impact: 0.0) { on }
  next unless on

  hdf = input('hdf_file')
  readable = !hdf.empty? && File.file?(hdf) && File.readable?(hdf)
  describe "The HDF file to upload (hdf_file: #{hdf})" do
    subject { readable }
    it { should eq true }
  end
  next unless readable

  client.new_session('heimdall-admin')
  login = client.secret_file('heimdall-login.json', JSON.generate(email: "admin@#{domain}", password: input('heimdall_admin_password')))
  response = client.request("-H 'Content-Type: application/json' --data-binary @#{login} -w '%{stderr}%{http_code}' #{heimdall}/authn/login")
  token = json(content: response.stdout).params['accessToken'].to_s
  auth = client.secret_file('heimdall-auth', "Authorization: Bearer #{token}\n")
  filename = "safbox-test-#{File.basename(hdf)}"
  upload = client.request("-H @#{auth} -F #{client.quote("data=@#{hdf}")} -F #{client.quote("filename=#{filename}")} -F public=false -w '%{stderr}%{http_code}' #{heimdall}/evaluations")
  id = json(content: upload.stdout).params['id']
  profiles = json(hdf).params['profiles'].to_a.map { |profile| profile['name'] }
  evaluation = json(content: client.request("-H @#{auth} #{heimdall}/evaluations/#{id.to_i}").stdout)

  describe "Log in to #{heimdall} as admin@#{domain}" do
    subject { response }
    its('stderr') { should eq '201' }
  end
  describe "The log-in's response" do
    subject { token }
    it { should_not be_empty }
  end
  describe "Upload of #{File.basename(hdf)}" do
    subject { upload }
    its('stderr') { should eq '201' }
  end
  describe "Evaluation #{id} read back" do
    subject { evaluation }
    its('filename') { should eq filename }
  end
  describe "The profiles of evaluation #{id}" do
    subject { evaluation.params.dig('data', 'profiles').to_a.map { |profile| profile['name'] } }
    it { should_not be_empty }
    it { should eq profiles }
  end
end
