require 'builder'
require 'aws-sdk'
require 'ipaddr'
require 'base64'
require 'net/ssh'
require 'net/ssh/proxy/command'

module Builder
  class Networks
    class << self
      include Builder::Helpers::Config
      include Builder::Helpers::Logger

      def provision
        @vpn_setup_flags = {}

        types = []
        Builder.recipe[:networks].map {|k, v| types << v[:network_type] }
        if types.uniq.size > 1
          types.each {|type| @vpn_setup_flags[type.to_sym] = true }
        end

        _provision(:all)

        if @vpn_setup_flags[:linux]
          expected_nodes = Builder.recipe[:nodes].select {|k,v| !v.include?(:provision) }

          linux_networks = Builder.recipe[:networks].select {|k,v| v[:network_type] == "linux" }
          nics = {}
          i = 0
          ssh_ip = nil
          linux_networks.each do |k, v|
            key = "eth#{i}"

            _ip = IPAddr.new("#{v[:ipv4_network]}/#{v[:prefix]}")
            ip = IPAddr.new(_ip.to_i+2, Socket::AF_INET).to_s
            nics[key] = {
              :network => k,
              :device => key,
              :bootproto => "static",
              :onboot => "yes",
              :ipaddr => ip,
              :prefix => v[:prefix],
              :mac_address => "52:54:FF:00:00:#{sprintf("%02d", i)}"
            }

            if v[:ipv4_gateway]
              nics[key][:gateway] = v[:ipv4_gateway]
              nics[key][:defroute] = "yes"
              ssh_ip = ip
            end

            i = i + 1
          end

          i = 0
          expected_nodes.each do |k, v|
            name = "vpn#{i}"
            Builder.recipe[:nodes][name] = {
              :provision => {
                :spec => {
                  :type => 'kvm',
                  :disk => 10,
                  :memory => 1000,
                  :nics => nics
                },
                :provisioner => "shell",
                :data => "/path/to/vpn2",
                :user_data => Builder.recipe[:vpc_info][:public_ip_address]
              },
              :ssh => {
                :from => k.to_s,
                :ip => ssh_ip,
                :user => 'root',
                :key => '/path/to/private_key'
              }
            }
          end
          @vpn_setup_flags[:linux] = false
        end
        recipe_save
        config_save
      end

      def mesh_network
        provisioned = Builder.recipe[:nodes].select {|k, v| v.include?(:provision) }
        aws_provisioned = provisioned.select {|k, v| v[:provision][:spec][:type] == "aws" }
        kvm_provisioned = provisioned.select {|k, v| v[:provision][:spec][:type] == "kvm" }

        aws_server_ip = Builder.recipe[:vpc_info][:public_ip_address]
        aws_server_key = Builder.recipe[:vpc_info][:key]

        i = 0
        Net::SSH.start(aws_server_ip, 'ec2-user', :keys => [aws_server_key]) do |ssh|
          commands = []

          aws_provisioned.each do |k, v|
            v[:provision][:spec][:nics].each do |k, v|
              commands << "sudo ovs-vsctl add-port brtun t#{i} -- set interface t#{i} type=gre options:remote_ip=#{v[:ipaddr]}"
              i = i + 1
            end
          end

          ssh_exec(ssh, commands)
        end

        aws_provisioned.each do |k, v|
          commands = []
          Net::SSH.start(v[:ssh][:ip], v[:ssh][:user], :keys => [v[:ssh][:key]]) do |ssh|
            commands << "sudo ovs-vsctl add-port brtun t#{i} -- set interface t#{i} type=gre options:remote_ip=#{Builder.recipe[:vpc_info][:private_ip_address]}"
            ssh_exec(ssh, commands)
          end
        end

        vpn_provisioned = provisioned.select {|k, v| k =~ /vpn/ }
        kvm_provisioned.each do |k, v|
          if v[:ssh].include?(:from)
            parent = Builder.recipe[:nodes][v[:ssh][:from].to_sym]
            proxy = Net::SSH::Proxy::Command.new("
              ssh #{parent[:ssh][:ip]} \
                -l #{parent[:ssh][:user]} \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -W %h:%p -i #{parent[:ssh][:key]}
            ")
            ssh_options = {}
            ssh_options[:keys] = [parent[:ssh][:key]]
            ssh_options[:user_known_hosts_file] = "/dev/null"
            ssh_options[:paranoid] = false
            info "connect to #{k}"
            Net::SSH.start(parent[:ssh][:ip], parent[:ssh][:user], ssh_options) do |ssh|
              wait_port_22(v[:ssh][:ip])
            end
            ssh_options[:proxy] = proxy
            ssh_options[:keys] = [v[:ssh][:key]]
            Net::SSH.start(v[:ssh][:ip], v[:ssh][:user], ssh_options) do |ssh|
              commands = []
              vpn_provisioned.each do |k, v|
                ip = v[:provision][:spec][:nics].values.first[:ipaddr]
                commands << "sudo ovs-vsctl add-port brtun t#{i} -- set interface t#{i} type=gre options:remote_ip=#{ip}"
              end
              ssh_exec(ssh, commands)
              i = i + 1
            end
          else
          end
        end

        vpn_provisioned.each do |k, v|
          if v[:ssh].include?(:from)
            parent = Builder.recipe[:nodes][v[:ssh][:from].to_sym]
            proxy = Net::SSH::Proxy::Command.new("
              ssh #{parent[:ssh][:ip]} \
                -l #{parent[:ssh][:user]} \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -W %h:%p -i #{parent[:ssh][:key]}
            ")
            ssh_options = {}
            ssh_options[:keys] = [parent[:ssh][:key]]
            ssh_options[:user_known_hosts_file] = "/dev/null"
            ssh_options[:paranoid] = false
            info "connect to #{k}"
            Net::SSH.start(parent[:ssh][:ip], parent[:ssh][:user], ssh_options) do |ssh|
              wait_port_22(v[:ssh][:ip])
            end
            ssh_options[:proxy] = proxy
            ssh_options[:keys] = [v[:ssh][:key]]
            Net::SSH.start(v[:ssh][:ip], v[:ssh][:user], ssh_options) do |ssh|
              commands = []
              kvm_provisioned.each do |k, v|
                ip = v[:provision][:spec][:nics].values.first[:ipaddr]
                commands << "sudo ovs-vsctl add-port brtun t#{i} -- set interface t#{i} type=gre options:remote_ip=#{ip}"
              end
              ssh_exec(ssh, commands)
              i = i + 1
            end
          else
          end
        end
      end

      private

      def wait_port_22(ip)
        i = 1
        while true
          if i > 40
            error "timeout"
            raise "ExceedTrial"
          end
          break if `nmap -p 22 #{ip}`.include?("open")
          sleep(1)
          i = i + 1
        end
      end

      def _provision(name)
        if name == :all
          networks.keys.each {|n| _provision(n) }
        else
          network = network_spec(name)
          send("network_#{network[:network_type].to_s}", network)
        end
      end

      def network_linux(network)
        if system("ip link show #{network[:bridge_name]}")
          info "#{network[:network_type]} already exists. skip creation"
        else
          cmd = send("#{network[:network_type].to_s}_addbr")
          system("#{sudo} #{cmd} #{network[:bridge_name]}")
          system("#{sudo} ip link set #{network[:bridge_name]} up")

          if network[:ipv4_gateway]
            system("#{sudo} ip addr add #{network[:ipv4_gateway]}/#{network[:prefix]} dev #{network[:bridge_name]}")
          end

          if network[:masquerade]
            system("#{sudo} iptables -t nat -A POSTROUTING -s #{network[:ipv4_network]}/#{network[:prefix]} -j MASQUERADE")
          end

          info "bridge #{network[:bridge_name]} created"
        end
      end

      def network_aws(n)
        ::Aws.config.update({
          region: config[:aws_region],
          credentials: ::Aws::Credentials.new(config[:aws_access_key], config[:aws_secret_key])
        })
        ec2 = ::Aws::EC2::Client.new

        v = recipe[:vpc_info]
        
        if v[:vpc_id]
          info "Skip vpc creation. already exist #{v[:vpc_id]}"
        else
          raise "InvalidParameter" if n[:prefix] < 8

          network_address = IPAddr.new("#{n[:ipv4_network]}/#{n[:prefix]-8}").to_s
          prefix = n[:prefix] - 8

          v[:vpc_id] = ec2.create_vpc(
              cidr_block: "#{network_address}/#{prefix}",
              instance_tenancy: "default").vpc.vpc_id

          info "Create VPC #{v[:vpc_id]}"
        end


        if n[:subnet_id]
          info "Skip subnet creation. already exist #{n[:subnet_id]}"
        else
          n[:subnet_id] = ec2.create_subnet(
            vpc_id: v[:vpc_id],
            cidr_block: "#{n[:ipv4_network]}/#{n[:prefix]}").subnet.subnet_id

          info "Create subnet #{n[:subnet_id]}"
        end

        if v[:route_table_id]
          info "Skip route_table creation. already exist #{v[:route_table_id]}"
        else
          v[:route_table_id] = ec2.describe_route_tables(
            filters: [
              { name: "vpc-id", values: [v[:vpc_id]] }
            ]
          ).route_tables.first.route_table_id

          info "Create route table #{v[:route_table_id]}"

          v[:association_id] = ec2.associate_route_table({
            subnet_id: n[:subnet_id],
            route_table_id: v[:route_table_id]
          }).association_id
        end


        if v[:igw_id]
          info "Skip igw creation. already exist #{v[:igw_id]}"
        else
          v[:igw_id] = ec2.create_internet_gateway.internet_gateway.internet_gateway_id

          ec2.attach_internet_gateway({
            internet_gateway_id: v[:igw_id],
            vpc_id: v[:vpc_id]
          })

          ec2.create_route({
            route_table_id: v[:route_table_id],
            destination_cidr_block: '0.0.0.0/0',
            gateway_id: v[:igw_id]
          })

          info "Create igw #{v[:igw_id]}"
        end


        if v[:secg_id]
          info "Skip secg creation. already exist #{v[:secg_id]}"
        else
          v[:secg_id] = ec2.create_security_group({
            group_name: v[:name],
            description: v[:name],
            vpc_id: v[:vpc_id]
          }).group_id

          secg = ::Aws::EC2::SecurityGroup.new(id: v[:secg_id])

          if secg.data.ip_permissions.empty?
            secg.authorize_ingress(ip_permissions: [{ip_protocol: "-1", from_port: nil, to_port: nil, user_id_group_pairs: [{group_id: "#{v[:secg_id]}"}]}])

            config[:global_cidrs].each do |global_cidr|
              secg.authorize_ingress(ip_permissions: [{ip_protocol: "-1", from_port: nil, to_port: nil, ip_ranges: [{cidr_ip: "#{global_cidr}"}]}])
              secg.authorize_egress(ip_permissions: [{ip_protocol: "-1", from_port: nil, to_port: nil, ip_ranges: [{cidr_ip: "#{global_cidr}"}]}])
            end
          end
          secg.load
          info "Create secg #{v[:secg_id]}"

          if @vpn_setup_flags[:aws]
            nics = [{ 
              :device_index => 0,
              :subnet_id => n[:subnet_id],
              :groups => [v[:secg_id]],
              :associate_public_ip_address => true,
            }]

            user_data = Base64.encode64(File.read("/path/to/vpn"))

            id = ec2.run_instances({
              image_id: v[:image_id],
              user_data: user_data,
              min_count: 1,
              max_count: 1,
              key_name: v[:key_pair],
              instance_type: 't2.micro',
              network_interfaces: nics
            }).instances.first.instance_id

            i = ::Aws::EC2::Instance.new(id: id)
            info "Create instance #{id}"
            i.wait_until_running

            v[:instance_id] = id
            v[:public_ip_address] = i.public_ip_address
            v[:private_ip_address] = i.network_interfaces.first.private_ip_address
            @vpn_setup_flags[:aws] = false
          end
        end
        recipe_save
        config_save
      end


      def ssh_exec(ssh, commands)
        ssh.open_channel do |ch|
          ch.request_pty do |ch, success|
            ch.exec commands.join(';') do |ch, success|
              ch.on_data do |ch, data|
                data.chomp.split("\n").each { |d| info d }
              end
            end
          end
        end
      end

      def sudo
        `whoami` =~ /root/ ? '' : 'sudo'
      end

      def ovs_addbr
        "ovs-vsctl add-br"
      end

      def linux_addbr
        "brctl addbr"
      end
    end
  end
end
