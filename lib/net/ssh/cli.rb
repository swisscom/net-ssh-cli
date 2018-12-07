require "net/ssh/cli/version"
require 'net/ssh'
require 'hooks'

module Net
  module SSH
    module CLI
      #include Net::SSH
      include Hooks

      class Error < StandardError
        class Pty < Error; end
        class RequestShell < Error; end
        class MatchMissing < Error; end
      end

      attr_accessor :options, :ssh, :ssh_options, :channel, :host, :ip, :user, :stdout, :stderr

      def initialize(host, user, **opts)
        self.options = opts
        self.host = host
        self.user = user
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
            raise Error::Pty, "Failed to open ssh pty" unless success
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
        process(0.3)
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

      def read_till_match(regex,**options)
        while !stdout[/#{host}/]   #[/\w+@\w+:/]
          process
        end
        read
      end

      def cmd(command, **options)
        raise 
        read
        write command + "\n"
        read_till_match(options[:match] || /#{host}/)
      end

      def return(command, **options)
        read
        write command + "\n"
        read
      end 
      alias :enter :return

      def process(time = 0.1)
        ssh.process(time)
      rescue IOError => error
        # closed stream
        raise Error.new(error.message)
      end

      def close
        if ssh
          ssh.cleanup_channel(channel)
          self.channel = nil
          ssh.close if ssh.channels.none?
        end
      end
  
      def shutdown!
        ssh.shutdown! if ssh
      end
    end
  end
end

class Net::CLI
  include Net::SSH::CLI
end
