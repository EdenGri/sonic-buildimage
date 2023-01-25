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
[ -n "$USERNAME" ] || {
    echo "Error: no or empty USERNAME"
    exit 1
}

## Password for the default user
[ -n "$PASSWORD" ] || {
    echo "Error: no or empty PASSWORD"
    exit 1
}

## Include common functions
. functions.sh

## Enable debug output for script
set -x -e

CONFIGURED_ARCH=$([ -f .arch ] && cat .arch || echo amd64)

## docker engine version (with platform)
DOCKER_VERSION=5:20.10.14~3-0~debian-$IMAGE_DISTRO
CONTAINERD_IO_VERSION=1.5.11-1
LINUX_KERNEL_VERSION=5.10.0-18-2

## Working directory to prepare the file system
FILESYSTEM_ROOT=./fsroot
PLATFORM_DIR=platform
## Hostname for the linux image
HOSTNAME=sonic
DEFAULT_USERINFO="Default admin user,,,"
BUILD_TOOL_PATH=src/sonic-build-hooks/buildinfo
TRUSTED_GPG_DIR=$BUILD_TOOL_PATH/trusted.gpg.d

## Read ONIE image related config file
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

date
sudo fuser -vm $FILESYSTEM_ROOT
sudo rm -rf $FILESYSTEM_ROOT
sudo unsquashfs -d $FILESYSTEM_ROOT sonic.squashfs
pushd $FILESYSTEM_ROOT && sudo unzip $OLDPWD/$TARGET_PATH/basefs.zip; popd
date

## ensure proc is mounted
sudo mount proc /proc -t proc || true

## make / as a mountpoint in chroot env, needed by dockerd
pushd $FILESYSTEM_ROOT
sudo mount --bind . .
popd

trap_push 'sudo LANG=C chroot $FILESYSTEM_ROOT umount /proc || true'
sudo LANG=C chroot $FILESYSTEM_ROOT mount proc /proc -t proc
## Note: mounting is necessary to makedev and install linux image
echo '[INFO] Mount all'
## Output all the mounted device for troubleshooting
sudo LANG=C chroot $FILESYSTEM_ROOT mount

## docker and mkinitramfs on target system will use pigz/unpigz automatically
if [[ $GZ_COMPRESS_PROGRAM == pigz ]]; then
    sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install pigz
fi

## Install initramfs-tools and linux kernel
## Note: initramfs-tools recommends depending on busybox, and we really want busybox for
## 1. commands such as touch
## 2. mount supports squashfs
## However, 'dpkg -i' plus 'apt-get install -f' will ignore the recommended dependency. So
## we install busybox explicitly
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install busybox linux-base
echo '[INFO] Install SONiC linux kernel image'
## Note: duplicate apt-get command to ensure every line return zero
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/initramfs-tools-core_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/initramfs-tools_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/linux-image-${LINUX_KERNEL_VERSION}-*_${CONFIGURED_ARCH}.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install acl
if [[ $CONFIGURED_ARCH == amd64 ]]; then
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install dmidecode hdparm
fi

