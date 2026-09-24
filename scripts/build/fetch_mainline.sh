#!/bin/bash
# Fetch the mainline 7.1 tree into $BUILD/src/mainline (shallow clone of the
# v7.1 tag). The port's drivers and in-tree edits are applied by build71.sh.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
mount_build || exit 1
mkdir -p "$BUILD/src/mainline"
cd "$BUILD/src"

if [ ! -d mainline/.git ]; then
	for tag in v7.1 v7.0 master; do
		echo "trying $tag"
		if git clone --depth 1 --branch "$tag" \
		    https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
		    mainline 2>&1 | tail -3; then
			break
		fi
		rm -rf mainline
	done
fi

cd mainline
git log -1 --format='%H %s'
make kernelversion
ls arch/arm64/boot/dts/exynos/ | grep 9810
# WSL can shut the distro down between invocations, and anything still
# dirty in the loop image's page cache is lost with it.
sync
echo MAINLINE_READY
