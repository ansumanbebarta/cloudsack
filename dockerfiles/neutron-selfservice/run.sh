#!/bin/bash

KEYSTONE_HOST=${KEYSTONE_HOST:-keystone}
REGION=${REGION:-RegionOne}
NOVA_HOST=${NOVA_HOST:-nova}
MYSQL_HOST=${MYSQL_HOST:-mysql}
NOVA_USER=${NOVA_USER:-nova}
NOVA_PASSWORD=${NOVA_PASSWORD:-devops}
NEUTRON_DBPASS=${NEUTRON_DBPASS:-devops}
RABBITMQ_HOST=${RABBITMQ_HOST:-rabbitmq}
RABBITMQ_USER=${RABBITMQ_USER:-openstack}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-devops}
NEUTRON_PASSWORD=${NEUTRON_PASSWORD:-devops}
NEUTRON_HOST=${NEUTRON_HOST:-neutorn}
MEMCACHED_HOST=${MEMCACHED_HOST:-memcached}
MEMCACHED_PORT=${MEMCACHED_PORT:-11211}
METADATA_SECRET=${METADATA_SECRET:-openstack}
PROJECT_DOMAIN=${PROJECT_DOMAIN:-default}
USER_DOMAIN=${USER_DOMAIN:-default}
PROJECT_NAME=${PROJECT_NAME:-service}
NEUTRON_USER=${NEUTRON_USER:-neutron}
NEUTRON_FILE=/etc/neutron/neutron.conf
OVERLAY_INTERFACE_IP_ADDRESS=`hostname -i`
NEUTRON_DB=${NEUTRON_DB:-neutron}
NEUTRON_DBUSER=${NEUTRON_DBUSER:-neutron}
SERVICE_PORT=${SERVICE_PORT:-9696}

create_service_credentials() {
	CMD=$1
	c=0
	$CMD
	while [ $? -ne 0 ] && [ $c -lt 4 ]
	do
		sleep 5
		c=$((c+1))
		$CMD
	done
	if [ $? -ne 0 ]
	then
		echo -e "Problem in running:\n$CMD"
		exit 1
	fi
}

neutron_config() {

echo -e "nameserver ${KUBE_NAMESERVER} \n nameserver ${HOST_NAMESERVER}" > /etc/resolv.conf

MYSQL="mysql -h${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD}"
${MYSQL} -e "CREATE DATABASE IF NOT EXISTS ${NEUTRON_DB};"
${MYSQL} -e "GRANT ALL PRIVILEGES ON ${NEUTRON_DB}.* TO \"${NEUTRON_DBUSER}\"@'localhost' IDENTIFIED BY \"${NEUTRON_DBPASS}\";\
                GRANT ALL PRIVILEGES ON ${NEUTRON_DB}.* TO \"$NEUTRON_DBUSER\"@'%' IDENTIFIED BY \"${NEUTRON_DBPASS}\";"


cat >~/openrc <<EOF
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASSWORD}
export OS_AUTH_URL=http://${KEYSTONE_HOST}:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

source ~/openrc

if [ "`openstack user list | grep ${NEUTRON_USER}`" ]
then
	:
else
	create_service_credentials "openstack user create --domain default --password ${NEUTRON_PASSWORD} ${NEUTRON_USER}"
	create_service_credentials "openstack role add --project service --user ${NEUTRON_USER} admin"
	create_service_credentials "openstack service create --name neutron network"
	create_service_credentials "openstack endpoint create --region $REGION network  public http://${NEUTRON_HOST}:${SERVICE_PORT}"
	create_service_credentials "openstack endpoint create --region $REGION network internal http://${NEUTRON_HOST}:${SERVICE_PORT}"
	create_service_credentials "openstack endpoint create --region $REGION network admin http://${NEUTRON_HOST}:${SERVICE_PORT}"

fi

echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv4.conf.default.rp_filter=0' >> /etc/sysctl.conf
echo 'net.ipv4.conf.all.rp_filter=0' >> /etc/sysctl.conf
sysctl -p


sed -i "s,^connection[ =].*,connection = mysql+pymysql://${NEUTRON_DBUSER}:${NEUTRON_DBPASS}@${MYSQL_HOST}/${NEUTRON_DB}," $NEUTRON_FILE

sed -i "/^\[DEFAULT\]/a core_plugin = ml2\nservice_plugins = router\nauth_strategy = keystone\nallow_overlapping_ips = True\nrpc_backend = rabbit\nnotify_nova_on_port_status_changes = True\nnotify_nova_on_port_data_changes = True " $NEUTRON_FILE

sed -i "/\[nova\]/a auth_url = http://$KEYSTONE_HOST:35357\nauth_type = password\nproject_domain_name = default\nuser_domain_name = default\nregion_name = $REGION\nproject_name = service\nusername = ${NOVA_USER}\npassword = $NOVA_PASSWORD" $NEUTRON_FILE

sed -i "/\[keystone_authtoken\]/a auth_uri = http://${KEYSTONE_HOST}:5000\nauth_url = http://${KEYSTONE_HOST}:35357\nmemcached_servers = ${MEMCACHED_HOST}:${MEMCACHED_PORT}\nauth_type = password\nproject_domain_name = ${PROJECT_DOMAIN}\nuser_domain_name = ${USER_DOMAIN}\nproject_name = ${PROJECT_NAME}\nusername = ${NEUTRON_USER}\npassword = $NEUTRON_PASSWORD " $NEUTRON_FILE

sed -i "/\[oslo_concurrency\]/a lock_path = $state_path/lock " $NEUTRON_FILE

sed -i "/\[oslo_messaging_rabbit\]/a rabbit_host = $RABBITMQ_HOST\nrabbit_userid = $RABBITMQ_USER\nrabbit_password = $RABBITMQ_PASSWORD" $NEUTRON_FILE


sed -i "/^\[DEFAULT\]/a interface_driver = neutron.agent.linux.interface.BridgeInterfaceDriver\nexternal_network_bridge = " /etc/neutron/l3_agent.ini

sed -i "/^\[DEFAULT\]/a interface_driver = neutron.agent.linux.interface.BridgeInterfaceDriver\ndhcp_driver = neutron.agent.linux.dhcp.Dnsmasq\nenable_isolated_metadata = True " /etc/neutron/dhcp_agent.ini
 
sed -i "/^\[DEFAULT\]/a nova_metadata_ip = $NOVA_HOST\nmetadata_proxy_shared_secret = ${METADATA_SECRET}" /etc/neutron/metadata_agent.ini

sed -i "/\[ml2\]/a type_drivers = flat,vlan,vxlan\ntenant_network_types = vxlan\nmechanism_drivers = linuxbridge,l2population\nextension_drivers = port_security " /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[ml2_type_flat\]/a flat_networks = provider " /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[ml2_type_vxlan\]/a vni_ranges = 1:1000" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[securitygroup\]/a enable_ipset = True" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[linux_bridge\]/a physical_interface_mappings = provider:eth0 " /etc/neutron/plugins/ml2/linuxbridge_agent.ini

sed -i "/\[vxlan\]/a enable_vxlan = True\nlocal_ip = $OVERLAY_INTERFACE_IP_ADDRESS\nl2_population = True" /etc/neutron/plugins/ml2/linuxbridge_agent.ini

sed -i "/\[securitygroup\]/a enable_security_group = True\nfirewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver" /etc/neutron/plugins/ml2/linuxbridge_agent.ini

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini 

rm -rf /var/lib/neutron/neutron.sqlite
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

}

if [ ! -f ~/openrc ]; then
        neutron_config
fi

/usr/bin/supervisord
