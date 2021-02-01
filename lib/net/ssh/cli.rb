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
        cmd_rm_command_tail:       "\n",                                         # which format does the end of line return after a command has been submitted. Could be something like "ls\n" "ls\r\n" or "ls \n" (extra spaces)
        run_impact:                false,                                        # whether to run #impact commands. This might align with testing|development|production. example #impact("reboot")
        read_till_timeout:         nil,                                          # timeout for #read_till to find the match
        read_till_hard_timeout:    nil,                                          # hard timeout for #read_till to find the match using Timeout.timeout(hard_timeout) {}. Might creates unpredicted sideffects
        read_till_hard_timeout_factor: 1.2,                                      # hard timeout factor in case read_till_hard_timeout is true
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
        on_stdout_processing:      100,                                          # whether to optimize the on_stdout performance by calling #process #optimize_on_stdout-times in case more data arrives
        sleep_procs:               ActiveSupport::HashWithIndifferentAccess.new, # procs to call instead of Kernel.sleep(), perfect for async hooks
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
        optimise_stdout_processing
        stdout
      end

      def stdin(content = String.new)
        logger.debug { "#write #{content.inspect}" }
        before_on_stdin_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        channel.send_data content
        process
        after_on_stdin_procs.each { |_name, a_proc| instance_eval(&a_proc) }
        content
      end
      alias write stdin

      def write_n(content = String.new)
        write content + "\n"
      end

      def read
        process
        var = stdout!
        logger.debug { "#read: \n#{var}" }
        var
      end

      ## fancy prompt|prompt handling methods
      #

      def current_prompt
        with_prompts[-1] || default_prompt
      end

      # run something with a different named prompt
      #
      # named_prompts["root"] = /(?<prompt>\nroot)\z/
      #
      # with_named_prompt("root") do
      #   cmd("sudo -i")
      #   cmd("cat /etc/passwd")
      # end
      # cmd("exit")
      #
      def with_named_prompt(name)
        raise Error::UndefinedMatch, "unknown named_prompt #{name}" unless named_prompts[name]

        with_prompt(named_prompts[name]) do
          yield
        end
      end

      # tries to detect the prompt
      # sends a "\n", waits for a X seconds, and uses the last line as prompt
      # this won't work reliable if the prompt changes during the session
      def detect_prompt(seconds: 3)
        write_n
        process(seconds)
        self.default_prompt = read[/\n?^.*\z/]
        raise Error::PromptDetection, "couldn't detect a prompt" unless default_prompt.present?

        default_prompt
      end

      # run something with a different prompt
      #
      # with_prompt(/(?<prompt>\nroot)\z/) do
      #   cmd("sudo -i")
      #   cmd("cat /etc/passwd")
      # end
      # cmd("exit")
      def with_prompt(prompt)
        logger.debug { "#with_prompt: #{current_prompt.inspect} => #{prompt.inspect}" }
        with_prompts << prompt
        yield
        prompt
      ensure
        with_prompts.delete_at(-1)
        logger.debug { "#with_prompt: => #{current_prompt.inspect}" }
      end

      # continues to process the ssh connection till #stdout matches the given prompt.
      # might raise a timeout error if a soft/hard timeout is given
      # be carefull when using the hard_timeout, this is using the dangerous Timeout.timeout
      # this gets really slow on large outputs, since the prompt will be searched in the whole output. Use \z in the regex if possible
      #
      # Optional named arguments:
      #  - prompt: expected to be a regex
      #  - timeout: nil or a number
      #  - hard_timeout: nil, true, or a number
      #  - hard_timeout_factor: nil, true, or a number
      #  -   when hard_timeout == true, this will set the hard_timeout as (read_till_hard_timeout_factor * read_till_timeout), defaults to 1.2 = +20%
      def read_till(prompt: current_prompt, timeout: read_till_timeout, hard_timeout: read_till_hard_timeout, hard_timeout_factor: read_till_hard_timeout_factor, **_opts)
        raise Error::UndefinedMatch, 'no prompt given or default_prompt defined' unless prompt
        hard_timeout = (read_till_hard_timeout_factor * timeout) if timeout and hard_timeout == true
        hard_timeout = nil if hard_timeout == true

        with_prompt(prompt) do
          ::Timeout.timeout(hard_timeout, Error::ReadTillTimeout, "#{current_prompt.inspect} didn't match on #{stdout.inspect} within #{hard_timeout}s") do
            soft_timeout = Time.now + timeout if timeout
            until prompt_in_stdout? do
              if timeout and soft_timeout < Time.now
                raise Error::ReadTillTimeout, "#{current_prompt.inspect} didn't match on #{stdout.inspect} within #{timeout}s"
              end
              process
              sleep 0.01 # don't race for CPU
            end
          end
        end
        read
      end

      def prompt_in_stdout?
        case current_prompt
        when Regexp
          !!stdout[current_prompt]
        when String
          stdout.include?(current_prompt)
        else
          raise Net::SSH::CLI::Error, "prompt/current_prompt is not a String/Regex #{current_prompt.inspect}"
        end
      end

      def read_for(seconds:)
        process(seconds)
        read
      end

      def dialog(command, prompt, **opts)
        opts = opts.clone.merge(prompt: prompt)
        cmd(command, **opts)
      end

      # send a command and get the output as return value
      # 1. sends the given command to the ssh connection channel
      # 2. continues to process the ssh connection until the prompt is found in the stdout
      # 3. prepares the output using your callbacks
      # 4. returns the output of your command
      # Hint: 'read' first on purpuse as a feature. once you cmd you ignore what happend before. otherwise use read|write directly.
      #       this should avoid many horrible state issues where the prompt is not the last prompt
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

      # Execute multiple cmds, see #cmd
      def cmds(*commands, **opts)
        commands.flatten.map { |command| [command, cmd(command, **opts)] }
      end
      alias commands cmds

      def rm_command!(output, command, **opts)
        output[command + cmd_rm_command_tail] = '' if rm_command?(**opts) && output[command + cmd_rm_command_tail]
      end

      # removes the prompt from the given output
      # prompt should contain a named match 'prompt' /(?<prompt>.*something.*)\z/
      # for backwards compatibility it also tries to replace the first match of the prompt /(something)\z/
      # it removes the whole match if no matches are given /something\z/ 
      def rm_prompt!(output, prompt: current_prompt, **opts)
        if rm_prompt?(**opts)
          if output[prompt]
            case prompt
            when String then output[prompt] = ''
            when Regexp
              if prompt.names.include?("prompt")
                output[prompt, "prompt"] = ''
              else
                begin
                  output[prompt, 1] = ''
                rescue IndexError
                  output[prompt] = ''
                end
              end
            end
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

      # if #sleep_procs are set, they will be called instead of Kernel.sleep
      # great for async
      # .sleep_procs["async"] = proc do |duration| async_reactor.sleep(duration) end
      #
      # cli.sleep(1)
      def sleep(duration)
        if sleep_procs.any?
          sleep_procs.each { |_name, a_proc| instance_exec(duration, &a_proc) }
        else
          Kernel.sleep(duration)
        end
      end

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

      # when new data is beeing received, likely more data will arrive - this improves the performance by a large factor
      # but on a lot of data, this leads to a stack level too deep
      # therefore it is limited to max #on_stdout_processing
      # the bigger on_stdout_processing, the closer we get to a stack level too deep
      def optimise_stdout_processing
        self.process_count += 1
        process unless process_count > on_stdout_processing
      ensure
        self.process_count -= 1
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
