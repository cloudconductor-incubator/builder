require 'spec_helper'

describe Builder::Hypervisors::Kvm do
  before do
    generate_builder_file(:vdc)
    generate_builder_config(:vdc)
    Builder::Cli::Root.new
  end

  subject { Builder::Hypervisors::Kvm }

  let(:config) { Builder.config }
  let(:nodes) { Builder.recipe[:nodes] }
  let(:node_spec) { nodes[name][:spec] }
  let(:name) { :dcmgr }

  describe "provision" do

    let(:node_dir) { "#{config[:builder_root]}/#{name.to_s}" } 
    let(:node_image_path) { "#{node_dir}/#{name.to_s}.raw" }
    let(:nics) { nodes[:dcmgr][:provision][:spec][:nics] }

    it "creates a directory with node's name" do
      mkdir_cmd = "mkdir -p #{node_dir}"
      expect(subject).to receive(:system).with(mkdir_cmd)
      subject.send(:create_node_dir, node_dir)
    end

    it "downloads seed image" do
      curl_cmd = "curl -L #{config[:seed_image_url]} -o #{config[:seed_image_path]}"
      allow(subject).to receive(:system).with(curl_cmd).and_return(true)
      subject.send(:download_seed_image)
    end

    it "extracs seed image to node's directory" do

      zlib_mock = double('zlib')

      allow(Zlib::GzipReader).to receive(:open).with(config[:seed_image_path]).and_return(zlib_mock)
      allow(Archive::Tar::Minitar).to receive(:unpack).with(zlib_mock, node_dir).and_return(true)

      raw_file_mock = double('raw_file')
      allow(raw_file_mock).to receive(:select).with(no_args).and_return(['dcmgr.raw'])
      allow(Dir).to receive(:entries).with(anything).and_return(raw_file_mock)

      allow(subject).to receive(:system).with(anything).and_return(true)

      expect {
        subject.send(:extract_seed_image, node_dir, node_image_path)
      }.not_to raise_error
    end

    it "creates ifcfg-xxx files according to node's spec" do
      nics = nodes[:dcmgr][:provision][:spec][:nics]

      mkdir_cmd = "mkdir -p #{node_dir}/mnt"
      mount_cmd = "mount -o loop,offset=32256 #{node_image_path} #{node_dir}/mnt"
      umount_cmd= "umount #{node_dir}/mnt"

      allow(subject).to receive(:system).with(mkdir_cmd)
      allow(subject).to receive(:system).with(/#{mount_cmd}/)

      nics.keys.each do |nic|
        allow(File).to receive(:open)
          .with("#{node_dir}/ifcfg-#{nic}", "w")
        allow(subject).to receive(:system).with(/mv/)
      end

      allow(subject).to receive(:system).with(/#{umount_cmd}/)

      expect{
        subject.send(:create_nics, nics, node_dir, node_image_path)
      }.not_to raise_error
    end

    it "creates runscript" do
      expect(File).to receive(:exist?).with("/usr/libexec/qemu-kvm").and_return(true)

      expect(File).to receive(:open).at_least(:once)
        .with("#{node_dir}/run.sh", "w")

      expect(subject).to receive(:system).with(anything).and_return(true)

      expect {
        subject.send(:create_runscript, name, node_dir, node_spec)
      }.not_to raise_error
    end

    it "creates authorized_keys file" do

      allow(File).to receive(:read).with(anything).and_return(true)
      allow(Dir).to receive(:exist)

      allow(subject).to receive(:system).at_most(3).and_return(true)

      key_mock = double(:key)
      allow(key_mock).to receive(:ssh_public_key).and_return("ssh_public_key")
      allow(SSHKey).to receive(:new).and_return(key_mock)

      file_mock = double(:file)
      allow(file_mock).to receive(:puts).with("ssh_public_key")
      allow(File).to receive(:open).with(any_args).and_return(file_mock)

      expect {
        subject.send(:install_ssh_key, nodes[name][:ssh][:key], node_dir, node_image_path)
      }.not_to raise_error
    end
  end

  describe "launch" do
    it "launches kvm" do
      allow(subject).to receive(:system).with(/run\.sh/).and_return(true)

      expect {
        subject.send(:launch, name)
      }.not_to raise_error
    end
  end
end
