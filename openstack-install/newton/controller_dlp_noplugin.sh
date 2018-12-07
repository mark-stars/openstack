#!/bin/bash

#set -x
PASSWORD=iforgot
yum remove firewalld-filesystem NetworkManager-libnm -y
FIRST_PKG=centos-release-openstack-newton
CONTROLLER_PKGS=(
net-tools
chrony
python-openstackclient
openstack-selinux
mariadb
mariadb-server
python2-PyMySQL
rabbitmq-server
memcached
python-memcached
openstack-keystone
httpd
mod_wsgi
openstack-glance
openstack-nova-api
openstack-nova-conductor
openstack-nova-console
openstack-nova-novncproxy
openstack-nova-scheduler
openstack-nova-placement-api
openstack-neutron
openstack-neutron-ml2
openstack-neutron-linuxbridge
#openstack-neutron-lbaas-ui.noarch
#openstack-neutron-lbaas-ui-doc.noarch
#openstack-neutron-lbaas.noarch
#openstack-neutron-fwaas.noarch
ebtables
openstack-cinder
openstack-dashboard
)
declare -A SERVICE_USERS
SERVICE_USERS=(
[identity]="keystone"
[image]="glance"
[compute]="nova"
[placement]="placement"
[network]="neutron"
[volume]="cinder"
)
ENDPOINTS=(
"admin"
"internal"
"public"
)
#yum install $FIRST_PKG -y
yum upgrade -y
yum install ${CONTROLLER_PKGS[*]} -y
NIC_NAME=(`ip addr | grep '^[0-9]' | awk -F':' '{print $2}'`)
MGMT_IP=`ifconfig ${NIC_NAME[1]} | grep -w inet | awk '{print $2}'`
echo "$MGMT_IP controller" >> /etc/hosts
sed -i "s/#ServerName www.example.com:80/ServerName controller/g" /etc/httpd/conf/httpd.conf
cat > /etc/chrony.conf << EOF
server $MGMT_IP iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow 0.0.0.0
local stratum 10
EOF
systemctl enable chronyd
systemctl start chronyd
cat > /etc/my.cnf.d/openstack.cnf << EOF
[mysqld]
bind-address = $MGMT_IP
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF
systemctl enable mariadb
systemctl start mariadb
mysql_secure_installation <<EOF

