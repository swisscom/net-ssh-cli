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

      def initialize(**opts)
        self.options.merge!(opts)
        self.net_ssh = options.delete(:net_ssh)
      end

      attr_accessor :channel, :stdout, :stderr, :net_ssh

      ## make everthing configurable!

      def default(**defaults)
        @default ||= ActiveSupport::HashWithIndifferentAccess.new(
          default_prompt: /\\n/,
          process_time: 0.00001,
          open_channel_timeout: nil,
          read_till_timeout: nil,
        ).merge!(**defaults)
      end

      # don't even think about nesting hashes here
      def options(**options)
        @options ||= default
      end

      # don't even think about nesting hashes here
      def options=(opts)
        @options = ActiveSupport::HashWithIndifferentAccess.new(opts)
      end

      [:default_prompt, :process_time, :open_channel_timeout, :read_till_timeout].each do |name|
        define_method name do
          options[name]
        end
        define_method "#{name}=" do |value|
          options[name] = value
        end
      end

      [:process_stdout_procs, :process_stderr_procs, :named_prompts, :net_ssh_options].each do |name|
        define_method name do
          options[name] ||= ActiveSupport::HashWithIndifferentAccess.new
        end
        define_method "#{name}=" do |value|
          options[name] = ActiveSupport::HashWithIndifferentAccess.new(value)
        end
      end

      ## Net::SSH instance
      #

      def net_ssh
        return @net_ssh if @net_ssh
        self.net_ssh = Net::SSH.start(net_ssh_options[:ip] || net_ssh_options[:host], net_ssh_options[:user] || ENV["USER"], self.net_ssh_options)
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
        ::Timeout.timeout(open_channel_timeout, Error::ChannelSetupTimeout) do
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
        stdout
      end
    
      def process_stderr(data, type)
        stderr << data
        process_stderr_procs.each do |regex, the_proc|
          the_proc.call if stderr[regex]
        end
        stderr
      end


      def write(content = String.new)
        raise Error.new("channel is not stablished or gone") unless channel
        channel.send_data content
        process
        content
      end

      def write_n(content = String.new)
        write content + "\n"
      end

      def read
        process
        pre_buf = stdout
        self.stdout = String.new
        pre_buf
      end

      ## fancy prompt|prompt handling methods
      #

      def current_prompt
        @with_prompt ? (@with_prompt[-1] ? @with_prompt[-1] : default_prompt) : default_prompt
      end

      def with_named_prompt(name, &blk)
        raise Error::UndefinedMatch.new("unknown named_prompt #{name}") unless named_prompts[name]
        with_prompt(named_prompts[name]) do
          yield
        end
      end

      # prove a block where the default prompt changes 
      def with_prompt(prompt, &blk)
        @with_prompt ||= []
        @with_prompt << prompt
        self.default_prompt = prompt
        yield
      ensure
        self.default_prompt = @with_prompt.delete_at(-1)
      end

      def read_till(prompt: current_prompt, **options)
        raise Error::UndefinedMatch.new("no prompt given or default_prompt defined") unless prompt
        timeout = options[:timeout] || read_till_timeout
        ::Timeout.timeout(timeout, Error::ReadTillTimeout.new("output did not prompt #{prompt.inspect} within #{timeout}")) do
          with_prompt(prompt) do
            while !stdout[default_prompt]
              process
            end
          end
        end
        read
      rescue => error
        raise
      ensure
      end

      def read_for(seconds: , **options)
        process
        sleep seconds
        process
        read
      end

      def dialog(command, prompt, **options)
        read
        write command
        output = read_till(prompt: prompt, **options)
        rm_cmd(output, command, **options)
        output
      end

      # 'read' first on purpuse as a feature. once you cmd you ignore what happend before. otherwise use read|write directly. 
      # this should avoid many horrible state issues where the prompt is not the last prompt
      def cmd(command, **options)
        read
        write_n command
        output = read_till(**options)
        rm_cmd(output, command, **options)
        rm_prompt(output, **options)
        output
      end

      def cmds(commands, **options)
        commands.map {|command| [command, cmd(command, **options)]}.to_h
      end

      attr_writer :rm_cmd
      def rm_cmd?(**options)
        options[:rm_cmd] != nil ? options[:rm_cmd] : @rm_cmd
      end
      def rm_cmd(output, command, **options)
        output[command + "\n"] = "" if output[command + "\n"] if rm_cmd?(options)
      end

      attr_writer :rm_prompt
      def rm_prompt?(**options)
        options[:rm_prompt] != nil ? options[:rm_prompt] : @rm_prompt
      end
      def rm_prompt(output, **options)
        if rm_prompt?(options)
          prompt = options[:prompt] || default_prompt
          if output[prompt]
            prompt.is_a?(Regexp) ? output[prompt,1] = "" :  output[prompt] = ""
          end
        end
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

      # feels wrong

      def disconnect
        close
        net_ssh.close if net_ssh
        self.net_ssh = nil
      end
  
      def shutdown!
        net_ssh.shutdown! if net_ssh
      end

      private
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
  def open_cli_channel
    NET::SSH::CLI::Channel.new(net_ssh: self)
  end
end
