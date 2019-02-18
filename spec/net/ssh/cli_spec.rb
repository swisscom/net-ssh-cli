# frozen_string_literal: false

require 'ostruct'

RSpec.describe Net::SSH::CLI do
  it 'has a version number' do
    expect(Net::SSH::CLI::VERSION).not_to be nil
  end

  describe 'initializes nicely' do
    let(:cli) { Net::SSH::CLI::Channel.new() }
    it {expect(cli.stdout).to eq("")}
    it {expect(cli.stderr).to eq("")}
    it {expect(Net::SSH::CLI::DEFAULT).to be_a(ActiveSupport::HashWithIndifferentAccess)}
    it {expect(cli.default).to be_a(ActiveSupport::HashWithIndifferentAccess)}
    it {expect(cli.options).to be_a(ActiveSupport::HashWithIndifferentAccess)}
    it {expect(cli.net_ssh_options).to be_a(ActiveSupport::HashWithIndifferentAccess)}
    it {expect(cli.open_channel_options).to be_a(ActiveSupport::HashWithIndifferentAccess)}
    it {expect(cli.logger).to be_a(Logger)}
  end

  describe 'fake Socket' do
    let(:default_prompt) { 'the_prompt' }
    let(:channel) { double(Net::SSH::Connection::Channel) }
    let(:net_ssh) { double(Net::SSH) }
    let(:cli) { Net::SSH::CLI::Channel.new(default_prompt: default_prompt, net_ssh: net_ssh) }
    before(:each) { allow(cli).to receive(:open_channel) {} }
    before(:each) { allow(cli).to receive(:channel) { channel } }
    before(:each) { allow(cli).to receive(:process) { true } }
    before(:each) { allow(channel).to receive(:send_data) { true } }
    before(:each) { allow(net_ssh).to receive(:host) { "localhost" } }

    context 'configuration' do
      context "#options" do
        let(:cli) { Net::SSH::CLI::Channel.new(default_prompt: default_prompt, net_ssh: net_ssh) }
        it {expect(cli.options).to be_a(Hash)}
        it {expect(cli.options).to be_a(ActiveSupport::HashWithIndifferentAccess)}
        it {expect(cli.options).to include(:process_time)}
        it {expect(cli.options!(banana: true)).to include(:banana)}
        it {expect(cli.options = {}).to eq({})}
      end
      context "#default" do
        it {expect(Net::SSH::CLI::DEFAULT).to include(:process_time)}
        it {expect(Net::SSH::CLI::DEFAULT).to include(:default_prompt)}
        it {expect(cli.default).to be_a(Hash)}
        it {expect(cli.default).to be_a(ActiveSupport::HashWithIndifferentAccess)}
        it {expect(cli.default).to include(:default_prompt)}
        it {expect(cli.default!).to include(:default_prompt)}
        it "merges!" do
          cli.default!(banana: true)
          expect(cli.default).to include(:banana)
        end
      end
    end

    context '#host' do
      it "checks net_ssh" do
        expect(cli.host).to eq("localhost")
      end
      it "#hostname" do
        expect(cli.hostname).to eq("localhost")
      end
      it "#to_s" do
        expect(cli.to_s).to eq("localhost")
      end
      it "#ip" do
        expect(cli.ip).to eq(nil)
      end
    end

    context '#detect_prompt' do
      it "detects the prompt" do
        cli.stdout << "welcome!\n\nasdf\n\nthe_prompt"
        expect(cli.detect_prompt).to eq("\nthe_prompt")
        expect(cli.default_prompt).to eq("\nthe_prompt")
      end
      it "detects the strange prompt" do
        cli.stdout << "welcome!\n\nasdf\n\nthe_!@#U$:>\""
        expect(cli.detect_prompt).to eq("\nthe_!@#U$:>\"")
      end
    end

    context 'low level' do
      context '#stdout!' do
        it 'returns the value and emptries it' do
          cli.stdout = "asdf"
          expect(cli.stdout!).to eq("asdf")
          expect(cli.stdout).to eq("")
        end
      end

      context '#stderr!' do
        it 'returns the value and emptries it' do
          cli.stderr = "asdf"
          expect(cli.stderr!).to eq("asdf")
          expect(cli.stderr).to eq("")
        end
      end

      context '#read' do
        it 'reads the stdout var' do
          cli.stdout = 'asdf'
          expect(cli.read).to eq('asdf')
        end
        it 'empties the stdout after read' do
          cli.stdout << 'asdf'
          expect(cli.read).to eq('asdf')
          expect(cli.read).to eq('')
        end
      end

      context '#write' do
        it 'returns the value' do
          expect(cli.write('asdf')).to eq('asdf')
        end
      end

      context '#write_n' do
        it 'returns the value' do
          expect(cli.write_n('asdf')).to eq("asdf\n")
        end
      end
      
      context '#process_stdout' do
        it 'returns the value' do
          cli.stdout = "qwer"
          a_proc = Proc.new {} 
          cli.process_stdout_procs = {one: a_proc}
          expect(a_proc).to receive(:call)
          expect(cli.process_stdout('asdf')).to eq("qwerasdf")
        end
      end

      context '#process_stderr' do
        it 'returns the value' do
          cli.stderr = "qwer"
          a_proc = Proc.new {} 
          cli.process_stderr_procs = {one: a_proc}
          expect(a_proc).to receive(:call)
          expect(cli.process_stderr('asdf', 0)).to eq("qwerasdf")
        end
      end
    end

    context 'fancy prompt parsing' do
      before { allow(cli).to receive(:read) { 'the_prompt' } }
      context '#read_till' do
        it 'reads till the prompt matches' do
          cli.stdout = 'the_prompt'
          expect(cli.read_till).to eq('the_prompt')
        end
        it 'has a timeout' do
        end
      end

      context '#cmd' do
        before { allow(cli).to receive(:read_till) { "command\noutput\nthe_prompt" } }
        it 'sends a command and waits for a prompt' do
          expect(cli).to receive(:read)
          expect(cli).to receive(:write_n)
          expect(cli.cmd('command')).to eq("command\noutput\nthe_prompt")
        end

        it 'deletes the cmd' do
          expect(cli.cmd('command', rm_cmd: true)).to eq("output\nthe_prompt")
        end
        context 'deletes the prompt' do
          it 'with a string prompt' do
            expect(cli.cmd('command', rm_prompt: true)).to eq("command\noutput\n")
          end
          it 'with a regexp prompt' do
            allow(cli).to receive(:read) { /(the_prompt)/ }
            expect(cli.cmd('command', rm_prompt: true)).to eq("command\noutput\n")
          end
        end
        it 'deletes the cmd and the prompt' do
          expect(cli.cmd('command', rm_cmd: true, rm_prompt: true)).to eq("output\n")
        end
      end

      context "#cmds" do
        before { allow(cli).to receive(:read_till) { "command\nthe_prompt" } }
        it "returns a hash" do
          expect(cli.cmds([])).to eq([])
          expect(cli.cmds(["command", "command"])).to eq([["command", "command\nthe_prompt"],["command", "command\nthe_prompt"]])
        end
      end

      context '#dialog' do
        before { allow(cli).to receive(:read_till) { "command\noutput\nthe_dialog_prompt" } }
        it 'sends a command and waits for a prompt' do
          expect(cli).to receive(:read)
          expect(cli).to receive(:write)
          expect(cli.dialog('command', /(the_dialog_prompt)/)).to eq("command\noutput\nthe_dialog_prompt")
        end
        it 'deletes the cmd and the prompt' do
          expect(cli.dialog('command', /(the_dialog_prompt)/, rm_cmd: true, rm_prompt: true)).to eq("output\n")
        end
      end

      context '#read_for' do
        it 'sends a command and waits for a prompt' do
          allow(cli).to receive(:sleep) {true}
          allow(cli).to receive(:read) {"asdf"}
          expect(cli).to receive(:read)
          expect(cli).to receive(:sleep).with(5)
          expect(cli.read_for(seconds: 5)).to eq("asdf")
        end
      end
    end
  end
end
