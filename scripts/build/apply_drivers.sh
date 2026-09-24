#!/bin/bash
# Install this port's own drivers into the mainline tree. Idempotent: it runs
# before every build.
set -uo pipefail
PROJ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$PROJ/scripts/build/env.sh"
SRC="${1:-$BUILD/src/mainline}"

echo "--- UFS (Exynos 9810) ---"
install -m644 "$PROJ/src/ufs/ufs-exynos9810.c" "$PROJ/src/ufs/ufs-cal-9810.c" \
	"$PROJ/src/ufs/ufs-cal-9810.h" "$SRC/drivers/ufs/host/" || exit 1
sed -i 's/\r$//' "$SRC/drivers/ufs/host/ufs-exynos9810.c" \
	"$SRC/drivers/ufs/host/ufs-cal-9810.c" "$SRC/drivers/ufs/host/ufs-cal-9810.h"

echo "--- clock gates opened by hand, G3D power domain, MAX77705 USB switch ---"
install -m644 "$PROJ/src/soc/s9p-clkgate.c" "$PROJ/src/soc/s9p-g3d-pd.c" \
	"$PROJ/src/soc/s9p-max77705-muic.c" \
	"$SRC/drivers/soc/samsung/" || exit 1
sed -i 's/\r$//' "$SRC/drivers/soc/samsung/s9p-clkgate.c" \
	"$SRC/drivers/soc/samsung/s9p-g3d-pd.c" \
	"$SRC/drivers/soc/samsung/s9p-max77705-muic.c"

echo "--- USB 2.0 PHY (vendor CAL sequence for PHY revision 0x300) ---"
install -m644 "$PROJ/src/usb/phy-exynos9810-usbdrd.c" "$SRC/drivers/phy/samsung/" || exit 1
sed -i 's/\r$//' "$SRC/drivers/phy/samsung/phy-exynos9810-usbdrd.c"

echo "--- MAX77705 charger with charge_behaviour ---"
# Replaces the upstream driver so userspace can stop/resume charging via
# /sys/class/power_supply/max77705-charger/charge_behaviour. The src copy is
# pinned to the mainline version this tree was fetched with; re-check after a
# rebase. Guarded: only replace when the tree's file still matches the pinned
# upstream reference, otherwise leave it alone so a rebase cannot be patched
# with stale code silently.
ref="$PROJ/src/reference/max77705_charger.c"     # torvalds/linux v7.1, unmodified
if ! cmp -s "$ref" "$SRC/drivers/power/supply/max77705_charger.c"; then
	if cmp -s "$PROJ/src/soc/max77705_charger.c" "$SRC/drivers/power/supply/max77705_charger.c"; then
		: # already installed by us
	else
		echo "MAX77705 upstream driver drifted from the pinned reference —"
		echo "update src/soc/max77705_charger.c before building."
		exit 1
	fi
fi
install -m644 "$PROJ/src/soc/max77705_charger.c" "$SRC/drivers/power/supply/max77705_charger.c" || exit 1
sed -i 's/\r$//' "$SRC/drivers/power/supply/max77705_charger.c"


echo "--- PCIe root complex (WiFi), vendor PHY CAL ---"
install -m644 "$PROJ/src/pci/pcie-exynos9810.c" "$SRC/drivers/pci/controller/dwc/" || exit 1
sed -i 's/\r$//' "$SRC/drivers/pci/controller/dwc/pcie-exynos9810.c"

echo "--- display: bootloader framebuffer as a KMS device named exynos ---"
# Mesa pairs a display-only KMS driver with a render node only when the display
# driver's name is on its kmsro list. "simpledrm" is not on it, "exynos" is.
# The code is otherwise simpledrm verbatim, regenerated from the tree on every
# build so it cannot drift from the kernel it is compiled against.
sed -e 's/simpledrm/exynos_bootfb/g' \
    -e 's/#define DRIVER_NAME\t"exynos_bootfb"/#define DRIVER_NAME\t"exynos"/' \
    -e 's/DRM driver for simple-framebuffer platform devices/DRM driver for the framebuffer an Exynos bootloader leaves running/' \
    "$SRC/drivers/gpu/drm/sysfb/simpledrm.c" > "$SRC/drivers/gpu/drm/sysfb/exynos-bootfb.c" || exit 1
grep -q '#define DRIVER_NAME	"exynos"' "$SRC/drivers/gpu/drm/sysfb/exynos-bootfb.c" || {
	echo "DRIVER_NAME rename failed"
	grep -n 'define DRIVER_NAME' "$SRC/drivers/gpu/drm/sysfb/exynos-bootfb.c"
	exit 1
}

echo "--- ACPM mailbox (PMIC voltages), G3D stock clock, cpufreq ---"
install -m644 "$PROJ/src/soc/s9p-acpm.c" "$PROJ/src/soc/s9p-g3d.c" \
	"$SRC/drivers/soc/samsung/" || exit 1
install -m644 "$PROJ/src/soc/s9p-acpm.h" "$SRC/include/linux/soc/samsung/" || exit 1
install -m644 "$PROJ/src/cpufreq/s9p-cpufreq.c" "$SRC/drivers/cpufreq/" || exit 1
sed -i 's/\r$//' "$SRC/drivers/soc/samsung/s9p-acpm.c" \
	"$SRC/drivers/soc/samsung/s9p-g3d.c" \
	"$SRC/include/linux/soc/samsung/s9p-acpm.h" \
	"$SRC/drivers/cpufreq/s9p-cpufreq.c"

echo "--- display: DECON scanout takeover ---"
mkdir -p "$SRC/drivers/gpu/drm/s9p"
install -m644 "$PROJ/src/gpu/drm/s9p/s9p-decon.c" \
	"$PROJ/src/gpu/drm/s9p/Kconfig" \
	"$PROJ/src/gpu/drm/s9p/Makefile" "$SRC/drivers/gpu/drm/s9p/" || exit 1
sed -i 's/\r$//' "$SRC/drivers/gpu/drm/s9p/s9p-decon.c" \
	"$SRC/drivers/gpu/drm/s9p/Kconfig" "$SRC/drivers/gpu/drm/s9p/Makefile"

python3 "$PROJ/scripts/build/patch_tree.py" "$SRC" || exit 1
echo "APPLY_DRIVERS_OK"
