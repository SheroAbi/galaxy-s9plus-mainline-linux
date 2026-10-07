# Build locations shared by the scripts in scripts/. Source it, then call
# mount_build. Every value can be overridden from the environment.
#
# BUILD      where the kernel tree (src/mainline), the rootfs (rootfs/noble)
#            and intermediate output (out/) live. On a plain Linux host this
#            is an ordinary directory and nothing else is needed.
# BUILD_IMG  an ext4 loop image that is mounted at BUILD if BUILD is not
#            mounted yet. Only for WSL: there the project sits on a DrvFs
#            mount, which is far too slow for a kernel tree and cannot hold
#            its symlinks and permissions. Empty (the default on Linux) means
#            no image. Under WSL it defaults to /mnt/e/s9plus-build.img when
#            that drive exists, which is the reference setup.
BUILD=${BUILD:-/mnt/build}
if [ -z "${BUILD_IMG+set}" ]; then
	BUILD_IMG=
	if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && [ -d /mnt/e ]; then
		BUILD_IMG=/mnt/e/s9plus-build.img
	fi
fi

mount_build() {
	if [ -n "$BUILD_IMG" ] && ! mountpoint -q "$BUILD" && [ -f "$BUILD_IMG" ]; then
		mkdir -p "$BUILD"
		mount -o loop "$BUILD_IMG" "$BUILD"
	fi
	if [ -n "$BUILD_IMG" ] && mountpoint -q "$BUILD"; then
		mount -o remount,rw "$BUILD"
	fi
	[ -d "$BUILD" ] || { echo "no build directory: $BUILD (run scripts/build/setup_build.sh, or set BUILD)" >&2; return 1; }
}
