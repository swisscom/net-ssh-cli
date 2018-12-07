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
        self.host = host
        self.user = user
        self.ip = ip
        self.ssh_options = options[:ssh] || {}
      end

      def ssh
        @ssh ||= (ssh_options[:proxy] || Net::SSH.start(ip || host, user, self.ssh_options))
      end

      def stdout
        @stdout ||= String.new
      end

      def stderr
        @stderr ||= String.new
      end

      def channel
        @channel || setup_channel
      end

      def setup_channel #cli_channel
        ssh.open_channel do |chn|
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
        channel
      end

      def process_stdout(data)
        stdout << data
      end
    
      def process_stderr(data, type)
        stderr << data if type == 1
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

      def read_till_match(**options)
        raise UndefinedMatch.new("no match given") unless options[:match] || default_match
        while !stdout[options[:match] || default_match]   #[/\w+@\w+:/]
          process
        end
        read
      end

      def cmd(command, **options)
        read
        write command + "\n"
        read_till_match(**options)
      end

      def dialog(command, match, **options)
        read
        write command
        read_till_match(match)
      end

      def process(time = 0.0001)
        ssh.process(time)
      rescue IOError => error
        raise Error.new(error.message)
      end

      def close
        return unless ssh
        ssh.cleanup_channel(channel)
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
        ssh.close if ssh
        self.ssh = nil
      end
  
      def shutdown!
        ssh.shutdown! if ssh
      end
    end
  end
end

class Net::SSH::CLI::Host
  include Net::SSH::CLI
end
