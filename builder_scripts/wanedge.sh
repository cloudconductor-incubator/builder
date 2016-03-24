#!/bin/bash

set -e
set -x

resize2fs /dev/vda1

distro_pkgs="
 vim-minimal
 gcc
 gcc-c++
 git
 epel-release
 make
 sudo
 tcpdump
"
yum install -y ${distro_pkgs}

vdc_vnet_packages="
 libpcap-devel
 mysql-devel
 zeromq3-devel
 sqlite-devel
 redis
 mysql-server
 rabbitmq-server
 qemu-kvm
 lxc
 lxc-templates
"

yum install -y ${vdc_vnet_packages}

cat > /etc/sysconfig/network-scripts/ifcfg-br0 <<EOF
DEVICE=br0
DEVICETYPE=ovs
TYPE=OVSBridge
ONBOOT=yes
BOOTPROTO=static
HOTPLUG=no
OVS_EXTRA="
 set bridge     \${DEVICE} protocols=OpenFlow10,OpenFlow12,OpenFlow13 --
 set bridge     \${DEVICE} other_config:disable-in-band=true --
 set bridge     \${DEVICE} other-config:datapath-id=0000bbbbbbbbbbbb --
 set bridge     \${DEVICE} other-config:hwaddr=02:01:00:00:00:01 --
 set-fail-mode  \${DEVICE} standalone --
 set-controller \${DEVICE} tcp:127.0.0.1:6633
"
EOF

cat > /etc/sysconfig/network-scripts/ifcfg-brtun <<EOF
DEVICE=brtun
DEVICETYPE=ovs
TYPE=OVSBridge
ONBOOT=yes
BOOTPROTO=static
EOF

mkdir -p /opt/axsh
mkdir -p /var/log/openvnet

cd /tmp
curl -L -o openvswitch.rpm https://www.dropbox.com/s/y1cb03vy4cxiru7/openvswitch-2.4.0-1.x86_64.rpm?dl=0
yum -y localinstall openvswitch.rpm

git clone https://github.com/rbenv/rbenv.git ~/.rbenv
mkdir -p ~/.rbenv/versions || :
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
source ~/.bash_profile || :

cd /opt/axsh
curl -o /etc/yum.repos.d/openvnet-third-party.repo -R https://raw.githubusercontent.com/axsh/openvnet/master/deployment/yum_repositories/stable/openvnet-third-party.repo
git clone https://github.com/axsh/openvnet.git
yum -y install openvnet-ruby

ln -s /opt/axsh/openvnet/ruby/ ~/.rbenv/versions/vnet-ruby
rbenv rehash || :

cat > /opt/axsh/openvnet/.ruby-version <<EOF
vnet-ruby
EOF

mkdir -p /etc/openvnet
cp /opt/axsh/openvnet/deployment/conf_files/etc/default/*    /etc/default/
cp /opt/axsh/openvnet/deployment/conf_files/etc/init/* /etc/init/
cp /opt/axsh/openvnet/deployment/conf_files/etc/openvnet/* /etc/openvnet/

chkconfig openvswitch on

cat > /etc/openvnet/vna.conf <<EOF

node {
  id "wanedge"
  addr {
    protocol "tcp"
    host "10.8.0.5"
    public ""
    port 9103
  }
}


network {
  uuid "nw-global"
  gateway {
    address "10.255.213.254"
  }
}
EOF

cat > /etc/openvnet/common.conf <<EOF
registry {
  adapter "redis"
  host "10.8.0.2"
  port 6379
}

db {
  adapter "mysql2"
  host "localhost"
  database "vnet"
  port 3306
  user "root"
  password ""
}

datapath_mac_group "mrg-dpg"
EOF

cd /opt/axsh/openvnet/vnet
OLD_PATH=$PATH
PATH="/opt/axsh/openvnet/ruby/bin:$OLD_PATH"
bundle install --path vendor/bundle

service network restart
service openvswitch start

ovs-vsctl --if-exists del-port brtun pbr0
ovs-vsctl --if-exists del-port br0 pbrtun

ovs-vsctl add-port brtun pbr0 -- set interface pbr0 type=patch options:peer=pbrtun
ovs-vsctl add-port br0 pbrtun -- set interface pbrtun type=patch options:peer=pbr0

cat > /etc/rc.local <<EOF
#!/bin/bash

ovs-vsctl --if-exists del-port brtun pbr0
ovs-vsctl --if-exists del-port br0 pbrtun

ovs-vsctl add-port brtun pbr0 -- set interface pbr0 type=patch options:peer=pbrtun
ovs-vsctl add-port br0 pbrtun -- set interface pbrtun type=patch options:peer=pbr0
EOF


PATH="/opt/axsh/openvnet/ruby/bin:$OLD_PATH"
cd /opt/axsh/openvnet/vnet

# eth0_ip=`ip addr show eth0 | grep "inet " | awk '{print $2}'`
# brglo_ip=${eth0_ip%/*}
# brglo_prefix=${eth0_ip##*/}
#
# cat > /etc/sysconfig/network-scripts/ifcfg-brglo<<EOF
# DEVICE=brglo
# DEVICETYPE=ovs
# TYPE=OVSBridge
# ONBOOT=yes
# BOOTPROTO=static
# IPADDR=${brglo_ip}
# PREFIX=${brglo_prefix}
# EOF

service network restart
