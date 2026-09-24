#!/bin/bash
# Pack the rootfs from rootfs_stage1/2 as rootfs.img, a sparse userdata.img
# and Odin tars in $BUILD/dist.
#
# The stable kernel has every driver built in. For a WLAN=m build, point
# MODULES at dist/m71-<stamp>/modules to copy its modules into the rootfs.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../build/env.sh"
mount_build
R=$BUILD/rootfs/noble
O=$BUILD/out
DIST=$BUILD/dist
mkdir -p "$DIST"

# ---------- kernel modules into the rootfs (only for WLAN=m builds) ----------
if [ -n "${MODULES:-}" ]; then
	rm -rf "$R/lib/modules"
	mkdir -p "$R/lib/modules"
	cp -a "$MODULES/." "$R/lib/modules/"
	KVER=$(ls "$R/lib/modules" | head -1)
	echo "kernel modules: $KVER ($(find "$R/lib/modules" -name '*.ko' | wc -l) .ko)"
	rm -f "$R/lib/modules/$KVER/build" "$R/lib/modules/$KVER/source"
	depmod -b "$R" "$KVER"
fi

# ---------- rootfs image ----------
USED_KB=$(du -sk --exclude=./proc --exclude=./sys "$R" 2>/dev/null | tail -1 | cut -f1)
SIZE_MB=$(( USED_KB / 1024 * 130 / 100 + 700 ))
echo "rootfs used: $((USED_KB/1024)) MiB -> image ${SIZE_MB} MiB"
rm -f "$O/rootfs.img"
truncate -s "${SIZE_MB}M" "$O/rootfs.img"
mkfs.ext4 -q -F -L s9plus-root -O ^metadata_csum_seed -m 1 "$O/rootfs.img"
rm -rf /mnt/rfs && mkdir -p /mnt/rfs
mount -o loop "$O/rootfs.img" /mnt/rfs
tar -C "$R" --exclude=./proc/\* --exclude=./sys/\* --exclude=./dev/pts/\* \
    --exclude=./run/\* --exclude=./tmp/\* --exclude=./.debootstrap_done \
    --exclude=./.stage2_done -cf - . | tar -C /mnt/rfs -xf -
sync
df -h /mnt/rfs | tail -1
umount /mnt/rfs
e2fsck -fp "$O/rootfs.img" >/dev/null 2>&1 || true

# ---------- sparse image for Odin/Thor ----------
img2simg "$O/rootfs.img" "$DIST/userdata.img"
cp "$O/boot.img" "$DIST/boot.img"
ls -la "$DIST"

# ---------- Odin tar ----------
# Thor's flashTar wants a directory of Odin-style AP/BL/CP/CSC tars.
cd "$DIST"
rm -rf flash-full && mkdir flash-full
tar -H ustar -cf flash-full/AP_s9plus_full.tar boot.img userdata.img
( cd flash-full && md5sum -t AP_s9plus_full.tar >> AP_s9plus_full.tar   && mv AP_s9plus_full.tar AP_s9plus_full.tar.md5 )
rm -rf flash-boot && mkdir flash-boot
tar -H ustar -cf flash-boot/AP_s9plus_boot.tar boot.img
( cd flash-boot && md5sum -t AP_s9plus_boot.tar >> AP_s9plus_boot.tar   && mv AP_s9plus_boot.tar AP_s9plus_boot.tar.md5 )
ls -laR "$DIST" | head -30
echo IMAGES_OK
