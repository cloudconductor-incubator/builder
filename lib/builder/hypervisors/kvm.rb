require 'builder'

require 'zlib'
require 'archive/tar/minitar'
require 'sshkey'
require 'net/ssh'
require 'net/scp'
require 'ipaddr'

module Builder::Hypervisors
  class Kvm
    class << self
      include Builder::Helpers::Config
      include Builder::Helpers::Logger

      def provision(node_name)
        node = db[:nodes][node_name]


        if node[:ssh].key?(:from)

          parent_name = node[:ssh][:from].to_sym
          parent = db[:nodes][parent_name]

          if parent[:ssh].key?(:sudo_password) && parent[:ssh][:sudo_password] == true
            info "Enter password: "
            password = STDIN.noecho(&:gets).chomp
          end

          work_dir = if parent[:ssh][:user] == 'root'
                       "/root/builder_workspace"
                     else
                       "/home/#{parent[:ssh][:user]}/builder_workspace"
                     end

          kvm_dir        = work_dir + "/" + node_name.to_s
          kvm_rootfs_dir = work_dir + "/" + node_name.to_s + "/rootfs"

          k = SSHKey.new(File.read(node[:ssh][:key]))

          Net::SSH.start(parent[:ssh][:ip], parent[:ssh][:user], :keys => [ parent[:ssh][:key] ]) do |ssh|

            commands = []
            commands << "mkdir -p #{work_dir} || :"
            commands << "mkdir -p #{kvm_dir} || :"
            commands << "mkdir -p #{kvm_rootfs_dir} || :"
            commands << "mkdir -p #{kvm_rootfs_dir}/etc/sysconfig/network-scripts/ || :"
            commands << "mkdir -p #{kvm_rootfs_dir}/root/ || :"
            commands << "mkdir -p #{kvm_rootfs_dir}/root/.ssh || :"
            commands << "mkdir -p #{kvm_rootfs_dir}/metadata/ || :"

            ssh_exec(ssh, commands)
          end

          f_mac = File.open("macaddress", "w")
          f_bridge = File.open("bridge", "w")

          nic_num = 0
          node[:provision][:spec][:nics].each do |key, value|
            f_mac.puts value[:mac_address]
            f_bridge.puts db[:networks][value[:network].to_sym][:bridge_name]

            ifcfg_file = File.open("ifcfg-eth#{nic_num}", "w")

            value.each do |k, v|
              next if k == :network
              next if k == :mac_address
              ifcfg_file.puts "#{k.to_s.upcase}=#{v}"
            end

            ifcfg_file.close
            nic_num = nic_num + 1
          end

          f_mac.close
          f_bridge.close


          Net::SCP.start(parent[:ssh][:ip], parent[:ssh][:user], :keys => [ parent[:ssh][:key] ]) do |scp|
            scp.upload!("#{Builder::ROOT}/builder_scripts/seed_download.sh", work_dir)
            scp.upload!("#{Builder::ROOT}/builder_scripts/kvm.sh", kvm_dir)
            scp.upload!("#{Builder::ROOT}/builder_scripts/firstboot.sh", "#{kvm_rootfs_dir}/root")
            scp.upload!("#{node[:provision][:script]}", kvm_rootfs_dir)

            scp.upload!("macaddress", kvm_dir)
            scp.upload!("bridge", kvm_dir)

            for i in 0..nic_num-1
              scp.upload("ifcfg-eth#{i}", "#{kvm_rootfs_dir}/etc/sysconfig/network-scripts/")
            end

            if node[:provision][:spec].include?(:netjoin)
              ips = eval(`netjoin show_ip kvm`)

              node_ip = node[:provision][:spec][:nics][node[:provision][:spec][:netjoin].to_sym][:ipaddr]
              ips_map = ips.map {|ip| IPAddr.new("#{ip}/24") }
              index = ips_map.index(ips_map.select {|i| i.to_i == IPAddr.new("#{node_ip}/24").to_i }.first)

              File.open("netjoin_ip", "w") do |f|
                f.write ips[index]
              end

              scp.upload!("netjoin_ip", "#{kvm_rootfs_dir}/metadata/")
              FileUtils.rm("netjoin_ip")

              info "netjoin setup_tunnel kvm #{node_ip}"
              system("netjoin setup_tunnel kvm #{node_ip}")
            end

            k = SSHKey.new(File.read(node[:ssh][:key]))
            File.open("authorized_keys", "w") do |f|
              f.write k.ssh_public_key
            end
            scp.upload!("authorized_keys", "#{kvm_rootfs_dir}/root/.ssh")
            FileUtils.rm("authorized_keys")
          end

          FileUtils.rm("macaddress")
          FileUtils.rm("bridge")

          for i in 0..nic_num-1
            FileUtils.rm("ifcfg-eth#{i}")
          end

          Net::SSH.start(parent[:ssh][:ip], parent[:ssh][:user], :keys => [ parent[:ssh][:key] ]) do |ssh|
            ssh_exec(ssh, [
              "chmod +x #{work_dir}/*.sh",
              "chmod +x #{kvm_dir}/*.sh",
              "chmod +x #{kvm_rootfs_dir}/*.sh",
              "chmod +x #{kvm_rootfs_dir}/root/*.sh",
              "chmod 700 #{kvm_rootfs_dir}/root/.ssh",
              "chmod 600 #{kvm_rootfs_dir}/root/.ssh/authorized_keys",
              "sudo chown #{node[:ssh][:user]}.#{node[:ssh][:user]} #{kvm_dir}/*.sh",
              "#{work_dir}/seed_download.sh",
            ])

            ssh_exec(ssh,[
              "sudo #{kvm_dir}/kvm.sh #{node_name.to_s} \
              #{node[:provision][:spec][:disk]} \
              #{node[:provision][:spec][:memory]}"
            ])
          end

        elsif node.parent == 'self'
          info "self"
        else
          error 'specify node.parent'
          return
        end

        node[:provision][:provisioned] = true

        File.open("builder.yml", "w") do |f|
          f.write db.stringify_keys.to_yaml
        end
      end

    end
  end
end
