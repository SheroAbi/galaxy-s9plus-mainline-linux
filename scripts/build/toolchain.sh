#!/bin/bash
# One-time: the cross toolchain and host tools (Ubuntu 24.04 host), then the
# static arm64 busybox for the initramfs. Nothing else is downloaded: the
# boot image and the DTBH table are written by mkboot.py and mkdtbh.py.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev libncurses-dev \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  clang lld llvm \
  device-tree-compiler python3 python3-pip git wget curl ca-certificates \
  debootstrap qemu-user-static binfmt-support \
  cpio gzip lz4 zstd xz-utils rsync kmod fakeroot \
  e2fsprogs dosfstools android-sdk-libsparse-utils 2>&1 | tail -5
echo "--- versions ---"
aarch64-linux-gnu-gcc --version | head -1
clang --version | head -1
dtc --version
debootstrap --version
echo "--- busybox for the initramfs ---"
mount_build
if [ ! -x "$BUILD/out/busybox-arm64" ]; then
  python3 "$(dirname "${BASH_SOURCE[0]}")/fetch_busybox.py" "$BUILD/out/busybox-arm64"
fi
echo TOOLCHAIN_OK
