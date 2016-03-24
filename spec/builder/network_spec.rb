require 'spec_helper'

describe Builder::Networks do

  before do
    generate_builder_file(:vdc)
    generate_builder_config(:vdc)
    Builder::Cli::Root.new
  end

  subject { Builder::Networks }

  let(:networks) { Builder.recipe[:networks] }

  describe "provision" do
    it "creates and configures bridges as written in builder.yml" do

      networks.each do |k, v|
        allow(subject).to receive(:system).with(/add/).and_return(true)
        allow(subject).to receive(:system).with(/ip/).and_return(true)

        if v[:ipv4_gateway]
          allow(subject).to receive(:system)
            .with(/ip addr add #{v[:ipv4_gateway]}\/#{v[:prefix]} dev #{v[:bridge_name]}/)
            .and_return(true)
        end
      end

      expect {
        subject.send(:_provision, :linux)
      }.not_to raise_error
    end
  end
end
