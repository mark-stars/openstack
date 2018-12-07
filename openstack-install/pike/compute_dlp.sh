#!/bin/bash

#set -x
PASSWORD=iforgot
COMPUTE_PKGS=(
net-tools
openstack-selinux
openstack-nova-compute
openstack-neutron-linuxbridge
ebtables
ipset
)
yum remove firewalld-filesystem NetworkManager-libnm -y
yum install ${COMPUTE_PKGS[*]} -y
NIC_NAME=(`ip addr | grep '^[0-9]' | awk -F':' '{print $2}'`)
MGMT_IP=`ifconfig ${NIC_NAME[1]} | grep -w inet | awk '{print $2}'`
cat > /etc/nova/nova.conf << EOF
[DEFAULT]
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:$PASSWORD@192.168.1.31
my_ip = $MGMT_IP
use_neutron = True
firewall_driver = nova.virt.firewall.NoopFirewallDriver
[api]
auth_strategy = keystone
[glance]
api_servers = http://192.168.1.31:9292
[keystone_authtoken]
auth_uri = http://192.168.1.31:5000
auth_url = http://192.168.1.31:35357
memcached_servers = 192.168.1.31:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = $PASSWORD
[vnc]
enabled = True
vncserver_listen = 0.0.0.0
vncserver_proxyclient_address = $MGMT_IP
novncproxy_base_url = http://gamedebug.iok.la:6080/vnc_auto.html
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
[libvirt]
virt_type = kvm
[neutron]
url = http://192.168.1.31:9696
auth_url = http://192.168.1.31:35357
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = $PASSWORD
[placement]
os_region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://192.168.1.31:35357/v3
username = placement
password = $PASSWORD
EOF
cat > /etc/neutron/neutron.conf << EOF
[DEFAULT]
transport_url = rabbit://openstack:$PASSWORD@192.168.1.31
auth_strategy = keystone
[keystone_authtoken]
auth_uri = http://192.168.1.31:5000
auth_url = http://192.168.1.31:35357
memcached_servers = 192.168.1.31:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $PASSWORD
[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF
cat > /etc/neutron/plugins/ml2/linuxbridge_agent.ini << EOF
[vxlan]
enable_vxlan = true
local_ip = $MGMT_IP
l2_population = true
[securitygroup]
enable_security_group = true
firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
EOF

sed -i "s/#LIBVIRTD_ARGS=/LIBVIRTD_ARGS=/g" /etc/sysconfig/libvirtd
sed -i 's/#listen_tls = 0/listen_tls = 0/g' /etc/libvirt/libvirtd.conf
sed -i 's/#listen_tcp = 1/listen_tcp = 1/g' /etc/libvirt/libvirtd.conf
sed -i 's/#auth_tcp = "sasl"/auth_tcp = "none"/g' /etc/libvirt/libvirtd.conf

################## Start Services ###################
systemctl enable libvirtd.service openstack-nova-compute.service neutron-linuxbridge-agent.service
systemctl start libvirtd.service openstack-nova-compute.service neutron-linuxbridge-agent.service