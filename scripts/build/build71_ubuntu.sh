#!/bin/bash
# Build the Ubuntu boot image (kernel + uniLoader wrapper) in one go.
#
#   build71_ubuntu.sh <image name> [GPU=1] [TESTRUN=seconds] [GADGET=configfs] [CMDLINE_EXTRA="mem=1700M"]
#
# The image name is the file that ends up in dist/uniloader/. TESTRUN adds
# s9p_testrun=N to the command line: the rootfs service then reboots into TWRP
# after N seconds so the logs can be pulled without touching the phone.
set -uo pipefail
PROJ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NAME="${1:?image name}"
shift
GPU_FLAG=""
TESTRUN=""
GADGET_MODE="serial"
EXTRA=""
for a in "$@"; do
	case "$a" in
		GPU=1) GPU_FLAG=1 ;;
		CMDLINE_EXTRA=*) EXTRA="${a#CMDLINE_EXTRA=}" ;;
		TESTRUN=*) TESTRUN="${a#TESTRUN=}" ;;
		GADGET=*) GADGET_MODE="${a#GADGET=}" ;;
	esac
done

CMD="console=tty0 loglevel=8 panic=5 earlycon=s9pram keep_bootcon maxcpus=8 s9p_late_ramlog s9p_vendor_m3_defaults"
[ -n "$TESTRUN" ] && CMD="$CMD s9p_testrun=$TESTRUN"
[ -n "$EXTRA" ] && CMD="$CMD $EXTRA"

echo "=== build: $NAME (GPU=${GPU_FLAG:-0} TESTRUN=${TESTRUN:-off} GADGET=$GADGET_MODE) ==="
OUT=$(INIT=boot UFS=1 GPU="$GPU_FLAG" GADGET="$GADGET_MODE" BOOT_CMDLINE="$CMD" bash "$PROJ/scripts/build/build71.sh" 2>&1 | tee /dev/stderr | sed -n 's/^BUILD71_OK //p')
if [ -z "$OUT" ]; then
	echo "BUILD FAILED"
	exit 1
fi
echo "=== pack: $OUT -> $NAME ==="
rm -f "$PROJ/dist/uniloader/$NAME"
bash "$PROJ/scripts/build/pack_uniloader.sh" "$OUT" "$NAME" || { echo "PACK FAILED"; exit 1; }
ls -l "$PROJ/dist/uniloader/$NAME"
cat "$PROJ/dist/uniloader/$NAME.sha256"
sync
echo "UBUNTU_IMAGE_OK $PROJ/dist/uniloader/$NAME"
