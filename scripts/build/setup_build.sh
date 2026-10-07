#!/bin/bash
# One-time: create the build directory BUILD (see env.sh). Under WSL, with
# BUILD_IMG set, it first creates the 70 GB ext4 image and mounts it there;
# on a plain Linux host a directory is all it takes.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
MNT=$BUILD
mkdir -p "$MNT"
if [ -n "$BUILD_IMG" ]; then
  if [ ! -f "$BUILD_IMG" ]; then
    mkdir -p "$(dirname "$BUILD_IMG")"
    truncate -s 70G "$BUILD_IMG"
    mkfs.ext4 -q -F -m 0 "$BUILD_IMG"
    echo "IMAGE_CREATED $BUILD_IMG"
  fi
  mountpoint -q "$MNT" || mount -o loop "$BUILD_IMG" "$MNT"
fi
df -h "$MNT" | tail -1
mkdir -p "$MNT/src" "$MNT/out" "$MNT/rootfs"
echo SETUP_OK
