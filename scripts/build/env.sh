# Build locations shared by the scripts in scripts/. Source it, then call
# mount_build. Every value can be overridden from the environment.
#
# BUILD      where the kernel tree (src/mainline), the rootfs (rootfs/noble),
#            the tools (tools/bin) and intermediate output (out/) live
# BUILD_IMG  an ext4 loop image that is mounted at BUILD if BUILD is not
#            mounted yet. On Windows/WSL the project sits on a DrvFs mount,
#            which is far too slow for a kernel tree and cannot hold its
#            symlinks and permissions, hence the image. On a plain Linux host,
#            point BUILD at any directory and the image is not used.
BUILD=${BUILD:-/mnt/build}
BUILD_IMG=${BUILD_IMG:-/mnt/e/s9plus-build.img}

mount_build() {
	if ! mountpoint -q "$BUILD" && [ -f "$BUILD_IMG" ]; then
		mkdir -p "$BUILD"
		mount -o loop "$BUILD_IMG" "$BUILD"
	fi
	if mountpoint -q "$BUILD"; then
		mount -o remount,rw "$BUILD"
	fi
	[ -d "$BUILD" ] || { echo "no build directory: $BUILD (set BUILD or BUILD_IMG)" >&2; return 1; }
}
