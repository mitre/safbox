# frozen_string_literal: true

require 'base64'
require 'digest'

# Site CA bundles in the system trust store (the site_config role, task
# group safbox-site-config-1). The role writes one anchor file per
# certificate, named safbox-<bundle>-<id>.pem, into the distribution's
# anchors directory and regenerates the extracted bundle that OpenSSL,
# curl and the containers read. A repository-default image trusts the DoD
# PKI bundle, so by default the control asserts that the DoD roots are in
# the store and every SAFBox anchor file is a DoD one. A site that builds or
# deploys with other bundles, or with the DoD bundle removed, names them in
# trust_bundles_expected (possibly empty): each expected bundle's roots must
# be present and every other known bundle's roots absent.

anchors_dir = '/etc/pki/ca-trust/source/anchors'
extracted_bundle = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
expected = input('trust_bundles_expected').map(&:to_s)
# InSpec gives the nested keys of a Hash input from inspec.yml as symbols (an
# inputs file may give strings), so normalise them. Fingerprints are compared
# as lowercase hex without separators, so either openssl's colon form or
# plain hex may be given.
known = input('trust_bundle_anchors').to_h do |bundle, roots|
  [bundle.to_s, roots.to_h { |label, fp| [label.to_s, fp.to_s.delete(':').downcase] }]
end
anchor_file = /\Asafbox-(?<bundle>[a-z0-9]+(?:-[a-z0-9]+)*)-[0-9a-f]{16}\.pem\z/

control 'safbox-trust-1' do
  impact 1.0
  title 'The system trust store holds exactly the site CA bundles the image was built or deployed with'
  desc 'The site_config role installs each configured CA bundle (the DoD PKI bundle fetched live from DISA and checksum-verified, on by default, or a site\'s own) into the system trust store. Every expected bundle\'s identifying roots must be in the extracted bundle OpenSSL and curl read, and every known bundle that is not expected must be absent from it, so an image built with the DoD bundle removed trusts no DoD root. Each SAFBox anchor file belongs to an expected bundle and is root-owned with mode 0644.'

  describe 'Bundles expected but without identifying roots in trust_bundle_anchors' do
    subject { expected - known.keys }
    it { should be_empty }
  end

  # SHA-256 fingerprint of each certificate in the extracted bundle, computed
  # here from the PEM blocks so the box runs nothing.
  pem_blocks = file(extracted_bundle).content.to_s.scan(/-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----/m)
  trusted = pem_blocks.map { |(body)| Digest::SHA256.hexdigest(Base64.decode64(body)) }

  describe file(extracted_bundle) do
    it { should exist }
  end

  known.each do |bundle, roots|
    roots.each do |label, fingerprint|
      describe "#{label} (#{bundle} bundle, SHA-256 #{fingerprint}) in #{extracted_bundle}" do
        subject { trusted }
        if expected.include?(bundle)
          it { should include fingerprint }
        else
          it { should_not include fingerprint }
        end
      end
    end
  end

  files = command("find #{anchors_dir} -maxdepth 1 -name 'safbox-*' -printf '%f\\n'").stdout.split("\n")

  describe "SAFBox anchor files in #{anchors_dir} not named safbox-<bundle>-<id>.pem" do
    subject { files.grep_v(anchor_file) }
    it { should be_empty }
  end

  describe "Bundles with anchor files in #{anchors_dir}" do
    subject { files.filter_map { |name| name[anchor_file, :bundle] }.uniq.sort }
    it { should eq expected.uniq.sort }
  end

  files.each do |name|
    describe file("#{anchors_dir}/#{name}") do
      it { should be_file }
      its('owner') { should eq 'root' }
      its('group') { should eq 'root' }
      its('mode') { should cmp '0644' }
    end
  end
end
