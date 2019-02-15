# frozen_string_literal: true

require 'net/ssh/cli/version'
require 'net/ssh'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/object/blank'
require 'timeout'
require 'logger'

module Net
  module SSH
    module CLI
      class Error < StandardError
        class Pty < Error; end
        class RequestShell < Error; end
        class UndefinedMatch < Error; end
        class OpenChannelTimeout < Error; end
        class ReadTillTimeout < Error; end
      end

      def initialize(**opts)
        options.merge!(opts)
        self.net_ssh = options.delete(:net_ssh)
        self.logger = options.delete(:logger) || Logger.new(STDOUT, level: Logger::WARN)
        open_channel unless lazy
      end

      attr_accessor :channel, :stdout, :stderr, :net_ssh, :logger

      ## make everthing configurable!
      #

      DEFAULT = ActiveSupport::HashWithIndifferentAccess.new(
        default_prompt: /^(\S+@\S+\s*)/,
        process_time: 0.00001,
        read_till_timeout: nil,
        read_till_rm_prompt: false,
        cmd_rm_prompt: false,
        cmd_rm_command: false,
        lazy: true
      )

      def default(**defaults)
        (@default ||= DEFAULT.clone).merge(**defaults)
      end

      def default!(**defaults)
        default.merge!(**defaults)
      end

      # don't even think about nesting hashes here
      def options(**_opts)
        @options ||= default
      end

      # don't even think about nesting hashes here
      def options!(**opts)
        options.merge!(opts)
      end

      # don't even think about nesting hashes here
      def options=(opts)
        @options = ActiveSupport::HashWithIndifferentAccess.new(opts)
      end

      [:default_prompt, :process_time, :read_till_timeout, :cmd_rm_command, :cmd_rm_prompt, :read_till_rm_prompt, :lazy].each do |name|
        define_method name do
          options[name]
        end
        define_method "#{name}=" do |value|
          options[name] = value
        end
      end

      [:process_stdout_procs, :process_stderr_procs, :named_prompts, :net_ssh_options, :open_channel_options].each do |name|
        define_method name do
          options[name] ||= ActiveSupport::HashWithIndifferentAccess.new
        end
        define_method "#{name}!" do |**opts|
          send(name).merge!(**opts)
        end
        define_method "#{name}=" do |value|
          options[name] = ActiveSupport::HashWithIndifferentAccess.new(value)
        end
      end

      ## Net::SSH instance
      #

      def net_ssh
        return @net_ssh if @net_ssh

        logger.debug { 'Net:SSH #start' }
        self.net_ssh = Net::SSH.start(net_ssh_options[:ip] || net_ssh_options[:host], net_ssh_options[:user] || ENV['USER'], net_ssh_options)
      rescue => error
        self.net_ssh = nil
        raise
      ensure
      end
      alias proxy net_ssh

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

      def open_channel # cli_channel
        ::Timeout.timeout(open_channel_options[:timeout], Error::OpenChannelTimeout) do
          net_ssh.open_channel do |channel_|
            logger.debug 'channel is open'
            self.channel = channel_
            channel_.request_pty do |_ch, success|
              raise Error::Pty, "#{host || ip} Failed to open ssh pty" unless success
            end
            channel_.send_channel_request('shell') do |_ch, success|
              raise Error::RequestShell, 'Failed to open ssh shell' unless success
            end
            channel_.on_data do |_ch, data|
              process_stdout(data)
            end
            channel_.on_extended_data do |_ch, type, data|
              process_stderr(data, type)
            end
            channel_.on_close do
              close
            end
          end
          until channel do process end
        end
        logger.debug 'channel is ready, running callbacks now'
        read_till if open_channel_options[:after_read_till_prompt]
        open_channel_options[:after_proc]&.call
        process
      rescue => error
        close
        raise
      ensure
      end

      def process_stdout(data)
        stdout << data
        process_stdout_procs.each { |_name, a_proc| a_proc.call }
        stdout
      end

      def process_stderr(data, _type)
        stderr << data
        process_stderr_procs.each { |_name, a_proc| a_proc.call }
        stderr
      end

      def write(content = String.new)
        raise Error, 'channel is not stablished or gone' unless channel

        logger.debug { "#write #{content.inspect}" }
        channel.send_data content
        process
        content
      end

      def write_n(content = String.new)
        write content + "\n"
      end

      # returns the stdout buffer and empties it
      def read
        process
        pre_buf = stdout
        self.stdout = String.new
        logger.debug("#read: \n#{pre_buf}")
        pre_buf
      end

      ## fancy prompt|prompt handling methods
      #

      def current_prompt
        @with_prompt ? (@with_prompt[-1] || default_prompt) : default_prompt
      end

      def with_named_prompt(name)
        raise Error::UndefinedMatch, "unknown named_prompt #{name}" unless named_prompts[name]

        with_prompt(named_prompts[name]) do
          yield
        end
      end

      # prove a block where the default prompt changes
      def with_prompt(prompt)
        logger.debug { "#with_prompt: #{current_prompt.inspect} => #{prompt.inspect}" }
        @with_prompt ||= []
        @with_prompt << prompt
        self.default_prompt = prompt
        yield
      ensure
        self.default_prompt = @with_prompt.delete_at(-1)
        logger.debug { "#with_prompt: => #{current_prompt.inspect}" }
      end

      def read_till(prompt: current_prompt, **options)
        raise Error::UndefinedMatch, 'no prompt given or default_prompt defined' unless prompt

        timeout = options[:timeout] || read_till_timeout
        ::Timeout.timeout(timeout, Error::ReadTillTimeout.new("output did not prompt #{prompt.inspect} within #{timeout}")) do
          with_prompt(prompt) do
            process until stdout[default_prompt]
          end
        end
        read
      rescue => error
        raise
      ensure
      end

      def read_for(seconds:, **_options)
        process
        sleep seconds
        process
        read
      end

      def dialog(command, prompt, **options)
        pre_read = read
        logger.debug { "#dialog ignores the following pre-output #{pre_read.inspect}" } if pre_read.present?
        write command
        output = read_till(prompt: prompt, **options)
        rm_prompt!(output, prompt: prompt, **options)
        rm_command!(output, command, prompt: prompt, **options)
        output
      end

      # 'read' first on purpuse as a feature. once you cmd you ignore what happend before. otherwise use read|write directly.
      # this should avoid many horrible state issues where the prompt is not the last prompt
      def cmd(command, **options)
        pre_read = read
        logger.debug { "#cmd ignoring pre-read: #{pre_read.inspect}" } if pre_read.present?
        write_n command
        output = read_till(**options)
        rm_prompt!(output, **options)
        rm_command!(output, command, **options)
        output
      end
      alias command cmd

      def cmds(commands, **options)
        commands.map { |command| [command, cmd(command, **options)] }.to_h
      end
      alias commands cmds

      def rm_command?(**opts)
        !opts[:rm_cmd].nil? ? opts[:rm_cmd] : cmd_rm_command
      end

      def rm_command!(output, command, **options)
        output[command + "\n"] = '' if rm_command?(options) && output[command + "\n"]
      end

      def rm_prompt?(**opts)
        !opts[:rm_prompt].nil? ? opts[:rm_prompt] : cmd_rm_prompt
      end

      def rm_prompt!(output, **options)
        if rm_prompt?(options)
          prompt = options[:prompt] || default_prompt
          if output[prompt]
            prompt.is_a?(Regexp) ? output[prompt, 1] = '' : output[prompt] = ''
          end
        end
      end

      ## NET::SSH
      #

      def process(time = process_time)
        net_ssh.process(time)
      rescue IOError => error
        raise Error, error.message
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
        net_ssh&.close
        self.net_ssh = nil
      end

      def shutdown!
        net_ssh&.shutdown!
      end

      private
    end
  end
end

class Net::SSH::CLI::Channel
  include Net::SSH::CLI
  def initialize(**options)
    super
    # open_channel
  end
end

class Net::SSH::Connection::Session
  attr_accessor :cli_channels
  def open_cli_channel(**opts)
    Net::SSH::CLI::Channel.new({ net_ssh: self, lazy: false }.merge(opts))
  end
end
