RSpec.describe Net::SSH::CLI do
  it "has a version number" do
    expect(Net::SSH::CLI::VERSION).not_to be nil
  end

  context "#cmd" do
    let(:cli) {Net::SSH::CLI::Host.new(host: "localhost", default_match: "ok")}
    it "#cmd" do
      allow(cli).to receive(:read).and_return "ok"
      allow(cli).to receive(:write).and_return "ok"
      expect(cli.cmd "").to eq("ok")
    end
  end
end
