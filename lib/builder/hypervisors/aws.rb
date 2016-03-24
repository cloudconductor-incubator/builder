require 'builder'
require 'aws-sdk'
require 'base64'
require 'net/ssh'
require 'net/scp'
require 'ipaddr'

module Builder::Hypervisors
  class Aws
    class << self
      include Builder::Helpers::Config
      include Builder::Helpers::Logger

      def provision(node_name)
        node = db[:nodes][node_name]

        ::Aws.config.update({
          region: config[:region],
          credentials: ::Aws::Credentials.new( ENV['ACCESS_KEY'] || config[:access_key], ENV['SECRET_KEY'] || config[:secret_key] )
        })
        ec2 = ::Aws::EC2::Client.new

        vpc_id = config[:vpc_id] || ""
        subnet_id = config[:subnet_id] || ""
        route_table_id = config[:route_table_id] || ""
        igw_id = config[:igw_id] || ""
        secg_id = config[:secg_id] || ""

        vpc_cidr = config[:vpc_cidr]
        subnet_cidr = config[:subnet_cidr]

        image_id = config[:ami]

        if vpc_id == ""
          vpc_id = ec2.create_vpc(
            cidr_block: vpc_cidr,
            instance_tenancy: "default",
          ).vpc.vpc_id
          info "Create VPC #{vpc_id}"
        end
        vpc = ::Aws::EC2::Vpc.new(id: vpc_id)

        if subnet_id == ""
          subnet_id = ec2.create_subnet(
            vpc_id: vpc_id,
            cidr_block: subnet_cidr,
          ).subnet.subnet_id
          info "Create subnet #{subnet_id}"
        end
        subnet = ::Aws::EC2::Subnet.new(id: subnet_id)

        if route_table_id == ""
          route_table_id = ec2.describe_route_tables(
            filters: [
              { name: "vpc-id", values: [vpc_id] }
            ]
          ).route_tables.first.route_table_id
          info "Create route table #{route_table_id}"
        end

        ec2.associate_route_table({
          subnet_id: subnet_id,
          route_table_id: route_table_id
        })

        if igw_id == ""
          igw_id = ec2.create_internet_gateway.internet_gateway.internet_gateway_id
          info "Create igw #{igw_id}"
        end
        igw = ::Aws::EC2::InternetGateway.new(id: igw_id)

        if igw.attachments.empty?
          ec2.attach_internet_gateway({
            internet_gateway_id: igw_id,
            vpc_id: vpc_id
          })
        end

        ec2.create_route({
          route_table_id: route_table_id,
          destination_cidr_block: '0.0.0.0/0',
          gateway_id: igw_id
        })

        if secg_id == ""
          secg_id = ec2.create_security_group({
            group_name: config[:group_name],
            description: config[:secg_description],
            vpc_id: vpc_id
          }).group_id
          info "Create secg #{secg_id}"
        end
        secg = ::Aws::EC2::SecurityGroup.new(id: secg_id)

        if secg.data.ip_permissions.empty?
          secg.authorize_ingress(ip_permissions: [{ip_protocol: "-1", from_port: nil, to_port: nil, user_id_group_pairs: [{group_id: "#{secg.id}"}]}])

          config[:global_cidrs].each do |global_cidr|
            secg.authorize_ingress(ip_permissions: [{ip_protocol: "-1", from_port: nil, to_port: nil, ip_ranges: [{cidr_ip: "#{global_cidr}"}]}])
            secg.authorize_egress(ip_permissions: [{ip_protocol: "-1", from_port: nil, to_port: nil, ip_ranges: [{cidr_ip: "#{global_cidr}"}]}])
          end
        end
        secg.load
        info "Create rules #{secg.data}"

        instance_id = instance_id = ec2.run_instances({
          image_id: image_id,
          min_count: 1,
          max_count: 1,
          key_name: node[:provision][:spec][:key_pair],
          instance_type: node[:provision][:spec][:instance_type],
          network_interfaces: [
            { device_index: 0, associate_public_ip_address: true, subnet_id: subnet_id, groups: [secg_id] }
          ]
        }).instances.first.instance_id
        i = ::Aws::EC2::Instance.new(id: instance_id)
        info "Create instance #{instance_id}"
        i.wait_until_running

        ec2.wait_until(:instance_status_ok, instance_ids:[instance_id]) do |w|
          w.before_attempt do |n|
            info "wait until 'instance_status_ok' for #{instance_id} (#{n})"
          end
        end

        ec2.wait_until(:system_status_ok, instance_ids:[instance_id]) do |w|
          w.before_attempt do |n|
            info "wait until 'system_status_ok' for #{instance_id} (#{n})"
          end
        end

        node[:provision][:spec][:instance_id] = i.id
        node[:provision][:spec][:public_ip_address] = i.data.public_ip_address
        node[:provision][:spec][:nics][:eth0][:ipaddr] = i.data.private_ip_address
        node[:ssh][:ip] = i.data.public_ip_address
        node[:provision][:spec][:subnet] = subnet.id

        config[:security_groups] = i.data.security_groups.map(&:group_id)

        Net::SCP.start(node[:ssh][:ip], node[:ssh][:user], :keys => [ node[:ssh][:key] ]) do |scp|
          scp.upload!(node[:provision][:script], "/home/ec2-user/")

          if node[:provision][:spec].include?(:netjoin)
            ips = eval(`netjoin show_ip aws`)

            node_ip = node[:provision][:spec][:nics][node[:provision][:spec][:netjoin].to_sym][:ipaddr]
            ips_map = ips.map {|ip| IPAddr.new("#{ip}/24") }
            index = ips_map.index(ips_map.select {|i| i.to_i == IPAddr.new("#{node_ip}/24").to_i }.first)

            File.open("netjoin_ip", "w") do |f|
              f.write ips[index]
            end

            scp.upload!("netjoin_ip", "/home/ec2-user/")
            FileUtils.rm("netjoin_ip")

            system("netjoin setup_tunnel aws #{node_ip}")
          end
        end

        Net::SSH.start(node[:ssh][:ip], node[:ssh][:user], :keys => [ node[:ssh][:key] ]) do |ssh|
          ssh_exec(ssh, [
            "chmod +x /home/ec2-user/*.sh",
            "sudo /home/ec2-user/#{node[:provision][:script].gsub(/.*\//, '')} | tee -a /home/ec2-user/#{node[:provision][:script].gsub(/.*\//, '')}.log"
          ])
        end

        node[:provision][:provisioned] = true

        File.open("builder.yml", "w") do |f|
          f.write db.stringify_keys.to_yaml
        end

        File.open(".builder", "w") do |f|
          f.write config.stringify_keys.to_yaml
        end
      end
    end
  end
end
