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


cat > /etc/sysconfig/network-scripts/ifcfg-brtun <<EOF
DEVICE=brtun
DEVICETYPE=ovs
TYPE=OVSBridge
ONBOOT=yes
BOOTPROTO=static
EOF

mkdir -p /opt/axsh
mkdir -p /var/log/openvnet

useradd vnet-vnmgr
useradd vnet-webapi

touch /var/log/openvnet/vnmgr.log
touch /var/log/openvnet/webapi.log

chown vnet-vnmgr.vnet-vnmgr /var/log/openvnet/vnmgr.log
chown vnet-webapi.vnet-webapi /var/log/openvnet/webapi.log

cd /tmp
curl -L -o openvswitch.rpm https://www.dropbox.com/s/y1cb03vy4cxiru7/openvswitch-2.4.0-1.x86_64.rpm?dl=0
yum -y localinstall openvswitch.rpm


git clone https://github.com/rbenv/rbenv.git ~/.rbenv
mkdir -p ~/.rbenv/versions || :
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
source ~/.bash_profile || :

curl -o /etc/yum.repos.d/wakame-vdc-stable.repo -R https://raw.githubusercontent.com/axsh/wakame-vdc/master/rpmbuild/yum_repositories/wakame-vdc-stable.repo
yum install -y wakame-vdc-dcmgr-vmapp-config
cp /opt/axsh/wakame-vdc/dcmgr/config/dcmgr.conf.example /etc/wakame-vdc/dcmgr.conf