y
$PASSWORD
$PASSWORD
y
y
y
y
EOF
systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service
rabbitmqctl add_user openstack $PASSWORD
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
sed -i "s/127.0.0.1/$MGMT_IP/g" /etc/sysconfig/memcached
systemctl enable memcached.service
systemctl start memcached.service
for USER in ${SERVICE_USERS[*]}; do
if [[ $USER = nova ]]; then
mysql -uroot -p$PASSWORD -e "CREATE DATABASE nova_api"
mysql -uroot -p$PASSWORD -e "CREATE DATABASE $USER"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON nova_api.* TO '$USER'@'localhost' IDENTIFIED BY '$PASSWORD'"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON nova_api.* TO '$USER'@'%' IDENTIFIED BY '$PASSWORD'"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON $USER.* TO '$USER'@'localhost' IDENTIFIED BY '$PASSWORD'"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON $USER.* TO '$USER'@'%' IDENTIFIED BY '$PASSWORD'"
else
mysql -uroot -p$PASSWORD -e "CREATE DATABASE $USER"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON $USER.* TO '$USER'@'localhost' IDENTIFIED BY '$PASSWORD'"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON $USER.* TO '$USER'@'%' IDENTIFIED BY '$PASSWORD'"
fi
done
cat > /etc/keystone/keystone.conf <<EOF
[database]
connection = mysql+pymysql://keystone:$PASSWORD@$MGMT_IP/keystone
[token]
provider = fernet
EOF
chown root:keystone /etc/keystone/keystone.conf
su -s /bin/sh -c "keystone-manage db_sync" keystone
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password $PASSWORD \
--bootstrap-admin-url http://$MGMT_IP:35357/v3/ \
--bootstrap-internal-url http://$MGMT_IP:5000/v3/ \
--bootstrap-public-url http://$MGMT_IP:5000/v3/ \
--bootstrap-region-id RegionOne
ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
systemctl enable httpd.service
systemctl start httpd.service
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL=http://$MGMT_IP:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
openstack project create --domain default \
--description "Service Project" service
openstack role create user
cat > ~/admin-openrc << EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL=http://$MGMT_IP:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
for SERVICE in ${!SERVICE_USERS[*]}; do
if [[ $SERVICE = volume ]]; then
openstack user create --domain default --password $PASSWORD ${SERVICE_USERS[$SERVICE]}
openstack role add --project service --user ${SERVICE_USERS[$SERVICE]} admin
openstack service create --name ${SERVICE_USERS[$SERVICE]}"v2" \
--description "OpenStack Block Storage" $SERVICE"v2"
openstack service create --name ${SERVICE_USERS[$SERVICE]}"v3" \
--description "OpenStack Block Storage" $SERVICE"v3"
for ENDPOINT in ${ENDPOINTS[*]}; do
openstack endpoint create --region RegionOne \
$SERVICE"v2" $ENDPOINT http://$MGMT_IP:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne \
$SERVICE"v3" $ENDPOINT http://$MGMT_IP:8776/v3/%\(project_id\)s
done
elif [[ $SERVICE = compute ]]; then
openstack user create --domain default --password $PASSWORD ${SERVICE_USERS[$SERVICE]}
openstack role add --project service --user ${SERVICE_USERS[$SERVICE]} admin
openstack service create --name ${SERVICE_USERS[$SERVICE]} \
--description "OpenStack Compute" $SERVICE
for ENDPOINT in ${ENDPOINTS[*]}; do
openstack endpoint create --region RegionOne \
$SERVICE $ENDPOINT http://$MGMT_IP:8774/v2.1
done
elif [[ $SERVICE = placement ]]; then
openstack user create --domain default --password $PASSWORD ${SERVICE_USERS[$SERVICE]}
openstack role add --project service --user ${SERVICE_USERS[$SERVICE]} admin
openstack service create --name ${SERVICE_USERS[$SERVICE]} \
--description "OpenStack Placement" $SERVICE
for ENDPOINT in ${ENDPOINTS[*]}; do
openstack endpoint create --region RegionOne \
$SERVICE $ENDPOINT http://$MGMT_IP:8778
done
elif [[ $SERVICE = image ]]; then
openstack user create --domain default --password $PASSWORD ${SERVICE_USERS[$SERVICE]}
openstack role add --project service --user ${SERVICE_USERS[$SERVICE]} admin
openstack service create --name ${SERVICE_USERS[$SERVICE]} \
--description "OpenStack Image" $SERVICE
for ENDPOINT in ${ENDPOINTS[*]}; do
openstack endpoint create --region RegionOne \
$SERVICE $ENDPOINT http://$MGMT_IP:9292
done
elif [[ $SERVICE = network ]]; then
openstack user create --domain default --password $PASSWORD ${SERVICE_USERS[$SERVICE]}
openstack role add --project service --user ${SERVICE_USERS[$SERVICE]} admin
openstack service create --name ${SERVICE_USERS[$SERVICE]} \
--description "OpenStack Network" $SERVICE
for ENDPOINT in ${ENDPOINTS[*]}; do
openstack endpoint create --region RegionOne \
$SERVICE $ENDPOINT http://$MGMT_IP:9696
done
fi
done
cat > /etc/glance/glance-api.conf << EOF
[database]
connection = mysql+pymysql://glance:$PASSWORD@$MGMT_IP/glance
[keystone_authtoken]
auth_uri = http://$MGMT_IP:5000
auth_url = http://$MGMT_IP:35357
memcached_servers = $MGMT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = $PASSWORD
[paste_deploy]
flavor = keystone
[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
EOF
cat > /etc/glance/glance-registry.conf << EOF
[database]
connection = mysql+pymysql://glance:$PASSWORD@$MGMT_IP/glance
[keystone_authtoken]
auth_uri = http://$MGMT_IP:5000
auth_url = http://$MGMT_IP:35357
memcached_servers = $MGMT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = $PASSWORD
[paste_deploy]
flavor = keystone
EOF
chown root:glance /etc/glance/glance-api.conf /etc/glance/glance-registry.conf
su -s /bin/sh -c "glance-manage db_sync" glance
cat > /etc/nova/nova.conf << EOF
[DEFAULT]
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:$PASSWORD@$MGMT_IP
my_ip = $MGMT_IP
use_neutron = True
firewall_driver = nova.virt.firewall.NoopFirewallDriver
auth_strategy = keystone
[api_database]
connection = mysql+pymysql://nova:$PASSWORD@$MGMT_IP/nova_api
[cinder]
os_region_name = RegionOne
[database]
connection = mysql+pymysql://nova:$PASSWORD@$MGMT_IP/nova
[glance]
api_servers = http://$MGMT_IP:9292
[keystone_authtoken]
auth_uri = http://$MGMT_IP:5000
auth_url = http://$MGMT_IP:35357
memcached_servers = $MGMT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = $PASSWORD
[neutron]
url = http://$MGMT_IP:9696
auth_url = http://$MGMT_IP:35357
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = $PASSWORD
service_metadata_proxy = True
metadata_proxy_shared_secret = $PASSWORD
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
[vnc]
enabled = True
vncserver_listen = $MGMT_IP
vncserver_proxyclient_address = $MGMT_IP
EOF
chown root:nova /etc/nova/nova.conf
su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage db sync" nova
cat > /etc/neutron/neutron.conf << EOF
[DEFAULT]
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
transport_url = rabbit://openstack:$PASSWORD@$MGMT_IP
auth_strategy = keystone
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
[database]
connection = mysql+pymysql://neutron:$PASSWORD@$MGMT_IP/neutron
[keystone_authtoken]
auth_uri = http://$MGMT_IP:5000
auth_url = http://$MGMT_IP:35357
memcached_servers = $MGMT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $PASSWORD
[nova]
auth_url = http://$MGMT_IP:35357
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = $PASSWORD
[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF
cat > /etc/neutron/plugins/ml2/ml2_conf.ini << EOF
[ml2]
type_drivers = flat,vlan,vxlan
tenant_network_types = vxlan
mechanism_drivers = linuxbridge,l2population
extension_drivers = port_security
[ml2_type_flat]
flat_networks = provider
[ml2_type_vxlan]
vni_ranges = 1:1000
[securitygroup]
enable_ipset = True
EOF
cat > /etc/neutron/plugins/ml2/linuxbridge_agent.ini << EOF
[linux_bridge]
physical_interface_mappings = provider:${NIC_NAME[2]}
[securitygroup]
enable_security_group = True
firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
[vxlan]
enable_vxlan = True
local_ip = $MGMT_IP
l2_population = True
EOF
cat > /etc/neutron/l3_agent.ini << EOF
[DEFAULT]
interface_driver = neutron.agent.linux.interface.BridgeInterfaceDriver
[AGENT]
#extensions = fwaas
EOF
cat > /etc/neutron/dhcp_agent.ini << EOF
[DEFAULT]
interface_driver = neutron.agent.linux.interface.BridgeInterfaceDriver
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
enable_isolated_metadata = True
EOF
cat > /etc/neutron/metadata_agent.ini << EOF
[DEFAULT]
nova_metadata_host = $MGMT_IP
metadata_proxy_shared_secret = $PASSWORD
EOF
#cat > /etc/neutron/fwaas_driver.ini << EOF
#[DEFAULT]
#[fwaas]
#agent_version = v1
#driver = iptables
#enabled = True
#EOF
#cat > /etc/neutron/lbaas_agent.ini << EOF
#[DEFAULT]
#device_driver = neutron_lbaas.drivers.haproxy.namespace_driver.HaproxyNSDriver
#interface_driver = neutron.agent.linux.interface.BridgeInterfaceDriver
#[haproxy]
#user_group = haproxy
#EOF
#cat > /etc/neutron/neutron_lbaas.conf << EOF
#[DEFAULT]
#[certificates]
#[quotas]
#[service_auth]
#[service_providers]
#service_provider = LOADBALANCERV2:Haproxy:neutron_lbaas.drivers.haproxy.plugin_driver.HaproxyOnHostPluginDriver:default
#EOF
chown root:neutron /etc/neutron/neutron.conf 
chown root:neutron /etc/neutron/plugins/ml2/ml2_conf.ini 
chown root:neutron /etc/neutron/plugins/ml2/linuxbridge_agent.ini
chown root:neutron /etc/neutron/l3_agent.ini
chown root:neutron /etc/neutron/dhcp_agent.ini
chown root:neutron /etc/neutron/metadata_agent.ini
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
--config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
#neutron-db-manage --subproject neutron-lbaas upgrade head
#neutron-db-manage --subproject neutron-fwaas upgrade head
cat > /etc/cinder/cinder.conf << EOF
[DEFAULT]
transport_url = rabbit://openstack:$PASSWORD@$MGMT_IP
auth_strategy = keystone
my_ip = $MGMT_IP
[database]
connection = mysql+pymysql://cinder:$PASSWORD@$MGMT_IP/cinder
[keystone_authtoken]
auth_uri = http://$MGMT_IP:5000
auth_url = http://$MGMT_IP:35357
memcached_servers = $MGMT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = $PASSWORD
[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
EOF
chown root:cinder /etc/cinder/cinder.conf
su -s /bin/sh -c "cinder-manage db sync" cinder

cp /etc/openstack-dashboard/local_settings /etc/openstack-dashboard/local_settings.bak
sed -i "4i\WSGIApplicationGroup %{GLOBAL}" /etc/httpd/conf.d/openstack-dashboard.conf
cat > /etc/openstack-dashboard/local_settings << EOF
# -*- coding: utf-8 -*-

import os
from django.utils.translation import ugettext_lazy as _
from openstack_dashboard import exceptions
from openstack_dashboard.settings import HORIZON_CONFIG
DEBUG = False
WEBROOT = '/dashboard/'
ALLOWED_HOSTS = ['*', ]
OPENSTACK_API_VERSIONS = {
         "identity": 3,
         "image": 2,
         "volume": 2,
}
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'default'
LOCAL_PATH = '/tmp'
SECRET_KEY='b24999645d719cedb521'
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
CACHES = {
          'default': {
                  'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
                  'LOCATION': 'controller:11211',
          }
}
EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'
OPENSTACK_HOST = "controller"
OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"
OPENSTACK_KEYSTONE_BACKEND = {
    'name': 'native',
    'can_edit_user': True,
    'can_edit_group': True,
    'can_edit_project': True,
    'can_edit_domain': True,
    'can_edit_role': True,
}
OPENSTACK_HYPERVISOR_FEATURES = {
    'can_set_mount_point': False,
    'can_set_password': False,
    'requires_keypair': False,
    'enable_quotas': True
}
OPENSTACK_CINDER_FEATURES = {
    'enable_backup': False,
}
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': True,
    'enable_quotas': True,
    'enable_ipv6': False,
    'enable_distributed_router': True,
    'enable_ha_router': True,
    'enable_lb': True,
    'enable_firewall': True,
    'enable_vpn': True,
    'enable_fip_topology_check': True,
    'profile_support': None,
    'supported_vnic_types': ['*'],
}
OPENSTACK_HEAT_STACK = {
    'enable_user_pass': True,
}
IMAGE_CUSTOM_PROPERTY_TITLES = {
    "architecture": _("Architecture"),
    "kernel_id": _("Kernel ID"),
    "ramdisk_id": _("Ramdisk ID"),
    "image_state": _("Euca2ools state"),
    "project_id": _("Project ID"),
    "image_type": _("Image Type"),
}
IMAGE_RESERVED_CUSTOM_PROPERTIES = []
API_RESULT_LIMIT = 1000
API_RESULT_PAGE_SIZE = 20
SWIFT_FILE_TRANSFER_CHUNK_SIZE = 512 * 1024
INSTANCE_LOG_LENGTH = 35
DROPDOWN_MAX_ITEMS = 30
TIME_ZONE = "UTC"
POLICY_FILES_PATH = '/etc/openstack-dashboard'
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'operation': {
            'format': '%(asctime)s %(message)s'
        },
    },
    'handlers': {
        'null': {
            'level': 'DEBUG',
            'class': 'logging.NullHandler',
        },
        'console': {
            'level': 'INFO',
            'class': 'logging.StreamHandler',
        },
        'operation': {
            'level': 'INFO',
            'class': 'logging.StreamHandler',
            'formatter': 'operation',
        },
    },
    'loggers': {
        'django.db.backends': {
            'handlers': ['null'],
            'propagate': False,
        },
        'requests': {
            'handlers': ['null'],
            'propagate': False,
        },
        'horizon': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'horizon.operation_log': {
            'handlers': ['operation'],
            'level': 'INFO',
            'propagate': False,
        },
        'openstack_dashboard': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'novaclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'cinderclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'keystoneclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'glanceclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'neutronclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'heatclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'ceilometerclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'swiftclient': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'openstack_auth': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'nose.plugins.manager': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'django': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
        'iso8601': {
            'handlers': ['null'],
            'propagate': False,
        },
        'scss': {
            'handlers': ['null'],
            'propagate': False,
        },
    },
}
SECURITY_GROUP_RULES = {
    'all_tcp': {
        'name': _('All TCP'),
        'ip_protocol': 'tcp',
        'from_port': '1',
        'to_port': '65535',
    },
    'all_udp': {
        'name': _('All UDP'),
        'ip_protocol': 'udp',
        'from_port': '1',
        'to_port': '65535',
    },
    'all_icmp': {
        'name': _('All ICMP'),
        'ip_protocol': 'icmp',
        'from_port': '-1',
        'to_port': '-1',
    },
    'ssh': {
        'name': 'SSH',
        'ip_protocol': 'tcp',
        'from_port': '22',
        'to_port': '22',
    },
    'smtp': {
        'name': 'SMTP',
        'ip_protocol': 'tcp',
        'from_port': '25',
        'to_port': '25',
    },
    'dns': {
        'name': 'DNS',
        'ip_protocol': 'tcp',
        'from_port': '53',
        'to_port': '53',
    },
    'http': {
        'name': 'HTTP',
        'ip_protocol': 'tcp',
        'from_port': '80',
        'to_port': '80',
    },
    'pop3': {
        'name': 'POP3',
        'ip_protocol': 'tcp',
        'from_port': '110',
        'to_port': '110',
    },
    'imap': {
        'name': 'IMAP',
        'ip_protocol': 'tcp',
        'from_port': '143',
        'to_port': '143',
    },
    'ldap': {
        'name': 'LDAP',
        'ip_protocol': 'tcp',
        'from_port': '389',
        'to_port': '389',
    },
    'https': {
        'name': 'HTTPS',
        'ip_protocol': 'tcp',
        'from_port': '443',
        'to_port': '443',
    },
    'smtps': {
        'name': 'SMTPS',
        'ip_protocol': 'tcp',
        'from_port': '465',
        'to_port': '465',
    },
    'imaps': {
        'name': 'IMAPS',
        'ip_protocol': 'tcp',
        'from_port': '993',
        'to_port': '993',
    },
    'pop3s': {
        'name': 'POP3S',
        'ip_protocol': 'tcp',
        'from_port': '995',
        'to_port': '995',
    },
    'ms_sql': {
        'name': 'MS SQL',
        'ip_protocol': 'tcp',
        'from_port': '1433',
        'to_port': '1433',
    },
    'mysql': {
        'name': 'MYSQL',
        'ip_protocol': 'tcp',
        'from_port': '3306',
        'to_port': '3306',
    },
    'rdp': {
        'name': 'RDP',
        'ip_protocol': 'tcp',
        'from_port': '3389',
        'to_port': '3389',
    },
}
REST_API_REQUIRED_SETTINGS = ['OPENSTACK_HYPERVISOR_FEATURES',
                              'LAUNCH_INSTANCE_DEFAULTS',
                              'OPENSTACK_IMAGE_FORMATS']
