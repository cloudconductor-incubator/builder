#!/bin/bash

set -e
set -x

distro_pkgs="
 vim-minimal
 gcc
 gcc-c++
 git
 epel-release
 make
 sudo
 dosfstools
 tcpdump
"
yum install -y ${distro_pkgs}

vdc_vnet_packages="
 libpcap-devel
 mysql-devel
 zeromq3-devel
 sqlite-devel
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
 set bridge     \${DEVICE} other-config:datapath-id=0000cccccccccccc --
 set bridge     \${DEVICE} other-config:hwaddr=02:01:00:00:00:02 --
 set-fail-mode  \${DEVICE} standalone --
 set-controller \${DEVICE} tcp:127.0.0.1:6633
"
EOF

cat > /etc/sysconfig/network-scripts/ifcfg-br1 <<EOF
DEVICE=br1
DEVICETYPE=ovs
TYPE=OVSBridge
ONBOOT=yes
BOOTPROTO=static
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

curl -o /etc/yum.repos.d/wakame-vdc-stable.repo -R https://raw.githubusercontent.com/axsh/wakame-vdc/master/rpmbuild/yum_repositories/wakame-vdc-stable.repo
yum install -y wakame-vdc-hva-kvm-vmapp-config.x86_64
cp /opt/axsh/wakame-vdc/dcmgr/config/hva.conf.example /etc/wakame-vdc/hva.conf
sed -i -e "s,config.edge_networking .\+,config.edge_networking = 'openvnet'," /etc/wakame-vdc/hva.conf
sed -i -e "s,#NODE_ID=.\+,NODE_ID=hvalxc," /etc/default/vdc-hva
sed -i -e "s,#AMQP_ADDR.\+,AMQP_ADDR=10.8.0.2," /etc/default/vdc-hva
sed -i -e "/dc_network/,/}/d" /etc/wakame-vdc/hva.conf


cat >> /etc/wakame-vdc/hva.conf <<EOF
dc_network('vnet') {
  bridge_type 'ovs'
  interface 'br0'
  bridge 'br0'
}

dc_network('management') {
  bridge_type 'ovs'
  interface 'br1'
  bridge 'br1'
}
EOF

cd /opt/axsh
curl -o /etc/yum.repos.d/openvnet-third-party.repo -R https://raw.githubusercontent.com/axsh/openvnet/master/deployment/yum_repositories/stable/openvnet-third-party.repo
git clone https://github.com/axsh/openvnet.git
yum -y install openvnet-ruby

ln -s /opt/axsh/wakame-vdc/ruby/ ~/.rbenv/versions/vdc-ruby
ln -s /opt/axsh/openvnet/ruby/ ~/.rbenv/versions/vnet-ruby
rbenv rehash || :

cat > /opt/axsh/wakame-vdc/.ruby-version <<EOF
vdc-ruby
EOF

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
  id "vnalxc"
  addr {
    protocol "tcp"
    host "10.8.0.6"
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


initctl start vdc-hva
initctl start vnet-vna
