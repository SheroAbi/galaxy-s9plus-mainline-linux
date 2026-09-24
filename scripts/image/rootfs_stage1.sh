#!/bin/bash
# debootstrap Ubuntu 24.04 (noble) arm64 into $BUILD/rootfs/noble.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../build/env.sh"
mount_build
R=$BUILD/rootfs/noble
if [ -f "$R/.debootstrap_done" ]; then echo "ALREADY_DONE"; exit 0; fi
rm -rf "$R"; mkdir -p "$R"
debootstrap --arch=arm64 --variant=minbase \
  --include=systemd,systemd-sysv,udev,dbus,kmod,ca-certificates,apt-utils,locales,tzdata \
  noble "$R" http://ports.ubuntu.com/ubuntu-ports 2>&1 | tail -20
touch "$R/.debootstrap_done"
du -sh "$R"
echo STAGE1_OK
