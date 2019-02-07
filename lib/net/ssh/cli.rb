require "net/ssh/cli/version"
require 'net/ssh'

module Net
  module SSH
    module CLI
      class Error < StandardError
        class Pty < Error; end
        class RequestShell < Error; end
        class UndefinedMatch < Error; end
      end

      attr_accessor :options, :ssh, :ssh_options, :channel, :host, :ip, :user, :stdout, :stderr, :default_match

      def initialize(host: , user: ENV["USER"], **opts)
        self.options = opts
        self.ssh_options = options[:ssh] || {}
        self.host = host || ip || ssh_options[:net_ssh]&.host
        raise Error.new("host missing") unless host
        self.user = user
        self.ip = ip
        self.default_match = options[:default_match] if options[:default_match]
      end

      def net_ssh
        @net_ssh ||= (ssh_options[:net_ssh] || Net::SSH.start(ip || host, user, self.ssh_options))
      end

      def stdout
        @stdout ||= String.new
      end

      def stderr
        @stderr ||= String.new
      end

      def channel
        @channel #|| setup_channel
      end

      def setup_channel #cli_channel
        net_ssh.open_channel do |chn|
          self.channel = chn
          chn.request_pty do |ch,success|
            raise Error::Pty, "#{host || ip} Failed to open ssh pty" unless success
          end
          chn.send_channel_request("shell") do |ch, success|
            raise Error::RequestShell.new("Failed to open ssh shell") unless success
          end
          chn.on_data do |ch,data|
            process_stdout(data)
          end
          chn.on_extended_data do |ch,type,data|
            process_stderr(data,type)
          end
          #chn.on_close { @eof = true }
        end
        process(0.01)
      end

      def process_stdout(data)
        stdout << data
      end
    
      def process_stderr(data, type)
        stderr << data if type == 1
      end

      def current_match
        @with_match[-1] ? @with_match[-1] : default_match
      end

      def write(content = String.new)
        channel.send_data content
        process
        content
      end
      alias :print :write

      def puts(content = String.new)
        write(content + "\n")
      end

      def read
        process
        pre_buf = stdout
        self.stdout = String.new
        pre_buf
      end

      def read_clean(cmd: , match: )
        # todo cleanup the cmd and prompt from the output
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
        with_default_match(match) do
          while !stdout[default_match]
            process
          end
        end
        read
      end

      def cmd(command, **options)
        read
        write command + "\n"
        read_till(**options)
      end

      def cmds(commands, **options)
        commands.map {|command| [command, cmd(command, **options)]}.to_h
      end

      def dialog(command, match, **options)
        read
        write command
        read_till(match: match, **options)
      end

      def process(time = 0.0001)
        net_ssh.process(time)
      rescue IOError => error
        raise Error.new(error.message)
      end

      def close
        return unless ssh
        net_ssh.cleanup_channel(channel)
        self.channel = nil
        # ssh.close if ssh.channels.none? # should the connection be closed if the last channel gets closed?
      end

      def connect
        setup_channel unless channel
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
end

class Net::SSH
  def open_cli_channel
    NET::SSH::CLI.new(net_ssh: self)
  end
end
