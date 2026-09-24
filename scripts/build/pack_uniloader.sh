#!/bin/bash
# Take the kernel and device tree from a build71 output directory, wrap them in
# uniLoader, and leave a flashable boot image behind.
#
#   TWRP_IMG=<twrp-3.3.1-0-star2lte.img> pack_uniloader.sh <dist/m71-...> <output name> [defconfig]
#
# The boot image copies its header layout and its DTBH table from the
# official TWRP 3.3.1-0 image for star2lte (twrp.me), an image this phone's
# bootloader is known to accept. The kernel sees none of it: uniLoader hands
# over its own device tree. The TWRP image this port was validated with has
# SHA-256 5b5d2290940203316024a94581107ffad17670bb2f596fd27ef483d3d2685994.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
mount_build
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC="$1"
NAME="${2:-boot-uniloader.img}"
DEFCONFIG="${3:-star2lte_defconfig}"
REFERENCE="${TWRP_IMG:-${BOOT_REFERENCE:-}}"
test -f "$REFERENCE" || { echo "set TWRP_IMG to twrp-3.3.1-0-star2lte.img"; exit 1; }

[[ "$SRC" = /* ]] || SRC="$ROOT/$SRC"
[[ "$NAME" = "$(basename "$NAME")" && "$NAME" = *.img ]] || exit 1
test ! -e "$ROOT/dist/uniloader/$NAME" || { echo "output already exists: $NAME"; exit 1; }
python3 "$ROOT/scripts/build/stage_uniloader_inputs.py" "$SRC" "$ROOT/dist/uniloader-in"

bash "$ROOT/scripts/build/build_uniloader.sh" "$DEFCONFIG" >/dev/null
echo "uniLoader: $(stat -c %s "$ROOT/dist/uniloader/uniLoader") bytes"

# The DTBH table out of the TWRP image, and the 20-byte empty gzip the
# validated images carry as their ramdisk (XFL 2, OS 255, mtime 0).
PARTS="$ROOT/dist/uniloader/parts"
mkdir -p "$PARTS"
python3 -c '
import gzip, sys
sys.path.insert(0, sys.argv[1])
from boot_parts import parts
p = parts(open(sys.argv[2], "rb").read())
open(sys.argv[3] + "/dt.img", "wb").write(p["dt"])
open(sys.argv[3] + "/ramdisk.gz", "wb").write(gzip.compress(b"", compresslevel=9, mtime=0))
' "$ROOT/scripts/build" "$REFERENCE" "$PARTS"

python3 "$ROOT/scripts/build/mkboot.py" \
	--ref "$REFERENCE" \
	--kernel "$ROOT/dist/uniloader/uniLoader" \
	--ramdisk "$PARTS/ramdisk.gz" \
	--dt "$PARTS/dt.img" \
	--cmdline "console=tty0" \
	-o "$ROOT/dist/uniloader/$NAME"
cp "$ROOT/dist/uniloader-in/inputs.json" "$ROOT/dist/uniloader/$NAME.inputs.json"
cp "$ROOT/dist/uniloader/uniLoader.config" "$ROOT/dist/uniloader/$NAME.loader.config"
cp "$ROOT/dist/uniloader/uniLoader.elf" "$ROOT/dist/uniloader/$NAME.loader.elf"
sha256sum "$ROOT/dist/uniloader/$NAME" > "$ROOT/dist/uniloader/$NAME.sha256"
sync
