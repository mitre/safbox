# frozen_string_literal: true

unit = 'qemu-guest-agent.service'
main_pid = command("systemctl show -p MainPID --value #{unit}").stdout.strip
agent_running = main_pid.match?(/^[1-9]\d*$/)
agent_args = agent_running ? file("/proc/#{main_pid}/cmdline").content.to_s.split("\0") : []

# The filter is either an allow list (--allow-rpcs=a,b / -a a,b) or a block
# list (--block-rpcs=a,b / -b a,b). Returns [mode, [rpcs]].
rpc_filter = lambda do |args|
  args.each_with_index do |arg, i|
    { 'allow' => %w[--allow-rpcs -a], 'block' => %w[--block-rpcs -b] }.each do |mode, flags|
      flags.each do |flag|
        return [mode, arg.split('=', 2).last.split(',')] if arg.start_with?("#{flag}=")
        return [mode, args[i + 1].to_s.split(',')] if arg == flag
      end
    end
  end
  [nil, []]
end

control 'safbox-guest-agent-1' do
  impact 1.0
  title "The guest agent keeps the distribution's RPC filter: no in-guest exec or file access"
  desc 'With guest-exec or guest-file-* enabled, anyone with administrative access to the hypervisor can run commands and read or write files inside the appliance without logging in. The distribution ships a filter that disables them; the image must keep it unmodified.'
  # On platforms without a guest-agent channel the agent cannot run; the
  # deploy sets guest_agent_expected=false there. Everywhere else a stopped
  # agent is a failure, not a skip.
  only_if('guest agent not expected on this platform (guest_agent_expected=false)') do
    input('guest_agent_expected')
  end

  describe 'qemu-guest-agent main process' do
    subject { main_pid }
    it { should match(/^[1-9]\d*$/) }
  end

  mode, rpcs = rpc_filter.call(agent_args)
  denied = input('guest_agent_denied_rpcs')

  describe 'guest agent RPC filter mode' do
    subject { mode }
    it { should be_in %w[allow block] }
  end

  if mode == 'allow'
    describe 'RPCs the guest agent allows' do
      subject { rpcs }
      denied.each { |rpc| it { should_not include rpc } }
    end
  elsif mode == 'block'
    describe 'RPCs the guest agent blocks' do
      subject { rpcs }
      denied.each { |rpc| it { should include rpc } }
    end
  end

  describe command("systemctl show -p DropInPaths --value #{unit}") do
    its('stdout.strip') { should be_empty }
  end

  describe command('rpm -V --nomtime qemu-guest-agent') do
    its('stdout') { should be_empty }
  end
end
