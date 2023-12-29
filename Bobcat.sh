set -e
#Openstack Configuration 

OPENSTACK_VERSION=$(whiptail --menu " Choose an OpenStack Cloud version ☁︎ " --title " Openstack Version ☁️" 18 100 10 \
  "2023.2" " OpenStack Bobcat Stable Version " 3>&1 1>&2 2>&3) 
OPENSTACK_VIP=$(whiptail --inputbox "Please Enter the OpenStack VIP  " --title " OpenStack Vıp " 10 65 3>&1 1>&2 2>&3 )
INTERNAL_NIC_NAME=$(whiptail --inputbox "Please Enter the Primary NIC Name (EX:- eth0 ens192..) " --title " OpenStack Primary NIC 🔗 " 10 65 3>&1 1>&2 2>&3 )
EXTERNAL_NIC_NAME=$(whiptail --inputbox "Please Enter the Secondary NIC Name (EX:- eth1 ens224..) " --title " OpenStack Secondary NIC 🔗 " 10 65 3>&1 1>&2 2>&3 )
NEWTRON_PLUGIN=$(whiptail --menu "Choose Neutron Network Plugin 🖧 " 18 100 10 \
  "ovn" "Open Virtual Network." \
  "openvswitch" "A software-defined networking (SDN) " \
  "linuxbridge" "Linux Bridge, being older and simpler" 3>&1 1>&2 2>&3)
CINDER_DISK_NAME=$(whiptail --inputbox "Please Enter the Raw disk name for Cinder ⛁ (EX:- /dev/sdb..) " --title " OpenStack Cinder Disk ⛁ " 10 65 3>&1 1>&2 2>&3 )
VIRT_TYPE=$(whiptail --menu "Choose Virtualization Type " 18 100 10 \
  "qemu" "your compute node does not support hardware acceleration, and you must configure libvirt to use QEMU instead of KVM." \
  "kvm" "your compute node does support hardware acceleration, and you must configure KVM to use KVM instead of qemu" 3>&1 1>&2 2>&3)
KEYSTONE_ADMIN_PASSWORD=$(whiptail --passwordbox "Please Enter Keystone Admin Password 🔑 " --title " 🔑 OpenStack Horizon Dashboard  Admin Password 🔑 " 10 65 3>&1 1>&2 2>&3 )

#Cloud network configuration 

IP_VERSION=${IP_VERSION:-4}
EXT_NET_CIDR=$(whiptail --inputbox "Please Enter Provider/External Network CIDR Range 🕸 (EX:- 172.16.24.1/23..) " --title " 🕸 Openstack External CIDR Range 🕸 " 10 95 3>&1 1>&2 2>&3 )
EXT_NET_RANGE=$(whiptail --inputbox "Please Enter External Network Start and end IP's (EX:- start=172.16.25.87,end=172.16.25.89) " --title " OpenStack External CIDR  Start and End IP " 10 95 3>&1 1>&2 2>&3 )
EXT_NET_GATEWAY=$(whiptail --inputbox "Please Enter External Network GatewayIP (EX:- 172.16.24.1) " --title " OpenStack External Gateway IP " 10 95 3>&1 1>&2 2>&3 )

#opentack all-in-one deployment

dnf update -y
dnf remove python3-requests -y  
dnf install git python3-devel libffi-devel gcc openssl-devel python3-libselinux -y
dnf install python3-pip -y
pip3 install -U pip
pip install 'ansible-core>=2.13,<=2.14.7'
pip install 'ansible>=6,<8'
pip3 install git+https://opendev.org/openstack/kolla-ansible@stable/$OPENSTACK_VERSION  
sudo mkdir -p /etc/kolla
sudo chown $USER:$USER /etc/kolla
cp -r /usr/local/share/kolla-ansible/etc_examples/kolla/* /etc/kolla
cp /usr/local/share/kolla-ansible/ansible/inventory/* .
cd /etc/kolla
kolla-ansible install-deps
mkdir -p /etc/ansible
cat << EOF > /etc/ansible/ansible.cfg
[defaults]
host_key_checking=False
pipelining=True
forks=100
EOF

kolla-genpwd
sed -ie "s/\(keystone_admin_password:*\)/#\1/"  /etc/kolla/passwords.yml
echo "keystone_admin_password: "$KEYSTONE_ADMIN_PASSWORD"" >> /etc/kolla/passwords.yml
cp /usr/local/share/kolla-ansible/ansible/inventory/* .
pvcreate $CINDER_DISK_NAME
vgcreate cinder-volumes $CINDER_DISK_NAME
cd /etc/kolla
echo "kolla_internal_vip_address: "$OPENSTACK_VIP"" >> globals.yml
echo "network_interface: "$INTERNAL_NIC_NAME"" >> globals.yml
echo "neutron_external_interface: "$EXTERNAL_NIC_NAME"" >> globals.yml
echo "enable_cinder: "yes"" >> globals.yml >> globals.yml
echo "enable_cinder_backend_lvm: "yes""  >> globals.yml
echo "cinder_volume_group: "cinder-volumes"" >> globals.yml
echo "enable_cinder_backup: "no"" >> globals.yml
echo "nova_compute_virt_type: "$VIRT_TYPE"" >> globals.yml
echo "neutron_plugin_agent: "$NEWTRON_PLUGIN"" >> globals.yml
kolla-ansible -i all-in-one bootstrap-servers
kolla-ansible -i all-in-one prechecks
kolla-ansible -i all-in-one deploy
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/$OPENSTACK_VERSION
kolla-ansible post-deploy

#openstack configuration 

cd /etc/kolla
wget https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2 -O Centos9
. admin-openrc.sh
openstack flavor create --id 1 --ram 512 --disk 1 --vcpus 1 m1.tiny
openstack flavor create --id 2 --ram 2048 --disk 20 --vcpus 1 m1.small
openstack flavor create --id 3 --ram 4096 --disk 40 --vcpus 2 m1.medium
openstack flavor create --id 4 --ram 8192 --disk 80 --vcpus 4 m1.large
openstack flavor create --id 5 --ram 16384 --disk 160 --vcpus 8 m1.xlarge

openstack network create --external --provider-physical-network physnet1 \
        --provider-network-type flat external

openstack subnet create --dhcp --ip-version ${IP_VERSION} \
        --allocation-pool $EXT_NET_RANGE --network external \
        --subnet-range $EXT_NET_CIDR --gateway $EXT_NET_GATEWAY external-subnet
openstack image create --disk-format qcow2 --container-format bare --public --file Centos9 Centos9 

if [ ! -f ~/.ssh/id_ecdsa.pub ]; then
    echo Generating ssh key.
    ssh-keygen -t ecdsa -N '' -f ~/.ssh/id_ecdsa
fi
if [ -r ~/.ssh/id_ecdsa.pub ]; then
    echo Configuring nova public key and quotas.
    openstack keypair create --public-key ~/.ssh/id_ecdsa.pub mykey
fi
git clone https://github.com/Dineshk1205/Logos
cd /etc/kolla/Logos/
docker cp logo-splash.svg horizon:/var/lib/kolla/venv/lib/python3.9/site-packages/static/dashboard/img
docker cp logo.svg horizon:/var/lib/kolla/venv/lib/python3.9/site-packages/static/dashboard/img
docker restart horizon 
whiptail --msgbox "ℹ️ USE the URL 🔗➡'http://IP or FQDN' to acess the Openstack Dashboard." --title "🚀 Openstack All-In-One Node Deployment Successfully Completed ☑️ 👏" 10 150
