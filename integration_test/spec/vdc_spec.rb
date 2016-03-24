require_relative 'spec_helper'

require 'aws-sdk'

describe "vdc" do
  before(:all) do
    generate_builder_file(:vdc, false)
    generate_builder_config(:vdc, false)
  end

  after(:all) do
    config = Builder.config
    vpc_info = Builder.recipe[:vpc_info]
    nodes = Builder.recipe[:nodes]
    networks = Builder.recipe[:networks]

    ::Aws.config.update({
      region: config[:aws_region],
      credentials: ::Aws::Credentials.new(config[:aws_access_key], config[:aws_secret_key])
    })
    ec2 = ::Aws::EC2::Client.new

    [nodes[:dcmgr][:provision][:spec][:instance_id], Builder.recipe[:vpc_info][:instance_id]].each do |instance_id|
      instance = ::Aws::EC2::Instance.new(id: instance_id)
      instance.terminate
      instance.wait_until_terminated
    end

    ec2.delete_security_group(group_id: vpc_info[:secg_id])
    ec2.disassociate_route_table(association_id: vpc_info[:association_id])
    ec2.detach_internet_gateway(internet_gateway_id: vpc_info[:igw_id], vpc_id: vpc_info[:vpc_id])
    ec2.delete_internet_gateway(internet_gateway_id: vpc_info[:igw_id])
    ec2.delete_subnet(subnet_id: networks[:aws][:subnet_id])
    ec2.delete_vpc(vpc_id: vpc_info[:vpc_id])
  end

  subject { Builder::Cli::Root.new }

  let(:name) { :dcmgr }
  let(:config) { Builder.config }

  let(:nodes) { Builder.recipe[:nodes] }
  let(:networks) { Builder.recipe[:networks] }

  it "vdc" do
    subject.invoke(:exec)
    expect(ping_to(nodes[name][:ssh][:ip])).to eq true
  end
end