cat >> /etc/wakame-vdc/dcmgr.conf <<EOF
features {
  openvnet true
  vnet_endpoint 'localhost'
  vnet_endpoint_port 9090
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

chkconfig redis on
chkconfig mysqld on
chkconfig rabbitmq-server on
chkconfig openvswitch on

sed -i -e "s,bind,#bind," /etc/redis.conf

cd /opt/axsh/openvnet/vnet
OLD_PATH=$PATH
PATH="/opt/axsh/openvnet/ruby/bin:$OLD_PATH"
bundle install --path vendor/bundle

service openvswitch start || :
service mysqld start || :
service network restart

cd /opt/axsh/wakame-vdc/dcmgr
mysqladmin drop -f wakame_dcmgr wakame_dcmgr_gui || :
mysqladmin create wakame_dcmgr
mysqladmin create wakame_dcmgr_gui
PATH="/opt/axsh/wakame-vdc/ruby/bin:$OLD_PATH"
bundle exec rake db:up

PATH="/opt/axsh/openvnet/ruby/bin:$OLD_PATH"
cd /opt/axsh/openvnet/vnet
bundle exec rake db:drop || :
bundle exec rake db:create
bundle exec rake db:init

service redis start
service mysqld start
service rabbitmq-server start

mkdir -p /var/lib/wakame-vdc/images
curl -o /var/lib/wakame-vdc/images/centos-6.6.x86_64.kvm.md.raw.tar.gz -R http://dlc.wakame.axsh.jp/demo/1box/vmimage/centos-6.6.x86_64.kvm.md.raw.tar.gz

node_id=`grep NODE_ID /etc/default/vdc-hva | sed -e s,NODE_ID=,,`
cd /opt/axsh/wakame-vdc/dcmgr/bin
./vdc-manage host add hva.hvakvm --force --uuid hn-hvakvm --cpu-cores 180 --memory-size 400000 --disk-space 500000 --hypervisor kvm --arch x86_64
./vdc-manage host add hva.hvalxc --force --uuid hn-hvalxc --cpu-cores 180 --memory-size 400000 --disk-space 500000 --hypervisor lxc --arch x86_64

./vdc-manage backupstorage add --uuid bkst-demo1 --display-name='local storage'  --base-uri='file:///opt/axsh/wakame-vdc/images/' --storage-type=local --description='local backup storage under /opt/axsh/wakame-vdc/images/' --node-id="bksta.demo1"
./vdc-manage backupstorage add --uuid bkst-demo2 --display-name='remote storage' --base-uri='http://10.8.0.2:8000/image/' --storage-type=webdav --description='webdav storage' --node-id="bksta.demo2"

./vdc-manage backupobject add --storage-id=bkst-demo1 --uuid=bo-centos1d64 --display-name='centos-6.6.x86_64.kvm.md.raw.tar.gz' --object-key=centos-6.6.x86_64.kvm.md.raw.tar.gz --size=4294967296 --allocation-size=412668243 --checksum=bbdaa6193d5823e772c0df9260007b47 --container-format=tgz --description='centos-6.6.x86_64.kvm.md.raw.tar.gz'
./vdc-manage backupobject add --storage-id=bkst-demo2 --uuid=bo-vdcdcmgr --display-name='virtual_datacenter_dcmgr.kvm.md.raw.tar.gz' --object-key=virtual_datacenter_dcmgr.kvm.md.raw.tar.gz --size=22548578304 --allocation-size=4489711846 --checksum=203ae63d265d2831b1f69ab622b1570c --container-format=tgz --description='virtual_datacenter_dcmgr'

./vdc-manage image add local bo-centos1d64 --account-id a-shpoolxx --uuid wmi-centos1d64 --arch x86_64 --description 'centos-6.6.x86_64.kvm.md.raw.tar.gz local' --file-format raw --root-device label:root --service-type std --is-public --display-name 'centos1d64' --is-cacheable
./vdc-manage image add local bo-vdcdcmgr --account-id a-shpoolxx --uuid wmi-vdcdcmgr --arch x86_64 --description 'virtual_datacenter_dcmgr.kvm.md.raw.tar.gz' --file-format raw --root-device label:root --service-type std --is-public --display-name 'vdcdcmgr' --is-cacheable

./vdc-manage image features wmi-centos1d64 --virtio
./vdc-manage image features wmi-vdcdcmgr --virtio

./vdc-manage network dc add management
./vdc-manage network dc del-network-mode management securitygroup
./vdc-manage network dc add-network-mode management passthrough

./vdc-manage network dc add vnet --allow-new-networks true
./vdc-manage network dc add-network-mode vnet l2overlay

./vdc-manage network add --uuid nw-global --ipv4-network 10.255.196.0 --ipv4-gw 10.255.196.254 --prefix 24 --domain global --metric 10 --service-type std --display-name "global" --ip-assignment "asc" --network-mode passthrough
./vdc-manage network forward nw-global management
./vdc-manage network dhcp addrange nw-global 10.255.196.90 10.255.196.100

./vdc-manage macrange add 525400 1 ffffff --uuid mr-demomacs

cd /root
git clone https://github.com/axsh/wakame-vdc.git
yes | cp -r wakame-vdc/dcmgr/* /opt/axsh/wakame-vdc/dcmgr/

initctl start vdc-dcmgr
initctl start vdc-collector

mkdir -p /etc/wakame-vdc/dcmgr_gui
cp /opt/axsh/wakame-vdc/frontend/dcmgr_gui/config/database.yml.example /etc/wakame-vdc/dcmgr_gui/database.yml
cp /opt/axsh/wakame-vdc/frontend/dcmgr_gui/config/dcmgr_gui.yml.example /etc/wakame-vdc/dcmgr_gui/dcmgr_gui.yml
cp /opt/axsh/wakame-vdc/frontend/dcmgr_gui/config/instance_spec.yml.example /etc/wakame-vdc/dcmgr_gui/instance_spec.yml
cp /opt/axsh/wakame-vdc/frontend/dcmgr_gui/config/load_balancer_spec.yml.example /etc/wakame-vdc/dcmgr_gui/load_balancer_spec.yml
cp /opt/axsh/wakame-vdc/contrib/etc/init/vdc-webui.conf /etc/init/
cp /opt/axsh/wakame-vdc/contrib/etc/default/vdc-webui /etc/default/
cd /opt/axsh/wakame-vdc/frontend/dcmgr_gui/
/opt/axsh/wakame-vdc/ruby/bin/rake db:init

./bin/gui-manage account add --name default --uuid a-shpoolxx
./bin/gui-manage user add --name "demo user" --uuid u-demo --password demo --login-id demo
./bin/gui-manage user associate u-demo --account-ids a-shpoolxx

initctl start vdc-webui || :

initctl start vnet-vnmgr
initctl start vnet-webapi

sleep 20

curl -s -X POST \
 --data-urlencode uuid=dp-vnakvm \
 --data-urlencode dpid=0x0000aaaaaaaaaaaa \
 --data-urlencode display_name=vnakvm \
 --data-urlencode node_id=vnakvm \
http://localhost:9090/api/1.0/datapaths

curl -s -X POST \
 --data-urlencode uuid=dp-wanedge \
 --data-urlencode dpid=0x0000bbbbbbbbbbbb \
 --data-urlencode display_name=wanedge \
 --data-urlencode node_id=wanedge \
http://localhost:9090/api/1.0/datapaths

curl -s -X POST \
 --data-urlencode uuid=dp-vna \
 --data-urlencode dpid=0x0000cccccccccccc \
 --data-urlencode display_name=vnalxc \
 --data-urlencode node_id=vnalxc \
http://localhost:9090/api/1.0/datapaths

curl -s -X POST \
  --data-urlencode uuid=nw-global \
  --data-urlencode display_name=global \
  --data-urlencode ipv4_network=10.255.213.0 \
  --data-urlencode ipv4_prefix=24 \
  --data-urlencode network_mode=physical \
http://localhost:9090/api/1.0/networks

curl -s -X POST \
  --data-urlencode uuid=nw-public \
  --data-urlencode display_name=public \
  --data-urlencode ipv4_network=10.8.0.0 \
  --data-urlencode ipv4_prefix=24 \
  --data-urlencode network_mode=physical \
http://localhost:9090/api/1.0/networks