ALLOWED_PRIVATE_SUBNET_CIDR = {'ipv4': [], 'ipv6': []}
EOF

chown root:apache /etc/openstack-dashboard/local_settings
systemctl restart httpd

echo "######### Start ALL Services ##########"
systemctl enable openstack-glance-api.service \
openstack-glance-registry.service
systemctl start openstack-glance-api.service \
openstack-glance-registry.service
systemctl enable openstack-nova-api.service \
openstack-nova-consoleauth.service openstack-nova-scheduler.service \
openstack-nova-conductor.service openstack-nova-novncproxy.service
systemctl start openstack-nova-api.service \
openstack-nova-consoleauth.service openstack-nova-scheduler.service \
openstack-nova-conductor.service openstack-nova-novncproxy.service
systemctl restart openstack-nova-api.service
systemctl enable neutron-server.service \
neutron-linuxbridge-agent.service neutron-dhcp-agent.service \
neutron-metadata-agent.service neutron-l3-agent.service \
neutron-lbaasv2-agent.service
systemctl start neutron-server.service \
neutron-linuxbridge-agent.service neutron-dhcp-agent.service \
neutron-metadata-agent.service neutron-l3-agent.service \
neutron-lbaasv2-agent.service
systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl start openstack-cinder-api.service openstack-cinder-scheduler.service
