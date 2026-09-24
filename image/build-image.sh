#!/bin/bash
# Build the Ubuntu 24.04 root filesystem for the Galaxy S9+ from scratch.
#
#   sudo image/build-image.sh
#
# Output in dist/image/: s9plus-rootfs.img (a raw ext4 image for USERDATA)
# and SHA256SUMS. The kernel is a separate boot image (docs/02-building.md);
# it has every driver built in, so the root filesystem carries no modules.
#
# Settings (user, password, time zone, keyboard, SSH key) are described in
# image/common/lib.sh. Optional features are not installed: see extras/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$REPO/image/common/lib.sh"
WORK=${WORK:-/var/tmp/s9plus-image}
OUT=${OUT:-$REPO/dist/image}

require_host
image_settings s9plus
R=$WORK/rootfs
trap chroot_umount EXIT

rootfs_bootstrap "$R"
chroot_mount "$R"
rootfs_install "$R" "$REPO/device/packages.txt"
rootfs_configure "$R"
rootfs_device "$R" "$REPO/device/base" "$REPO/device/configure.sh"
rootfs_finish "$R"
chroot_umount

mkdir -p "$OUT"
rm -f "$OUT/s9plus-rootfs.img" "$OUT/SHA256SUMS"
make_ext4 "$R" "$OUT/s9plus-rootfs.img" s9plus-root
checksums "$OUT"
log "done: flash $OUT/s9plus-rootfs.img to USERDATA (docs/03-installing.md)"