## Sign the Linux kernel
if [ "$SONIC_ENABLE_SECUREBOOT_SIGNATURE" = "y" ]; then
    if [ ! -f $SIGNING_KEY ]; then
       echo "Error: SONiC linux kernel signing key missing"
       exit 1
    fi
    if [ ! -f $SIGNING_CERT ]; then
       echo "Error: SONiC linux kernel signing certificate missing"
       exit 1
    fi

    echo '[INFO] Signing SONiC linux kernel image'
    K=$FILESYSTEM_ROOT/boot/vmlinuz-${LINUX_KERNEL_VERSION}-${CONFIGURED_ARCH}
    sbsign --key $SIGNING_KEY --cert $SIGNING_CERT --output /tmp/${K##*/} ${K}
    sudo cp -f /tmp/${K##*/} ${K}
fi

## Update initramfs for booting with squashfs+overlay
cat files/initramfs-tools/modules | sudo tee -a $FILESYSTEM_ROOT/etc/initramfs-tools/modules > /dev/null

## Hook into initramfs: change fs type from vfat to ext4 on arista switches
sudo mkdir -p $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/
sudo cp files/initramfs-tools/arista-convertfs $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/arista-convertfs
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/arista-convertfs
sudo cp files/initramfs-tools/arista-hook $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/arista-hook
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/arista-hook
sudo cp files/initramfs-tools/mke2fs $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/mke2fs
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/mke2fs
sudo cp files/initramfs-tools/setfacl $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/setfacl
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/setfacl

# Hook into initramfs: rename the management interfaces on arista switches
sudo cp files/initramfs-tools/arista-net $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/arista-net
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/arista-net

# Hook into initramfs: resize root partition after migration from another NOS to SONiC on Dell switches
sudo cp files/initramfs-tools/resize-rootfs $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/resize-rootfs
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/resize-rootfs

# Hook into initramfs: upgrade SSD from initramfs
sudo cp files/initramfs-tools/ssd-upgrade $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/ssd-upgrade
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/ssd-upgrade

# Hook into initramfs: run fsck to repair a non-clean filesystem prior to be mounted
sudo cp files/initramfs-tools/fsck-rootfs $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/fsck-rootfs
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-premount/fsck-rootfs

## Hook into initramfs: after partition mount and loop file mount
## 1. Prepare layered file system
## 2. Bind-mount docker working directory (docker overlay storage cannot work over overlay rootfs)
sudo cp files/initramfs-tools/union-mount $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/union-mount
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/union-mount
sudo cp files/initramfs-tools/varlog $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/varlog
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/varlog
# Management interface (eth0) dhcp can be optionally turned off (during a migration from another NOS to SONiC)
#sudo cp files/initramfs-tools/mgmt-intf-dhcp $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/mgmt-intf-dhcp
#sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/mgmt-intf-dhcp
sudo cp files/initramfs-tools/union-fsck $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/union-fsck
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/union-fsck
pushd $FILESYSTEM_ROOT/usr/share/initramfs-tools/scripts/init-bottom && sudo patch -p1 < $OLDPWD/files/initramfs-tools/udev.patch; popd
if [[ $CONFIGURED_ARCH == armhf || $CONFIGURED_ARCH == arm64 ]]; then
    sudo cp files/initramfs-tools/uboot-utils $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/uboot-utils
    sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/uboot-utils
    cat files/initramfs-tools/modules.arm | sudo tee -a $FILESYSTEM_ROOT/etc/initramfs-tools/modules > /dev/null
fi
# Update initramfs for load platform specific modules
if [ -f platform/$CONFIGURED_PLATFORM/modules ]; then
    cat platform/$CONFIGURED_PLATFORM/modules | sudo tee -a $FILESYSTEM_ROOT/etc/initramfs-tools/modules > /dev/null
fi

# Needed to install kdump-tools
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "mkdir -p /etc/initramfs-tools/conf.d"
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo 'MODULES=most' >> /etc/initramfs-tools/conf.d/driver-policy"

## Copy ASIC config checksum
sudo chmod 755 files/build_scripts/generate_asic_config_checksum.py
./files/build_scripts/generate_asic_config_checksum.py
if [[ ! -f './asic_config_checksum' ]]; then
    echo 'asic_config_checksum not found'
    exit 1
fi
sudo cp ./asic_config_checksum $FILESYSTEM_ROOT/etc/sonic/asic_config_checksum

if [ -f sonic_debian_extension.sh ]; then
    ./sonic_debian_extension.sh $FILESYSTEM_ROOT $PLATFORM_DIR $IMAGE_DISTRO
fi

## Organization specific extensions such as Configuration & Scripts for features like AAA, ZTP...
if [ "${enable_organization_extensions}" = "y" ]; then
   if [ -f files/build_templates/organization_extensions.sh ]; then
      sudo chmod 755 files/build_templates/organization_extensions.sh
      ./files/build_templates/organization_extensions.sh -f $FILESYSTEM_ROOT -h $HOSTNAME
   fi
fi

## Setup ebtable rules (rule file in text format)
sudo cp files/image_config/ebtables/ebtables.filter.cfg ${FILESYSTEM_ROOT}/etc

## Update initramfs
sudo chroot $FILESYSTEM_ROOT update-initramfs -u
## Convert initrd image to u-boot format
if [[ $TARGET_BOOTLOADER == uboot ]]; then
    INITRD_FILE=initrd.img-${LINUX_KERNEL_VERSION}-${CONFIGURED_ARCH}
    if [[ $CONFIGURED_ARCH == armhf ]]; then
        INITRD_FILE=initrd.img-${LINUX_KERNEL_VERSION}-armmp
        sudo LANG=C chroot $FILESYSTEM_ROOT mkimage -A arm -O linux -T ramdisk -C gzip -d /boot/$INITRD_FILE /boot/u${INITRD_FILE}
        ## Overwriting the initrd image with uInitrd
        sudo LANG=C chroot $FILESYSTEM_ROOT mv /boot/u${INITRD_FILE} /boot/$INITRD_FILE
    elif [[ $CONFIGURED_ARCH == arm64 ]]; then
        sudo cp -v $PLATFORM_DIR/${sonic_asic_platform}-${CONFIGURED_ARCH}/sonic_fit.its $FILESYSTEM_ROOT/boot/
        sudo LANG=C chroot $FILESYSTEM_ROOT mkimage -f /boot/sonic_fit.its /boot/sonic_${CONFIGURED_ARCH}.fit
    fi
fi

# Collect host image version files before cleanup
SONIC_VERSION_CACHE=${SONIC_VERSION_CACHE}  \
	DBGOPT="${DBGOPT}" \
	scripts/collect_host_image_version_files.sh $CONFIGURED_ARCH $IMAGE_DISTRO $TARGET_PATH $FILESYSTEM_ROOT

# Remove GCC
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y remove gcc

# Remove eatmydata
sudo rm $FILESYSTEM_ROOT/etc/apt/apt.conf.d/00image-install-eatmydata $FILESYSTEM_ROOT/usr/local/bin/dpkg
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y remove eatmydata

## Clean up apt
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y autoremove
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get autoclean
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get clean
sudo LANG=C chroot $FILESYSTEM_ROOT bash -c 'rm -rf /usr/share/doc/* /usr/share/locale/* /var/lib/apt/lists/* /tmp/*'

## Clean up proxy
[ -n "$http_proxy" ] && sudo rm -f $FILESYSTEM_ROOT/etc/apt/apt.conf.d/01proxy

## Clean up pip cache
sudo LANG=C chroot $FILESYSTEM_ROOT pip3 cache purge

## Umount all
echo '[INFO] Umount all'
## Display all process details access /proc
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -vm /proc
## Kill the processes
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -km /proc || true
## Wait fuser fully kill the processes
sleep 15
sudo LANG=C chroot $FILESYSTEM_ROOT umount /proc || true

## Prepare empty directory to trigger mount move in initramfs-tools/mount_loop_root, implemented by patching
sudo mkdir $FILESYSTEM_ROOT/host

## Compress most file system into squashfs file
sudo rm -f $ONIE_INSTALLER_PAYLOAD $FILESYSTEM_SQUASHFS
## Output the file system total size for diag purpose
## Note: -x to skip directories on different file systems, such as /proc
sudo du -hsx $FILESYSTEM_ROOT
sudo mkdir -p $FILESYSTEM_ROOT/var/lib/docker
sudo cp files/image_config/resolv-config/resolv.conf $FILESYSTEM_ROOT/etc/resolv.conf
sudo mksquashfs $FILESYSTEM_ROOT $FILESYSTEM_SQUASHFS -comp zstd -b 1M -e boot -e var/lib/docker -e $PLATFORM_DIR

# Ensure admin gid is 1000
gid_user=$(sudo LANG=C chroot $FILESYSTEM_ROOT id -g $USERNAME) || gid_user="none"
if [ "${gid_user}" != "1000" ]; then
    die "expect gid 1000. current:${gid_user}"
fi

# ALERT: This bit of logic tears down the qemu based build environment used to
# perform builds for the ARM architecture. This must be the last step in this
# script before creating the Sonic installer payload zip file.
if [[ $MULTIARCH_QEMU_ENVIRON == y || $CROSS_BUILD_ENVIRON == y ]]; then
    # Remove qemu arm bin executable used for cross-building
    sudo rm -f $FILESYSTEM_ROOT/usr/bin/qemu*static || true
    DOCKERFS_PATH=../dockerfs/
fi

## Compress docker files
pushd $FILESYSTEM_ROOT && sudo tar -I $GZ_COMPRESS_PROGRAM -cf $OLDPWD/$FILESYSTEM_DOCKERFS -C ${DOCKERFS_PATH}var/lib/docker .; popd

## Compress together with /boot, /var/lib/docker and $PLATFORM_DIR as an installer payload zip file
pushd $FILESYSTEM_ROOT && sudo tar -I $GZ_COMPRESS_PROGRAM -cf platform.tar.gz -C $PLATFORM_DIR . && sudo zip -n .gz $OLDPWD/$ONIE_INSTALLER_PAYLOAD -r boot/ platform.tar.gz; popd
sudo zip -g -n .squashfs:.gz $ONIE_INSTALLER_PAYLOAD $FILESYSTEM_SQUASHFS $FILESYSTEM_DOCKERFS
