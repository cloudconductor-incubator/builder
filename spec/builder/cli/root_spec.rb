require 'spec_helper'
require 'net/ssh'

describe Builder::Cli::Root do

  before do
    generate_builder_file(:vdc)
    generate_builder_config(:vdc)
  end

  subject { Builder::Cli::Root.new }

  describe "init" do
    it "creates .builder and builder.yml file" do
      subject.invoke(:init)
      expect(File.exist?(".builder")).to eq true
      expect(File.exist?("builder.yml")).to eq true
    end
  end

  describe "load_conf" do
    it "loads builder conf files" do
      expect(Builder.recipe).not_to eq nil
    end
  end
end
