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
echo '[INFO] Eden -build debian base: Default user'
[ -n "$USERNAME" ] || {
    echo "Error: no or empty USERNAME"
    exit 1
}

## Password for the default user
echo '[INFO] Eden -build debian base: Password for the default user'
[ -n "$PASSWORD" ] || {
    echo "Error: no or empty PASSWORD"
    exit 1
}

## Include common functions
echo '[INFO] Eden -build debian base: Include common functions'
. functions.sh

## Enable debug output for script
echo '[INFO] Eden -build debian base: Enable debug output for script'
set -x -e

CONFIGURED_ARCH=$([ -f .arch ] && cat .arch || echo amd64)

## docker engine version (with platform)
echo '[INFO] Eden -build debian base: docker engine version (with platform)'
DOCKER_VERSION=5:20.10.14~3-0~debian-$IMAGE_DISTRO
CONTAINERD_IO_VERSION=1.5.11-1
LINUX_KERNEL_VERSION=5.10.0-18-2

## Working directory to prepare the file system
echo '[INFO] Eden -build debian base: Working directory to prepare the file system'
FILESYSTEM_ROOT=./fsroot
PLATFORM_DIR=platform
## Hostname for the linux image
HOSTNAME=sonic
DEFAULT_USERINFO="Default admin user,,,"
BUILD_TOOL_PATH=src/sonic-build-hooks/buildinfo
TRUSTED_GPG_DIR=$BUILD_TOOL_PATH/trusted.gpg.d

## Read ONIE image related config file
echo '[INFO] Eden -build debian base: Read ONIE image related config file'
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
echo '[INFO] Eden -build debian base: Prepare the file system directory'
if [[ -d $FILESYSTEM_ROOT ]]; then
    sudo rm -rf $FILESYSTEM_ROOT || die "Failed to clean chroot directory"
fi
echo '[INFO] Eden -build debian base: mkdir'
mkdir -p $FILESYSTEM_ROOT
mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR
mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/grub
touch $FILESYSTEM_ROOT/$PLATFORM_DIR/firsttime

## ensure proc is mounted
echo '[INFO] Eden -build debian base: ensure proc is mounted'
sudo mount proc /proc -t proc || true

## make / as a mountpoint in chroot env, needed by dockerd
echo '[INFO] Eden -build debian base: make / as a mountpoint in chroot env, needed by dockerd'
pushd $FILESYSTEM_ROOT
sudo mount --bind . .
popd

## Build the host debian base system
echo '[INFO] Build host debian base system...'
TARGET_PATH=$TARGET_PATH scripts/build_debian_base_system.sh $CONFIGURED_ARCH $IMAGE_DISTRO $FILESYSTEM_ROOT

# Prepare buildinfo
sudo scripts/prepare_debian_image_buildinfo.sh $CONFIGURED_ARCH $IMAGE_DISTRO $FILESYSTEM_ROOT $http_proxy

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
sudo rm -f sonic.squashfs
sudo mksquashfs $FILESYSTEM_ROOT sonic.squashfs -e boot -e var/lib/docker -e $PLATFORM_DIR
pushd $FILESYSTEM_ROOT && zip $OLDPWD/$TARGET_PATH/basefs.zip -r boot/ $PLATFORM_DIR/; popd
date