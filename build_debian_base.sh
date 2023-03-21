#!/bin/bash
## This script is to automate the preparation for a debian file system, which will be used for
## an ONIE installer image.
##
## USAGE:
##   USERNAME=username PASSWORD=password ./build_debian
## ENVIRONMENT:
##   USERNAME
##          The name of the default admin user
##   PASSWORD
##          The password, expected by chpasswd command

## Default user
echo "Eden build_debian_base Default user" 
[ -n "$USERNAME" ] || {
    echo "Error: no or empty USERNAME"
    exit 1
}

## Password for the default user
echo "Eden build_debian_base Password for the default user" 
[ -n "$PASSWORD" ] || {
    echo "Error: no or empty PASSWORD"
    exit 1
}

## Include common functions
echo "Eden build_debian_base Include common functions"
. functions.sh

## Enable debug output for script
echo "Eden build_debian_base  set -x -e" 
set -x -e

CONFIGURED_ARCH=$([ -f .arch ] && cat .arch || echo amd64)

## docker engine version (with platform)
echo "Eden build_debian_base  docker engine version (with platform)" 
DOCKER_VERSION=5:20.10.14~3-0~debian-$IMAGE_DISTRO
CONTAINERD_IO_VERSION=1.5.11-1
LINUX_KERNEL_VERSION=5.10.0-18-2

## Working directory to prepare the file system
echo "Eden build_debian_base Working directory to prepare the file system" 
FILESYSTEM_ROOT=./fsroot
PLATFORM_DIR=platform
## Hostname for the linux image
echo "Eden build_debian_base Hostname for the linux image" 
HOSTNAME=sonic
DEFAULT_USERINFO="Default admin user,,,"
BUILD_TOOL_PATH=src/sonic-build-hooks/buildinfo
TRUSTED_GPG_DIR=$BUILD_TOOL_PATH/trusted.gpg.d

## Read ONIE image related config file
echo "Eden build_debian_base Read ONIE image related config file" 
. ./onie-image.conf
[ -n "$ONIE_IMAGE_PART_SIZE" ] || {
    echo "Error: Invalid ONIE_IMAGE_PART_SIZE in onie image config file"
    exit 1
}
[ -n "$ONIE_INSTALLER_PAYLOAD" ] || {
    echo "Error: Invalid ONIE_INSTALLER_PAYLOAD in onie image config file"
    exit 1
}
[ -n "$FILESYSTEM_SQUASHFS" ] || {
    echo "Error: Invalid FILESYSTEM_SQUASHFS in onie image config file"
    exit 1
}

## Prepare the file system directory
echo "Eden build_debian_base  Prepare the file system directory" 
if [[ -d $FILESYSTEM_ROOT ]]; then
    sudo rm -rf $FILESYSTEM_ROOT || die "Failed to clean chroot directory"
fi
mkdir -p $FILESYSTEM_ROOT
mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR
mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/grub
touch $FILESYSTEM_ROOT/$PLATFORM_DIR/firsttime

## ensure proc is mounted
sudo mount proc /proc -t proc || true

## make / as a mountpoint in chroot env, needed by dockerd
pushd $FILESYSTEM_ROOT
sudo mount --bind . .
popd

## Build the host debian base system
echo "Eden build_debian_base Build host debian base system..."
TARGET_PATH=$TARGET_PATH scripts/build_debian_base_system.sh $CONFIGURED_ARCH $IMAGE_DISTRO $FILESYSTEM_ROOT

# Prepare buildinfo
sudo SONIC_VERSION_CACHE=${SONIC_VERSION_CACHE} \
	DBGOPT="${DBGOPT}" \
	scripts/prepare_debian_image_buildinfo.sh $CONFIGURED_ARCH $IMAGE_DISTRO $FILESYSTEM_ROOT $http_proxy


sudo chown root:root $FILESYSTEM_ROOT

## Config hostname and hosts, otherwise 'sudo ...' will complain 'sudo: unable to resolve host ...'
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '$HOSTNAME' > /etc/hostname"
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '127.0.0.1       $HOSTNAME' >> /etc/hosts"
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '127.0.0.1       localhost' >> /etc/hosts"

## Config basic fstab
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'echo "proc /proc proc defaults 0 0" >> /etc/fstab'
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'echo "sysfs /sys sysfs defaults 0 0" >> /etc/fstab'

