#!/bin/bash
# Re-apply overlay/ to the staged rootfs and to out/rootfs.img, enable its
# services, and copy the image to NATIVE_OUT for flashing
# (default: next to the build image).
set -euo pipefail
PROJ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$(dirname "${BASH_SOURCE[0]}")/../build/env.sh"
mount_build
NATIVE_OUT=${NATIVE_OUT:-$(dirname "$BUILD_IMG")/s9plus-native-install}
test "$(e2label "$BUILD/out/rootfs.img")" = s9plus-root
MOUNT=$(mktemp -d /mnt/s9plus-rootfs.XXXXXXXX)
cleanup() {
    if mountpoint -q "$MOUNT"; then umount "$MOUNT"; fi
    rmdir "$MOUNT"
}
trap cleanup EXIT
mount -o loop "$BUILD/out/rootfs.img" "$MOUNT"
for ROOT in "$BUILD/rootfs/noble" "$MOUNT"; do
    test -f "$ROOT/etc/os-release"
    cp -a "$PROJ/overlay/." "$ROOT/"
    # Windows source files have permissive synthetic mode bits on drvfs.
    # Apply normal Linux modes to exactly the copied overlay paths.
    while IFS= read -r -d '' ENTRY; do
        RELATIVE=${ENTRY#"$PROJ/overlay"}
        chmod 755 "$ROOT$RELATIVE"
    done < <(find "$PROJ/overlay" -type d -print0)
    while IFS= read -r -d '' ENTRY; do
        RELATIVE=${ENTRY#"$PROJ/overlay/"}
        chmod 644 "$ROOT/$RELATIVE"
    done < <(find "$PROJ/overlay" -type f -print0)
    find "$ROOT/usr/local/sbin" "$ROOT/etc/systemd/system" "$ROOT/etc/NetworkManager" \
        -type f -exec sed -i 's/\r$//' {} +
    chmod 755 "$ROOT/usr/local/sbin/usb-gadget" "$ROOT/usr/local/sbin/s9p-stability" \
        "$ROOT/usr/local/sbin/s9p-blackbox" "$ROOT/usr/local/sbin/s9p-wifi-guard" \
        "$ROOT/usr/local/sbin/s9p-power"
    chmod 600 "$ROOT/etc/NetworkManager/system-connections/usb0.nmconnection"
    rm -f "$ROOT/etc/systemd/system/sysinit.target.wants/usb-gadget.service"
    systemctl --root="$ROOT" enable usb-gadget.service s9p-stability.service \
        s9p-blackbox.service s9p-wifi-guard.service
    # Suspend never resumes on this port (the M3 cores do not come back).
    systemctl --root="$ROOT" mask sleep.target suspend.target hibernate.target \
        hybrid-sleep.target suspend-then-hibernate.target
    bash -n "$ROOT/usr/local/sbin/usb-gadget"
done
sync
umount "$MOUNT"
set +e
e2fsck -f -p "$BUILD/out/rootfs.img"
RC=$?
set -e
test "$RC" -le 1
mkdir -p "$NATIVE_OUT"
cp --sparse=always "$BUILD/out/rootfs.img" "$NATIVE_OUT/ubuntu-rootfs.img"
(cd "$NATIVE_OUT" && sha256sum ubuntu-rootfs.img > ubuntu-rootfs.img.sha256)
stat -c 'ROOTFS_READY=%n SIZE=%s' "$NATIVE_OUT/ubuntu-rootfs.img"
