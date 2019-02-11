require "net/ssh/cli/version"
require 'net/ssh'
require "active_support/core_ext/hash/indifferent_access"
require 'timeout'

module Net
  module SSH
    module CLI
      class Error < StandardError
        class Pty < Error; end
        class RequestShell < Error; end
        class UndefinedMatch < Error; end
        class ChannelSetupTimeout < Error; end
        class ReadTillTimeout < Error; end
      end

      attr_accessor :options, :channel, :stdout, :stderr
      attr_accessor :host, :ip, :user
      attr_accessor :default_match, :process_stdout_procs, :process_stderr_procs
      attr_accessor :net_ssh, :net_ssh_options, :process_time
      attr_accessor :net_ssh_timeout, :channel_setup_timeout, :read_till_timeout

      def initialize(**opts)
        self.options = ActiveSupport::HashWithIndifferentAccess.new(opts)

        self.net_ssh = options[:net_ssh] if options[:net_ssh]
        self.net_ssh_options = options[:net_ssh_options] || {}
        self.host = options[:host] || ip || options[:net_ssh]&.host

        self.user = user || options[:user] || net_ssh_options[:user] || ENV["USER"] 
        self.ip = ip

        self.default_match = options[:default_match] if options[:default_match]

        self.process_stdout_procs = options[:process_stdout_procs] || {}
        self.process_stderr_procs = options[:process_stderr_procs] || {}

        self.net_ssh_timeout       = options[:net_ssh_timeout] || net_ssh_options[:timeout] 
        self.channel_setup_timeout = options[:channel_setup_timeout]   
        self.read_till_timeout     = options[:read_till_timeout]      

        self.process_time = 0.00001
      end

      def net_ssh
        return @net_ssh if @net_ssh
        ::Timeout.timeout(net_ssh_timeout, ::Net::SSH::Timeout) do
          self.net_ssh = Net::SSH.start(ip || host, user, self.net_ssh_options)
        end
        @net_ssh
      rescue => error
        self.net_ssh = nil
        raise
      ensure
      end

      ## channel & stderr|stdout stream handling
      #

      def stdout
        @stdout ||= String.new
      end

      def stdout!
        var = stdout
        self.stdout = String.new
        var
      end

      def stderr
        @stderr ||= String.new
      end

      def stderr!
        var = stderr
        self.stderr = String.new
        var
      end

      def open_channel #cli_channel
        ::Timeout.timeout(channel_setup_timeout, Error::ChannelSetupTimeout) do
          net_ssh.open_channel do |channel_|
            self.channel = channel_
            channel_.request_pty do |ch,success|
              raise Error::Pty, "#{host || ip} Failed to open ssh pty" unless success
            end
            channel_.send_channel_request("shell") do |ch, success|
              raise Error::RequestShell.new("Failed to open ssh shell") unless success
            end
            channel_.on_data do |ch,data|
              process_stdout(data)
            end
            channel_.on_extended_data do |ch,type,data|
              process_stderr(data,type)
            end
            channel_.on_close do
              close
            end
          end
          while !channel
            process
          end
          process
        end
      rescue => error
        close
        raise
      ensure
      end

      def process_stdout(data)
        stdout << data
        process_stdout_procs.each do |regex, the_proc|
          the_proc.call if stdout[regex]
        end
      end
    
      def process_stderr(data, type)
        stderr << data
        process_stderr_procs.each do |regex, the_proc|
          the_proc.call if stderr[regex]
        end
      end


      def write(content = String.new)
        raise Error.new("channel is not stablished or gone") unless channel
        channel.send_data content
        process
        content
      end
      alias :print :write

      def read
        process
        pre_buf = stdout
        self.stdout = String.new
        pre_buf
      end

      ## fancy match|prompt handling methods
      #

      def current_match
        @with_match[-1] ? @with_match[-1] : default_match
      end

      attr_accessor :named_match
      def named_match
        @named_matches ||= ActiveSupport::HashWithIndifferentAccess.new
      end

      def with_named_match(name, &blk)
        raise Error::UndefinedMatch.new("unknown named_match #{name}") unless named_match[name]
        with_default_match(named_match[name]) do
          yield
        end
      end

      # prove a block where the default match changes 
      def with_default_match(match, &blk)
        @with_default_match ||= []
        @with_default_match << match
        self.default_match = match
        yield
      ensure
        self.default_match = @with_default_match.delete_at(-1)
      end

      def read_till(match: default_match, **options)
        raise Error::UndefinedMatch.new("no match given or default_match defined") unless match
        ::Timeout.timeout(read_till_timeout, Error::ReadTillTimeout.new("output did not match #{match.inspect} within #{read_till_timeout}")) do
          with_default_match(match) do
            while !stdout[default_match]
              sleep 0.1
              process
            end
          end
        end
        read
      rescue => error
        raise
      ensure
      end

      def cmd(command, **options)
        read
        write command + "\n"
        value = read_till(**options)
        value[command] = "" if value[command] if options[:delete_cmd]
        value[options[:match] || default_match] = "" if value[options[:match] || default_match] if options[:delete_prompt]
        value
      end

      def cmds(commands, **options)
        commands.map {|command| [command, cmd(command, **options)]}.to_h
      end

      def dialog(command, match, **options)
        read
        write command
        read_till(match: match, **options)
      end
  
      ## NET::SSH
      #

      def process(time = process_time)
        net_ssh.process(time)
      rescue IOError => error
        raise Error.new(error.message)
      end

      def close
        return unless net_ssh
        net_ssh.cleanup_channel(channel) if channel
        self.channel = nil
        # ssh.close if ssh.channels.none? # should the connection be closed if the last channel gets closed?
      end

      def connect
        open_channel unless channel
      end

      def reconnect
        disconnect
        connect
      end

      def disconnect
        close
        net_ssh.close if net_ssh
        self.net_ssh = nil
      end
  
      def shutdown!
        net_ssh.shutdown! if net_ssh
      end
    end
  end
end

class Net::SSH::CLI::Channel
  include Net::SSH::CLI
  def initialize(**options)
    super
    open_channel
  end
end

module Net::SSH
  def request_cli_channel
    NET::SSH::CLI.new(net_ssh: self)
  end
end
