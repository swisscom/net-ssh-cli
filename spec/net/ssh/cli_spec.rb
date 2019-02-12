require 'ostruct'
RSpec.describe Net::SSH::CLI do
  it "has a version number" do
    expect(Net::SSH::CLI::VERSION).not_to be nil
  end

  describe "fake Socket" do
    let(:default_prompt) {"@"}
    let(:cli) {Net::SSH::CLI::Channel.new(default_prompt: default_prompt)}
    let(:channel) {OpenStruct.new}
    before {allow(cli).to receive(:process) {|args| true}}
    before {allow(cli).to receive(:process) {true}}
    before {allow(cli).to receive(:net_ssh) {true}}
    before {allow(cli).to receive(:open_channel) {true}}
    before {allow(cli).to receive(:channel) {channel}}
    before {allow(cli).to receive(:write)   {|args| cli.process_stdout(args)}}
    before {allow(channel).to receive(:send_data) {|args| cli.process_stdout(args)}}

    context "low level" do
      context "#read" do
        it "reads the stdout var" do
          cli.stdout = "asdf"
          expect(cli.read).to eq("asdf")
        end
        it "empties the stdout after read" do
          cli.stdout << "asdf"
          expect(cli.read).to eq("asdf")
          expect(cli.read).to eq("")
        end
      end

      context "#write" do
        it "returns the value" do
          expect(cli.write("asdf")).to eq("asdf")
        end
      end

      context "#write_n" do
        it "returns the value" do
          expect(cli.write_n("asdf")).to eq("asdf\n")
        end
      end
    end

    context "fancy prompt parsing" do
      before {allow(cli).to receive(:read) {"@"}}
      context "#read_till" do
        it "reads till the prompt matches" do
          cli.stdout = "@"
          expect(cli.read_till).to eq("@")
        end
        it "has a timeout" do
        end
      end

      context "#cmd" do
        before {allow(cli).to receive(:read_till) {"bananas\noranges\n@"}}
        it "sends a command and waits for a prompt" do
          expect(cli).to receive(:read)
          expect(cli).to receive(:write_n)
          expect(cli.cmd "bananas").to eq("bananas\noranges\n@")
        end
        
        it "deletes the cmd" do
          expect(cli.cmd "bananas", rm_cmd: true).to eq("oranges\n@")
        end
        context "deletes the prompt" do
          it "with a string prompt" do
            expect(cli.cmd "bananas", rm_prompt: true).to eq("bananas\noranges\n")
          end
          it "with a regexp prompt" do
            allow(cli).to receive(:read) {/(@)/}
            expect(cli.cmd "bananas", rm_prompt: true).to eq("bananas\noranges\n")
          end
        end
        it "deletes the cmd and the prompt" do
          expect(cli.cmd "bananas", rm_cmd: true, rm_prompt: true).to eq("oranges\n")
        end
      end
    end
  end
end
