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
        class PromptDetection < Error; end
        class CMD < Error; end
      end

      # Example
      # net_ssh = Net::SSH.start("localhost")
      # net_ssh_cli = Net::SSH::CLI.start(net_ssh: net_ssh)
      # net_ssh_cli.cmd "cat /etc/passwd"
      # => "root:x:0:0:root:/root:/bin/bash\n..."
      def self.start(**opts)
        Net::SSH::CLI::Session.new(**opts)
      end

      def initialize(**opts)
        options.merge!(opts)
        self.net_ssh = options.delete(:net_ssh)
        self.logger = options.delete(:logger) || Logger.new(STDOUT, level: Logger::WARN)
        self.process_count = 0
        @new_data = String.new
      end

      attr_accessor :channel, :stdout, :net_ssh, :logger, :new_data, :process_count

      OPTIONS = ActiveSupport::HashWithIndifferentAccess.new(
        default_prompt:            /\n?^(\S+@.*)\z/,                             # the default prompt to search for
        cmd_rm_prompt:             false,                                        # whether the prompt should be removed in the output of #cmd
        cmd_rm_command:            false,                                        # whether the given command should be removed in the output of #cmd
        run_impact:                false,                                        # whether to run #impact commands. This might align with testing|development|production. example #impact("reboot")
        read_till_timeout:         nil,                                          # timeout for #read_till to find the match
        named_prompts:             ActiveSupport::HashWithIndifferentAccess.new, # you can used named prompts for #with_prompt {} 
        before_cmd_procs:          ActiveSupport::HashWithIndifferentAccess.new, # procs to call before #cmd 
        after_cmd_procs:           ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  #cmd
        before_on_stdout_procs:    ActiveSupport::HashWithIndifferentAccess.new, # procs to call before data arrives from the underlying connection 
        after_on_stdout_procs:     ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  data arrives from the underlying connection
        before_on_stdin_procs:     ActiveSupport::HashWithIndifferentAccess.new, # procs to call before data is sent to the underlying channel 
        after_on_stdin_procs:      ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  data is sent to the underlying channel
        before_open_channel_procs: ActiveSupport::HashWithIndifferentAccess.new, # procs to call before opening a channel 
        after_open_channel_procs:  ActiveSupport::HashWithIndifferentAccess.new, # procs to call after  opening a channel, for example you could call #detect_prompt or #read_till
        open_channel_timeout:      nil,                                          # timeout to open the channel
        net_ssh_options:           ActiveSupport::HashWithIndifferentAccess.new, # a wrapper for options to pass to Net::SSH.start in case net_ssh is undefined
        process_time:              0.00001,                                      # how long #process is processing net_ssh#process or sleeping (waiting for something)
        background_processing:     false,                                        # default false, whether the process method maps to the underlying net_ssh#process or the net_ssh#process happens in a separate loop
      )

      def options
        @options ||= begin
          opts = OPTIONS.clone
          opts.each do |key, value|
            opts[key] = value.clone if value.is_a?(Hash)
          end
          opts
        end
      end

      # don't even think about nesting hashes here
      def options!(**opts)
        options.merge!(opts)
      end

      def options=(opts)
        @options = ActiveSupport::HashWithIndifferentAccess.new(opts)
      end

      OPTIONS.keys.each do |name|
        define_method name do
          options[name]
        end
        define_method "#{name}=" do |value|
          options[name] = value
        end
        define_method "#{name}?" do
          !!options[name]
        end
      end

      OPTIONS.keys.select {|key| key.to_s.include? "procs"}.each do |name|
        define_method name.sub("_procs","") do |&blk|
          self.send(name)[SecureRandom.uuid] = Proc.new {blk.call}
        end
      end

      def stdout
        @stdout ||= String.new
      end

      def stdout!
        var = stdout
        self.stdout = String.new
        var
      end

      def on_stdout(new_data)
        self.new_data = new_data
        before_on_stdout_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        stdout << new_data
        after_on_stdout_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        self.process_count += 1
        process unless process_count > 100 # if we receive data, we probably receive more - improves performance - but on a lot of data, this leads to a stack level too deep
        self.process_count -= 1
        stdout
      end

      def write(content = String.new)
        logger.debug { "#write #{content.inspect}" }
        before_on_stdin_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        channel.send_data content
        process
        after_on_stdin_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        content
      end
      alias stdin write

      def write_n(content = String.new)
        write content + "\n"
      end

      def read
        process
        var = stdout!
        logger.debug("#read: \n#{var}")
        var
      end

      ## fancy prompt|prompt handling methods
      #

      def current_prompt
        with_prompts[-1] || default_prompt
      end

      def with_named_prompt(name)
        raise Error::UndefinedMatch, "unknown named_prompt #{name}" unless named_prompts[name]

        with_prompt(named_prompts[name]) do
          yield
        end
      end

      def detect_prompt(seconds: 3)
        write_n
        future = Time.now + seconds
        while future > Time.now
          process
          sleep 0.1
        end
        self.default_prompt = read[/\n?^.*\z/]
        raise Error::PromptDetection, "couldn't detect a prompt" unless default_prompt.present?

        default_prompt
      end

      # prove a block where the default prompt changes
      def with_prompt(prompt)
        logger.debug { "#with_prompt: #{current_prompt.inspect} => #{prompt.inspect}" }
        with_prompts << prompt
        yield
        prompt
      ensure
        with_prompts.delete_at(-1)
        logger.debug { "#with_prompt: => #{current_prompt.inspect}" }
      end

      def read_till(prompt: current_prompt, timeout: read_till_timeout, **_opts)
        raise Error::UndefinedMatch, 'no prompt given or default_prompt defined' unless prompt

        hard_timeout = timeout
        hard_timeout += 0.5 if timeout
        ::Timeout.timeout(hard_timeout, Error::ReadTillTimeout, "#{current_prompt.inspect} didn't match on #{stdout.inspect} within #{timeout}s") do
          with_prompt(prompt) do
            soft_timeout = Time.now + timeout if timeout
            until stdout[current_prompt] do
              if timeout and soft_timeout < Time.now
                raise Error::ReadTillTimeout, "#{current_prompt.inspect} didn't match on #{stdout.inspect} within #{timeout}s"
              end
              process
              sleep 0.1
            end
          end
        end
        read
      end

      def read_for(seconds:)
        process(seconds)
        read
      end

      def dialog(command, prompt, **opts)
        opts = opts.clone.merge(prompt: prompt)
        cmd(command, **opts)
      end

      # 'read' first on purpuse as a feature. once you cmd you ignore what happend before. otherwise use read|write directly.
      # this should avoid many horrible state issues where the prompt is not the last prompt
      def cmd(command, pre_read: true, rm_prompt: cmd_rm_prompt, rm_command: cmd_rm_command, prompt: current_prompt, **opts)
        opts = opts.clone.merge(pre_read: pre_read, rm_prompt: rm_prompt, rm_command: rm_command, prompt: prompt)
        if pre_read
          pre_read_data = read
          logger.debug { "#cmd ignoring pre-command output: #{pre_read_data.inspect}" } if pre_read_data.present?
        end
        before_cmd_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        write_n command
        output = read_till(**opts)
        rm_prompt!(output, **opts)
        rm_command!(output, command, **opts)
        after_cmd_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        output
      rescue Error::ReadTillTimeout => error
        raise Error::CMD, "#{error.message} after cmd #{command.inspect} was sent"
      end
      alias command cmd
      alias exec cmd

      def cmds(*commands, **opts)
        commands.flatten.map { |command| [command, cmd(command, **opts)] }
      end
      alias commands cmds

      def rm_command!(output, command, **opts)
        output[command + "\n"] = '' if rm_command?(**opts) && output[command + "\n"]
      end

      def rm_prompt!(output, **opts)
        if rm_prompt?(**opts)
          prompt = opts[:prompt] || current_prompt
          if output[prompt]
            prompt.is_a?(Regexp) ? output[prompt, 1] = '' : output[prompt] = ''
          end
        end
      end

      # the same as #cmd but it will only run the command if the option run_impact is set to true.
      # this can be used for commands which you might not want to run in development|testing mode but in production
      # cli.impact("reboot") 
      # => "skip: reboot"
      # cli.run_impact = true
      # cli.impact("reboot") 
      # => "system is going to reboot NOW"
      def impact(command, **opts)
        run_impact? ? cmd(command, **opts) : "skip: #{command.inspect}"
      end

      # same as #cmds but for #impact instead of #cmd
      def impacts(*commands, **opts)
        commands.flatten.map { |command| [command, impact(command, **opts)] }
      end

      def host
        @net_ssh&.host
      end
      alias hostname host
      alias to_s host

      ## NET::SSH
      #

      def net_ssh
        return @net_ssh if @net_ssh

        logger.debug { 'Net:SSH #start' }
        self.net_ssh = Net::SSH.start(net_ssh_options[:ip] || net_ssh_options[:host] || 'localhost', net_ssh_options[:user] || ENV['USER'], formatted_net_ssh_options)
      rescue StandardError => error
        self.net_ssh = nil
        raise
      end
      alias proxy net_ssh

      # have a deep look at the source of Net::SSH
      # session#process https://github.com/net-ssh/net-ssh/blob/dd13dd44d68b7fa82d4ca9a3bbe18e30c855f1d2/lib/net/ssh/connection/session.rb#L227
      # session#loop    https://github.com/net-ssh/net-ssh/blob/dd13dd44d68b7fa82d4ca9a3bbe18e30c855f1d2/lib/net/ssh/connection/session.rb#L179
      # because the (cli) channel stays open, we always need to ensure that the ssh layer gets "processed" further. This can be done inside here automatically or outside in a separate event loop for the net_ssh connection.
      def process(time = process_time)
        background_processing? ? sleep(time) : net_ssh.process(time)
      rescue IOError => error
        raise Error, error.message
      end

      def open_channel # cli_channel
        before_open_channel_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        ::Timeout.timeout(open_channel_timeout, Error::OpenChannelTimeout) do
          net_ssh.open_channel do |new_channel|
            logger.debug 'channel is open'
            self.channel = new_channel
            new_channel.request_pty do |_ch, success|
              raise Error::Pty, "#{host || ip} Failed to open ssh pty" unless success
            end
            new_channel.send_channel_request('shell') do |_ch, success|
              raise Error::RequestShell, 'Failed to open ssh shell' unless success
            end
            new_channel.on_data do |_ch, data|
              on_stdout(data)
            end
            # new_channel.on_extended_data do |_ch, type, data| end
            # new_channel.on_close do end
          end
          until channel do process end
        end
        logger.debug 'channel is ready, running callbacks now'
        after_open_channel_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        process
        self
      end

      def close_channel
        net_ssh&.cleanup_channel(channel) if channel
        self.channel = nil
      end

      private

      def with_prompts
        @with_prompts ||= []
      end

      def formatted_net_ssh_options
        net_ssh_options.symbolize_keys.reject {|k,v| [:host, :ip, :user].include?(k)}
      end

      def rm_prompt?(**opts)
        opts[:rm_prompt].nil? ? cmd_rm_prompt : opts[:rm_prompt]
      end

      def rm_command?(**opts)
        opts[:rm_cmd].nil? ? cmd_rm_command : opts[:rm_cmd]
      end
    end
  end
end

class Net::SSH::CLI::Session
  include Net::SSH::CLI
end

class Net::SSH::Connection::Session
  attr_accessor :cli_channels
  def cli(**opts)
    cli_session = Net::SSH::CLI::Session.new({ net_ssh: self }.merge(opts))
    cli_session.open_channel
    cli_session
  end
end
