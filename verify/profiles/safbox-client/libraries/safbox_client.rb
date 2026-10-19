# frozen_string_literal: true

require 'securerandom'
require 'shellwords'

# A browser on this machine, made of curl and OpenSSL 3: it reaches the box
# only through its TLS proxy on port 443 and sends each name the proxy
# serves to the box's address itself, as a DNS or hosts entry on a client
# would. It trusts only the certificate the box serves (trust on first use:
# the box's own local CA signs it, and this machine does not trust that CA),
# so every request also proves the certificate names the name asked for.
#
# Each request runs curl in a command resource when the control body
# reaches it, so a flow's steps run in order and each can use what the
# one before left. CINC Auditor caches a command's result by its command
# line for the whole run, so a flow names its session (its own cookie
# jar), which makes its command lines its own; a step repeated within one
# session must differ in some argument.
#
# A password never goes on a command line: it is written to a file in the
# work directory, readable by this user only, and curl reads it from there
# (--data-urlencode name@file, --data-binary @file, -H @file).
class SafboxClient < Inspec.resource(1)
  name 'safbox_client'
  desc 'curl and openssl on this machine as a browser of a SAFBox'
  example <<~EXAMPLE
    client = safbox_client(input('address'), input('domain'), input('work_dir'))
    client.new_session('heimdall-page')
    page = client.request("-w '%{stderr}%{http_code}' \#{client.url('heimdall')}/")
    describe page do
      its('stderr') { should eq '200' }
    end
  EXAMPLE

  # The names the proxy serves besides the domain, one per application.
  APPS = %w[heimdall vulcan keycloak].freeze
  # Four character classes for random_password.
  CLASSES = ['ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#%^*-_=+'].freeze

  attr_reader :address, :domain, :work

  def initialize(address, domain, work)
    @address = address
    @domain = domain
    @work = work
  end

  # The names the proxy serves besides the domain, one per application.
  def apps
    APPS
  end

  def url(app)
    "https://#{app}.#{domain}"
  end

  # The path of FILE in the work directory.
  def path(file)
    File.join(work, file)
  end

  # openssl s_client to the proxy for NAME, with ARGS; what it prints on
  # both streams is on stdout.
  def s_client(name, args = '')
    "openssl s_client -connect #{address}:443 -servername #{name} #{args} </dev/null 2>&1"
  end

  # The curl command line for ARGS, in the current session (its cookie
  # jar). With -w '%{stderr}...' the write-out goes to stderr, apart from
  # the body on stdout.
  def curl(args)
    trust_box
    resolve = APPS.map { |app| "--resolve #{app}.#{domain}:443:#{address}" }.join(' ')
    "curl -sS --cacert #{path('cert.pem')} -b #{jar} -c #{jar} #{resolve} #{args}"
  end

  # Runs curl with ARGS now, in the current session, and returns the
  # command resource.
  def request(args)
    result = inspec.command(curl(args))
    result.stdout
    result
  end

  # Starts session NAME, with no cookies.
  def new_session(name)
    @session = name
    File.delete(jar) if File.exist?(jar)
  end

  # The current session's cookie jar.
  def jar
    path("jar-#{@session || 'none'}")
  end

  # The value of cookie NAME in the current session, or nil. The jar is in
  # Netscape format: tab-separated fields, the name sixth and the value
  # seventh.
  def cookie(name)
    (File.exist?(jar) ? File.read(jar) : '').lines.map { |line| line.chomp.split("\t") }.find { |fields| fields[5] == name }&.at(6)
  end

  # Writes CONTENT to FILE in the work directory, readable by this user
  # only, and returns its path.
  def secret_file(file, content)
    File.delete(path(file)) if File.exist?(path(file))
    File.write(path(file), content, perm: 0o600)
    path(file)
  end

  # The CSRF token Rails puts in every page's <meta name="csrf-token">.
  def csrf_token(html)
    html[/<meta name="csrf-token" content="([^"]+)"/, 1].to_s
  end

  # The action URL of the form with ID in the HTML page, or ''.
  def form_action(html, id)
    html.tr("\n", ' ')[/<form[^>]*id="#{Regexp.escape(id)}"[^>]*>/].to_s[/action="([^"]*)"/, 1].to_s.gsub('&amp;', '&')
  end

  # The scripts and stylesheets an HTML page references on its own origin,
  # as absolute paths.
  def same_origin_assets(html)
    html.scan(/<(?:script|link)[^>]+(?:src|href)="([^"]+\.(?:js|css)[^"]*)"/).flatten.uniq
        .reject { |asset| asset.start_with?('http://', 'https://', '//') }
        .map { |asset| asset.start_with?('/') ? asset : "/#{asset}" }
  end

  # A random 24-character password meeting the applications' default
  # complexity rules: at least 15 characters, two each of upper case, lower
  # case, digits and symbols (Vulcan), never four characters of one class
  # in a row (Heimdall), and Keycloak's (15 characters, not the username).
  def random_password
    Array.new(24) { |i| CLASSES[i % 4][SecureRandom.random_number(CLASSES[i % 4].length)] }.join
  end

  def random_email
    "safbox-test-#{SecureRandom.hex(4)}@example.invalid"
  end

  # Shell-quotes VALUE for a command line.
  def quote(value)
    Shellwords.escape(value.to_s)
  end

  def to_s
    "SAFBox client of #{address} (#{domain})"
  end

  private

  # Saves the certificate the proxy serves to cert.pem once per work
  # directory. The first boot's certificate names every name, so the one
  # served for the first application's name verifies them all.
  def trust_box
    return if File.size?(path('cert.pem'))

    inspec.command("#{s_client("#{APPS.first}.#{domain}", '-showcerts')} | openssl x509 -outform PEM > #{path('cert.pem')}").stdout
  end
end
