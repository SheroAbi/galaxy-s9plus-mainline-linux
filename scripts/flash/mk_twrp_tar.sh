#!/bin/bash
# Smallest possible Odin package: TWRP for RECOVERY only. sboot keeps the
# recovery flag it was once given, so whatever sits on RECOVERY is what every
# boot lands in -- putting TWRP back there is the one write that matters.
#
#   TWRP_IMG=<twrp-3.3.1-0-star2lte.img> mk_twrp_tar.sh
set -euo pipefail
: "${TWRP_IMG:?set TWRP_IMG to twrp-3.3.1-0-star2lte.img}"
TWRP_IMG=$(readlink -f "$TWRP_IMG")
. "$(dirname "${BASH_SOURCE[0]}")/../build/env.sh"
mount_build
D="$BUILD/dist/rescue-twrp"
rm -rf "$D"
mkdir -p "$D"
cd "$D"
cp "$TWRP_IMG" recovery.img
tar -H ustar -cf AP_twrp.tar recovery.img
md5sum -t AP_twrp.tar >> AP_twrp.tar
mv AP_twrp.tar AP_twrp.tar.md5
rm -f recovery.img
ls -l "$D"
sync
echo TWRP_TAR_OK
