require 'spec_helper'

describe Builder::Nodes do
  before do
    generate_builder_file(:vdc)
  end

  describe "list_to_provision" do
    it "lists nodes to provision" do
      expect(Builder::Nodes.list_to_provision).to eq [:dcmgr, :hva, :wanedge]
    end
  end

  describe "provision" do

    before do
      allow(Builder::Hypervisors::Kvm).to receive(:provision).with(:hva).and_return(true)
    end

    it "selects provisioner" do
      expect(Builder::Nodes.provision(:hva)).to eq true
    end
  end
end
