# frozen_string_literal: false

require 'ostruct'

RSpec.describe Net::SSH::CLI do
  it 'has a version number' do
    expect(Net::SSH::CLI::VERSION).not_to be nil
  end

  describe 'initializes nicely' do
    let(:cli) { Net::SSH::CLI::Session.new }
    it { expect(cli.stdout).to eq('') }
    it { expect(Net::SSH::CLI::OPTIONS).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.options).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.net_ssh_options).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.before_on_stdout_procs).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.after_on_stdout_procs).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.before_open_channel_procs).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.after_open_channel_procs).to be_a(ActiveSupport::HashWithIndifferentAccess) }
    it { expect(cli.logger).to be_a(Logger) }
  end

  describe 'fake Socket' do
    let(:default_prompt) { 'the_prompt' }
    let(:channel) { double(Net::SSH::Connection::Channel) }
    let(:net_ssh) { double(Net::SSH) }
    let(:cli) { Net::SSH::CLI::Session.new(default_prompt: default_prompt, net_ssh: net_ssh) }
    before(:each) { allow(cli).to receive(:open_channel) {} }
    before(:each) { allow(cli).to receive(:channel) { channel } }
    before(:each) { allow(cli).to receive(:process) { true } }
    before(:each) { allow(channel).to receive(:send_data) { true } }
    before(:each) { allow(net_ssh).to receive(:host) { 'localhost' } }

    context 'configuration' do
      context '#options' do
        let(:cli) { Net::SSH::CLI::Session.new(default_prompt: default_prompt, net_ssh: net_ssh) }
        it { expect(cli.options).to be_a(Hash) }
        it { expect(cli.options).to be_a(ActiveSupport::HashWithIndifferentAccess) }
        it { expect(cli.options).to include(:process_time) }
        it { expect(cli.options!(banana: true)).to include(:banana) }
        it { expect(cli.options = {}).to eq({}) }
      end
    end

    context '#host' do
      it 'checks net_ssh' do
        expect(cli.host).to eq('localhost')
      end
      it '#hostname' do
        expect(cli.hostname).to eq('localhost')
      end
      it '#to_s' do
        expect(cli.to_s).to eq('localhost')
      end
    end

    context '#detect_prompt' do
      it 'detects the prompt' do
        cli.stdout << "welcome!\n\nasdf\n\nthe_prompt"
        expect(cli.detect_prompt(seconds: 0.1)).to eq("\nthe_prompt")
        expect(cli.default_prompt).to eq("\nthe_prompt")
      end
      it 'detects the strange prompt' do
        cli.stdout << "welcome!\n\nasdf\n\nthe_!@#U$:>\""
        expect(cli.detect_prompt(seconds: 0.1)).to eq("\nthe_!@#U$:>\"")
      end
    end

    context 'low level' do
      context '#stdout!' do
        it 'returns the value and emptries it' do
          cli.stdout = 'asdf'
          expect(cli.stdout!).to eq('asdf')
          expect(cli.stdout).to eq('')
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

      context '#on_stdout' do
        let(:cli) { Net::SSH::CLI::Session.new(default_prompt: default_prompt, net_ssh: net_ssh, after_on_stdout_procs: {one: Proc.new {stdout.gsub!("as", "df")}}) }
        it 'returns the value' do
          cli.stdout = 'qwer'
          expect(cli.on_stdout('asdf')).to eq('qwerdfdf')
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
          cli.stdout = 'you never find me'
          expect {cli.read_till(timeout: 0.01)}.to raise_error(Net::SSH::CLI::Error::ReadTillTimeout)
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

      context '#cmds' do
        before { allow(cli).to receive(:read_till) { "command\nthe_prompt" } }
        it 'returns a hash' do
          expect(cli.cmds([])).to eq([])
          expect(cli.cmds(%w[command command])).to eq([%W[command command\nthe_prompt], %W[command command\nthe_prompt]])
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
    
      context '#impact' do
        before { allow(cli).to receive(:cmd) { "command\nthe_prompt" } }
        
        it 'doesn\'t a command if impact is false' do
          cli.run_impact = false
          expect(cli).not_to receive(:cmd)
          expect(cli.impact("_reboot_")).to match(/skip/)
        end
        it 'sends a command if impact is true' do
          cli.run_impact = true
          expect(cli).to receive(:cmd)
          cli.impact("_reboot_")
        end

      end

      context '#read_for' do
        it 'sends a command and waits for a prompt' do
          expect(cli.read_for(seconds: 5)).to eq('the_prompt')
        end
      end

      context '#default_prompt' do
        it 'can be a string' do
          expect(cli.default_prompt).to eq('the_prompt')
        end
      end

      context '#with_prompt' do
        it 'yields the new prompt' do
          expect(cli.default_prompt).to eq('the_prompt')
          expect(cli.current_prompt).to eq('the_prompt')
          cli.with_prompt('root@server') do
            expect(cli.current_prompt).to eq('root@server')
          end
          expect(cli.default_prompt).to eq('the_prompt')
          expect(cli.current_prompt).to eq('the_prompt')
        end
      end

      context '#with_named_prompt' do
        it 'yields the new prompt' do
          cli.named_prompts['root'] = 'root@server'
          expect(cli.default_prompt).to eq('the_prompt')
          expect(cli.current_prompt).to eq('the_prompt')
          cli.with_named_prompt('root') do
            expect(cli.current_prompt).to eq('root@server')
          end
          expect(cli.default_prompt).to eq('the_prompt')
          expect(cli.current_prompt).to eq('the_prompt')
        end
      end
    end
  end
end
