#!/bin/bash
# Build uniLoader with our mainline kernel inside it.
#
# Why this exists: S-Boot does not hand a mainline arm64 kernel a working
# environment on this SoC. Two things it gets wrong are known and fixed here
# by going through a shim:
#
#   * it leaves DECON's HW_SW_TRIG_CONTROL unset, so nothing written to the
#     framebuffer at 0xcc000000 ever reaches the panel -- which is why a stub
#     that painted the screen looked dead while it was in fact running;
#   * it keeps its own structures at 0x80000000 (sec_debug_magic,
#     kaslr_region), right where a kernel loaded by its text_offset lands.
#
# uniLoader sets the trigger, relocates the kernel to 0x90000000, and jumps
# there -- and prints to the panel on the way, which finally gives this port a
# console.
#
# Runs in Ubuntu-24.04: that is the distro with the cross toolchain. The build
# is staged into the distro's own filesystem because Kbuild cannot cope with
# the space in the project path ("9T ubuntu") -- it splits the variable and
# dies with "empty variable name".
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STAGE=/tmp/uniloader-build
DEFCONFIG="${1:-star2lte_defconfig}"
CROSS=aarch64-linux-gnu-

LOADER_SRC="${UNILOADER_SRC:-$ROOT/bootloader/uniLoader}"
test -d "$LOADER_SRC" || { echo "no uniLoader tree: $LOADER_SRC"; exit 1; }
test -f "$ROOT/dist/uniloader-in/Image" || { echo "missing dist/uniloader-in/Image"; exit 1; }
test -f "$ROOT/dist/uniloader-in/dtb" || { echo "missing dist/uniloader-in/dtb"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$LOADER_SRC/." "$STAGE/"
cd "$STAGE"

mkdir -p blob
cp "$ROOT/dist/uniloader-in/Image" blob/Image
cp "$ROOT/dist/uniloader-in/dtb" blob/dtb
# uniLoader always copies a ramdisk blob to CONFIG_RAMDISK_ENTRY, so one has
# to exist, and it points the kernel at it with linux,initrd-start/end. Our
# kernel carries its own initramfs inside the image, so nothing here is used.
#
# Do not "improve" this into a real empty cpio archive. Swapping the 20-byte
# empty gzip for a 50-byte empty cpio.gz is what turned a booting kernel into
# one that hangs before the console -- it was changed in the same edit as a
# driver fix, which sent the next hour of debugging after the wrong change.
# The kernel's complaint about "junk at the end of compressed archive" is
# cosmetic; this is not.
printf '' | gzip -n > blob/ramdisk

echo "=== blob ==="
ls -l blob/

make ARCH=aarch64 CROSS_COMPILE=$CROSS "$DEFCONFIG"
make ARCH=aarch64 CROSS_COMPILE=$CROSS -j"$(nproc)"

echo "=== output ==="
find . -maxdepth 2 \( -name "uniLoader*" -o -name "*.bin" -o -name "*.elf" \) \
	! -name "*.o" -printf '%s\t%p\n' | sort -rn | head

mkdir -p "$ROOT/dist/uniloader"
for f in uniLoader.bin uniLoader.elf uniLoader; do
	[ -f "$f" ] && cp "$f" "$ROOT/dist/uniloader/"
done
cp .config "$ROOT/dist/uniloader/uniLoader.config"
cp uniLoader.o "$ROOT/dist/uniloader/uniLoader.elf"
ls -l "$ROOT/dist/uniloader/" 2>/dev/null || true