## Setup proxy
[ -n "$http_proxy" ] && sudo /bin/bash -c "echo 'Acquire::http::Proxy \"$http_proxy\";' > $FILESYSTEM_ROOT/etc/apt/apt.conf.d/01proxy"

trap_push 'sudo LANG=C chroot $FILESYSTEM_ROOT umount /proc || true'
sudo LANG=C chroot $FILESYSTEM_ROOT mount proc /proc -t proc
## Note: mounting is necessary to makedev and install linux image
echo '[INFO] Mount all'
## Output all the mounted device for troubleshooting
sudo LANG=C chroot $FILESYSTEM_ROOT mount

## Install the trusted gpg public keys
[ -d $TRUSTED_GPG_DIR ] && [ ! -z "$(ls $TRUSTED_GPG_DIR)" ] && sudo cp $TRUSTED_GPG_DIR/* ${FILESYSTEM_ROOT}/etc/apt/trusted.gpg.d/

## Pointing apt to public apt mirrors and getting latest packages, needed for latest security updates
scripts/build_mirror_config.sh files/apt $CONFIGURED_ARCH $IMAGE_DISTRO 
sudo cp files/apt/sources.list.$CONFIGURED_ARCH $FILESYSTEM_ROOT/etc/apt/sources.list
sudo cp files/apt/apt.conf.d/{81norecommends,apt-{clean,gzip-indexes,no-languages},no-check-valid-until,apt-multiple-retries} $FILESYSTEM_ROOT/etc/apt/apt.conf.d/

## Note: set lang to prevent locale warnings in your chroot
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y update
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y upgrade

echo '[INFO] Install and setup eatmydata'
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install eatmydata
sudo LANG=C chroot $FILESYSTEM_ROOT ln -s /usr/bin/eatmydata /usr/local/bin/dpkg
echo 'Dir::Bin::dpkg "/usr/local/bin/dpkg";' | sudo tee $FILESYSTEM_ROOT/etc/apt/apt.conf.d/00image-install-eatmydata > /dev/null

## Note: dpkg hook conflict with eatmydata
sudo LANG=C chroot $FILESYSTEM_ROOT rm /usr/local/sbin/dpkg -f

echo '[INFO] Install packages for building image'
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install makedev psmisc

if [[ $CROSS_BUILD_ENVIRON == y ]]; then
    sudo LANG=C chroot $FILESYSTEM_ROOT dpkg --add-architecture $CONFIGURED_ARCH
fi

## Create device files
echo '[INFO] MAKEDEV'
if [[ $CONFIGURED_ARCH == armhf || $CONFIGURED_ARCH == arm64 ]]; then
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'cd /dev && MAKEDEV generic-arm'
else
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'cd /dev && MAKEDEV generic'
fi

## Install initramfs-tools and linux kernel
## Note: initramfs-tools recommends depending on busybox, and we really want busybox for
## 1. commands such as touch
## 2. mount supports squashfs
## However, 'dpkg -i' plus 'apt-get install -f' will ignore the recommended dependency. So
## we install busybox explicitly
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install busybox linux-base
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install acl
if [[ $CONFIGURED_ARCH == amd64 ]]; then
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install dmidecode hdparm
fi

## Add mtd and uboot firmware tools package
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install u-boot-tools libubootenv-tool mtd-utils device-tree-compiler

## Install docker
echo '[INFO] Install docker'
## Install apparmor utils since they're missing and apparmor is enabled in the kernel
## Otherwise Docker will fail to start
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install apparmor
sudo cp files/image_config/ntp/ntp-apparmor $FILESYSTEM_ROOT/etc/apparmor.d/local/usr.sbin.ntpd
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install apt-transport-https \
                                                       ca-certificates \
                                                       curl \
                                                       gnupg2 \
                                                       software-properties-common
if [[ $CONFIGURED_ARCH == armhf ]]; then
    # update ssl ca certificates for secure pem
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT c_rehash
fi
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT curl -o /tmp/docker.asc -fsSL https://download.docker.com/linux/debian/gpg
sudo LANG=C chroot $FILESYSTEM_ROOT mv /tmp/docker.asc /etc/apt/trusted.gpg.d/
sudo LANG=C chroot $FILESYSTEM_ROOT add-apt-repository \
                                    "deb [arch=$CONFIGURED_ARCH] https://download.docker.com/linux/debian $IMAGE_DISTRO stable"
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get update
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install docker-ce=${DOCKER_VERSION} docker-ce-cli=${DOCKER_VERSION} containerd.io=${CONTAINERD_IO_VERSION}

# Uninstall 'python3-gi' installed as part of 'software-properties-common' to remove debian version of 'PyGObject'
# pip version of 'PyGObject' will be installed during installation of 'sonic-host-services'
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y remove software-properties-common gnupg2 python3-gi

install_kubernetes () {
    local ver="$1"
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT curl -fsSL \
        https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
        sudo LANG=C chroot $FILESYSTEM_ROOT apt-key add -
    ## Check out the sources list update matches current Debian version
    sudo cp files/image_config/kubernetes/kubernetes.list $FILESYSTEM_ROOT/etc/apt/sources.list.d/
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get update
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install kubernetes-cni=${KUBERNETES_CNI_VERSION}
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install kubelet=${ver}
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install kubectl=${ver}
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install kubeadm=${ver}
}

if [ "$INCLUDE_KUBERNETES" == "y" ]
then
    ## Install Kubernetes
    echo '[INFO] Install kubernetes'
    install_kubernetes ${KUBERNETES_VERSION}
else
    echo '[INFO] Skipping Install kubernetes'
fi

if [ "$INCLUDE_KUBERNETES_MASTER" == "y" ]
then
    ## Install Kubernetes master
    echo '[INFO] Install kubernetes master'
    install_kubernetes ${MASTER_KUBERNETES_VERSION}
    
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT curl -fsSL \
        https://packages.microsoft.com/keys/microsoft.asc | \
        sudo LANG=C chroot $FILESYSTEM_ROOT apt-key add -
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT curl -fsSL \
        https://packages.microsoft.com/keys/msopentech.asc | \
        sudo LANG=C chroot $FILESYSTEM_ROOT apt-key add -
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azurecore-debian $IMAGE_DISTRO main" | \
        sudo tee $FILESYSTEM_ROOT/etc/apt/sources.list.d/azure.list
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get update
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install hyperv-daemons gnupg xmlstarlet
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install metricsext2
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y remove gnupg
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT curl -o /tmp/cri-dockerd.deb -fsSL \
        https://github.com/Mirantis/cri-dockerd/releases/download/v${MASTER_CRI_DOCKERD}/cri-dockerd_${MASTER_CRI_DOCKERD}.3-0.debian-${IMAGE_DISTRO}_amd64.deb
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install -f /tmp/cri-dockerd.deb 
    sudo LANG=C chroot $FILESYSTEM_ROOT rm -f /tmp/cri-dockerd.deb
else
    echo '[INFO] Skipping Install kubernetes master'
fi

## Add docker config drop-in to specify dockerd command line
sudo mkdir -p $FILESYSTEM_ROOT/etc/systemd/system/docker.service.d/
## Note: $_ means last argument of last command
sudo cp files/docker/docker.service.conf $_

## Create default user
## Note: user should be in the group with the same name, and also in sudo/docker/redis groups
sudo LANG=C chroot $FILESYSTEM_ROOT useradd -G sudo,docker $USERNAME -c "$DEFAULT_USERINFO" -m -s /bin/bash
## Create password for the default user
echo "$USERNAME:$PASSWORD" | sudo LANG=C chroot $FILESYSTEM_ROOT chpasswd

## Create redis group
sudo LANG=C chroot $FILESYSTEM_ROOT groupadd -f redis
sudo LANG=C chroot $FILESYSTEM_ROOT usermod -aG redis $USERNAME

if [[ $CONFIGURED_ARCH == amd64 ]]; then
    ## Pre-install hardware drivers
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install      \
        firmware-linux-nonfree
fi

## Pre-install the fundamental packages
## Note: gdisk is needed for sgdisk in install.sh
## Note: parted is needed for partprobe in install.sh
## Note: ca-certificates is needed for easy_install
## Note: don't install python-apt by pip, older than Debian repo one
## Note: fdisk and gpg are needed by fwutil
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install      \
    file                    \
    ifmetric                \
    iproute2                \
    bridge-utils            \
    isc-dhcp-client         \
    sudo                    \
    vim                     \
    tcpdump                 \
    dbus                    \
    ntpstat                 \
    openssh-server          \
    python3-apt             \
    traceroute              \
    iputils-ping            \
    arping                  \
    net-tools               \
    bsdmainutils            \
    ca-certificates         \
    i2c-tools               \
    efibootmgr              \
    usbutils                \
    pciutils                \
    iptables-persistent     \
    ebtables                \
    logrotate               \
    curl                    \
    kexec-tools             \
    less                    \
    unzip                   \
    gdisk                   \
    sysfsutils              \
    squashfs-tools          \
    grub2-common            \
    screen                  \
    hping3                  \
    tcptraceroute           \
    mtr-tiny                \
    locales                 \
    cgroup-tools            \
    ipmitool                \
    ndisc6                  \
    makedumpfile            \
    conntrack               \
    python3                 \
    python3-distutils       \
    python3-pip             \
    python-is-python3       \
    cron                    \
    libprotobuf23           \
    libgrpc++1              \
    libgrpc10               \
    haveged                 \
    fdisk                   \
    gpg                     \
    jq                      \
    auditd                  \
    linux-perf              \
    resolvconf              \
	lsof                    \
	sysstat

# default rsyslog version is 8.2110.0 which has a bug on log rate limit,
# use backport version
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -t bullseye-backports -y install rsyslog

# Have systemd create the auditd log directory
sudo mkdir -p ${FILESYSTEM_ROOT}/etc/systemd/system/auditd.service.d
sudo tee ${FILESYSTEM_ROOT}/etc/systemd/system/auditd.service.d/log-directory.conf >/dev/null <<EOF
[Service]
LogsDirectory=audit
LogsDirectoryMode=0750
EOF

if [[ $CONFIGURED_ARCH == amd64 ]]; then
## Pre-install the fundamental packages for amd64 (x86)
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install      \
    rasdaemon
fi

## Set /etc/shadow permissions to -rw-------.
sudo LANG=c chroot $FILESYSTEM_ROOT chmod 600 /etc/shadow

## Set /etc/passwd, /etc/group permissions to -rw-r--r--.
sudo LANG=c chroot $FILESYSTEM_ROOT chmod 644 /etc/passwd
sudo LANG=c chroot $FILESYSTEM_ROOT chmod 644 /etc/group


## Set /etc/passwd, /etc/group permissions to -rw-r--r--.
sudo LANG=c chroot $FILESYSTEM_ROOT chmod 644 /etc/passwd
sudo LANG=c chroot $FILESYSTEM_ROOT chmod 644 /etc/group

# Copy vmcore-sysctl.conf to add more vmcore dump flags to kernel
sudo cp files/image_config/kdump/vmcore-sysctl.conf $FILESYSTEM_ROOT/etc/sysctl.d/

#Adds a locale to a debian system in non-interactive mode
sudo sed -i '/^#.* en_US.* /s/^#//' $FILESYSTEM_ROOT/etc/locale.gen && \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT locale-gen "en_US.UTF-8"
sudo LANG=en_US.UTF-8 DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT update-locale "LANG=en_US.UTF-8"
sudo LANG=C chroot $FILESYSTEM_ROOT bash -c "find /usr/share/i18n/locales/ ! -name 'en_US' -type f -exec rm -f {} +"

sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install \
    picocom \
    systemd \
    systemd-sysv \
    ntp

if [[ $TARGET_BOOTLOADER == grub ]]; then
    if [[ $CONFIGURED_ARCH == amd64 ]]; then
        GRUB_PKG=grub-pc-bin
    elif [[ $CONFIGURED_ARCH == arm64 ]]; then
        GRUB_PKG=grub-efi-arm64-bin
    fi

    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get install -d -o dir::cache=/var/cache/apt \
        $GRUB_PKG

    sudo cp $FILESYSTEM_ROOT/var/cache/apt/archives/grub*.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/grub
fi

## Disable kexec supported reboot which was installed by default
sudo sed -i 's/LOAD_KEXEC=true/LOAD_KEXEC=false/' $FILESYSTEM_ROOT/etc/default/kexec

## Remove sshd host keys, and will regenerate on first sshd start
sudo rm -f $FILESYSTEM_ROOT/etc/ssh/ssh_host_*_key*
sudo cp files/sshd/host-ssh-keygen.sh $FILESYSTEM_ROOT/usr/local/bin/
sudo mkdir $FILESYSTEM_ROOT/etc/systemd/system/ssh.service.d
sudo cp files/sshd/override.conf $FILESYSTEM_ROOT/etc/systemd/system/ssh.service.d/override.conf
# Config sshd
# 1. Set 'UseDNS' to 'no'
# 2. Configure sshd to close all SSH connetions after 15 minutes of inactivity
sudo augtool -r $FILESYSTEM_ROOT <<'EOF'
touch /files/etc/ssh/sshd_config/EmptyLineHack
rename /files/etc/ssh/sshd_config/EmptyLineHack ""
set /files/etc/ssh/sshd_config/UseDNS no
ins #comment before /files/etc/ssh/sshd_config/UseDNS
set /files/etc/ssh/sshd_config/#comment[following-sibling::*[1][self::UseDNS]] "Disable hostname lookups"
rm /files/etc/ssh/sshd_config/ClientAliveInterval
rm /files/etc/ssh/sshd_config/ClientAliveCountMax
touch /files/etc/ssh/sshd_config/EmptyLineHack
rename /files/etc/ssh/sshd_config/EmptyLineHack ""
set /files/etc/ssh/sshd_config/ClientAliveInterval 900
set /files/etc/ssh/sshd_config/ClientAliveCountMax 0
ins #comment before /files/etc/ssh/sshd_config/ClientAliveInterval
set /files/etc/ssh/sshd_config/#comment[following-sibling::*[1][self::ClientAliveInterval]] "Close inactive client sessions after 15 minutes"
rm /files/etc/ssh/sshd_config/LogLevel
set /files/etc/ssh/sshd_config/LogLevel VERBOSE
save
quit
EOF
# Configure sshd to listen for v4 and v6 connections
sudo sed -i 's/^#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' $FILESYSTEM_ROOT/etc/ssh/sshd_config
sudo sed -i 's/^#ListenAddress ::/ListenAddress ::/' $FILESYSTEM_ROOT/etc/ssh/sshd_config

## Config rsyslog
sudo augtool -r $FILESYSTEM_ROOT --autosave "
rm /files/lib/systemd/system/rsyslog.service/Service/ExecStart/arguments
set /files/lib/systemd/system/rsyslog.service/Service/ExecStart/arguments/1 -n
"

sudo mkdir -p $FILESYSTEM_ROOT/var/core

# Config sysctl
sudo augtool --autosave "
set /files/etc/sysctl.conf/kernel.core_pattern '|/usr/local/bin/coredump-compress %e %t %p %P'
set /files/etc/sysctl.conf/kernel.softlockup_panic 1
set /files/etc/sysctl.conf/kernel.panic 10
set /files/etc/sysctl.conf/kernel.hung_task_timeout_secs 300
set /files/etc/sysctl.conf/vm.panic_on_oom 2
set /files/etc/sysctl.conf/fs.suid_dumpable 2
" -r $FILESYSTEM_ROOT

sysctl_net_cmd_string=""
while read line; do
  [[ "$line" =~ ^#.*$ ]] && continue
  sysctl_net_conf_key=`echo $line | awk -F '=' '{print $1}'`
  sysctl_net_conf_value=`echo $line | awk -F '=' '{print $2}'`
  sysctl_net_cmd_string=$sysctl_net_cmd_string"set /files/etc/sysctl.conf/$sysctl_net_conf_key $sysctl_net_conf_value"$'\n'
done < files/image_config/sysctl/sysctl-net.conf

sudo augtool --autosave "$sysctl_net_cmd_string" -r $FILESYSTEM_ROOT

# Upgrade pip via PyPI and uninstall the Debian version
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install --upgrade pip
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get purge -y python3-pip

# For building Python packages
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install 'setuptools==49.6.00'
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install 'wheel==0.35.1'

# docker Python API package is needed by Ansible docker module as well as some SONiC applications
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install 'docker==5.0.3'

# Install scapy
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install 'scapy==2.4.4'

## Note: keep pip installed for maintainance purpose

# Install GCC, needed for building/installing some Python packages
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install gcc

## Create /var/run/redis folder for docker-database to mount
sudo mkdir -p $FILESYSTEM_ROOT/var/run/redis

## Config DHCP for eth0
sudo tee -a $FILESYSTEM_ROOT/etc/network/interfaces > /dev/null <<EOF

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

sudo cp files/dhcp/rfc3442-classless-routes $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d
sudo cp files/dhcp/sethostname $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d/
sudo cp files/dhcp/sethostname6 $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d/
sudo cp files/dhcp/graphserviceurl $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d/
sudo cp files/dhcp/snmpcommunity $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d/
sudo cp files/dhcp/vrf $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d/
if [ -f files/image_config/ntp/ntp ]; then
    sudo cp ./files/image_config/ntp/ntp $FILESYSTEM_ROOT/etc/init.d/
fi

if [ -f files/image_config/ntp/ntp-systemd-wrapper ]; then
    sudo mkdir -p $FILESYSTEM_ROOT/usr/lib/ntp/
    sudo cp ./files/image_config/ntp/ntp-systemd-wrapper $FILESYSTEM_ROOT/usr/lib/ntp/
fi

## Version file
sudo mkdir -p $FILESYSTEM_ROOT/etc/sonic
if [ -f files/image_config/sonic_release ]; then
    sudo cp files/image_config/sonic_release $FILESYSTEM_ROOT/etc/sonic/
fi
export build_version="${SONIC_IMAGE_VERSION}"
export debian_version="$(cat $FILESYSTEM_ROOT/etc/debian_version)"
export kernel_version="${kversion}"
export asic_type="${sonic_asic_platform}"
export asic_subtype="${TARGET_MACHINE}"
export commit_id="$(git rev-parse --short HEAD)"
export branch="$(git rev-parse --abbrev-ref HEAD)"
export release="$(if [ -f $FILESYSTEM_ROOT/etc/sonic/sonic_release ]; then cat $FILESYSTEM_ROOT/etc/sonic/sonic_release; fi)"
export build_date="$(date -u)"
export build_number="${BUILD_NUMBER:-0}"
export built_by="$USER@$BUILD_HOSTNAME"
j2 files/build_templates/sonic_version.yml.j2 | sudo tee $FILESYSTEM_ROOT/etc/sonic/sonic_version.yml

## Copy over clean-up script
sudo cp ./files/scripts/core_cleanup.py $FILESYSTEM_ROOT/usr/bin/core_cleanup.py

for build_extension in ${build_extensions}; do
    ./${build_extension} $FILESYSTEM_ROOT $PLATFORM_DIR $IMAGE_DISTRO
done

## Organization specific extensions such as Configuration & Scripts for features like AAA, ZTP...
if [ "${enable_organization_extensions}" = "y" ]; then
   if [ -f files/build_templates/organization_extensions.sh ]; then
      sudo chmod 755 files/build_templates/organization_extensions.sh
      ./files/build_templates/organization_extensions.sh -f $FILESYSTEM_ROOT -h $HOSTNAME
   fi
fi

## Debug Image specific changes
## Update motd for debug image
if [ "$DEBUG_IMG" == "y" ]
then
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '**************' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo 'Running DEBUG image' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '**************' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '/src has the sources' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '/src is mounted in each docker' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '/debug is created for core files or temp files' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo 'Create a subdir under /debug to upload your files' >> /etc/motd"
    sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '/debug is mounted in each docker' >> /etc/motd"

    sudo mkdir -p $FILESYSTEM_ROOT/src
    sudo cp $DEBUG_SRC_ARCHIVE_FILE $FILESYSTEM_ROOT/src/
    sudo mkdir -p $FILESYSTEM_ROOT/debug

fi

## Umount all
echo '[INFO] Umount all'
## Display all process details access /proc
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -vm /proc
## Kill the processes
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -km /proc || true
## Wait fuser fully kill the processes
sleep 15
sudo LANG=C chroot $FILESYSTEM_ROOT umount /proc || true

# Ensure admin gid is 1000
gid_user=$(sudo LANG=C chroot $FILESYSTEM_ROOT id -g $USERNAME) || gid_user="none"
if [ "${gid_user}" != "1000" ]; then
    die "expect gid 1000. current:${gid_user}"
fi

sleep 10
# pack base sys
date
echo "Eden build_debian_base date"
sudo rm -f sonic.squashfs
echo "Eden build_debian_base rm -f sonic.squashfs" 
sudo mksquashfs $FILESYSTEM_ROOT sonic.squashfs -e boot -e var/lib/docker -e $PLATFORM_DIR
echo "Eden build_debian_base mksquashfs" 
pushd $FILESYSTEM_ROOT && zip $OLDPWD/$TARGET_PATH/sonic-basefs.zip -r boot/ $PLATFORM_DIR/; popd
echo "Eden build_debian_base FILESYSTEM_ROOT= $FILESYSTEM_ROOT OLDPWD = $OLDPWD TARGET_PATH= $TARGET_PATH PLATFORM_DIR = $PLATFORM_DIR"
echo "Eden build_debian_base pushd"
date
echo "Eden build_debian_base date" 