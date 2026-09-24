#!/bin/bash
# One-time: create the 70 GB ext4 build image (BUILD_IMG) and mount it at
# BUILD. See env.sh; on a plain Linux host a directory is enough.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
IMG=$BUILD_IMG
MNT=$BUILD
if [ ! -f "$IMG" ]; then
  truncate -s 70G "$IMG"
  mkfs.ext4 -q -F -m 0 "$IMG"
  echo "IMAGE_CREATED"
fi
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o loop "$IMG" "$MNT"
df -h "$MNT" | tail -1
mkdir -p "$MNT/src" "$MNT/out" "$MNT/rootfs"
echo SETUP_OK
