"""Write one boot image to a Galaxy S9+ (star2lte) from its running TWRP.

    python scripts/flash/flash_s9plus_boot_adb.py dist/uniloader/<image>.img

The image must lie under dist/. The script checks the device, the BOOT
mapping and the size, verifies the copy on the phone, writes BOOT, reads it
back and only then reboots. RECOVERY is never touched.
"""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[2]
# adb binary: S9PLUS_ADB, else whatever is on PATH.
ADB = os.environ.get("S9PLUS_ADB", "adb")


def find_serial():
    """Every call names the S9+ explicitly, so no other attached phone is ever
    touched. S9PLUS_SERIAL wins; otherwise exactly one star2lte must be on adb."""
    serial = os.environ.get("S9PLUS_SERIAL")
    if serial:
        return serial
    listing = subprocess.run([str(ADB), "devices", "-l"], capture_output=True,
                             text=True, check=True).stdout.splitlines()[1:]
    hits = [line.split()[0] for line in listing if "device:star2lte" in line]
    if len(hits) != 1:
        raise SystemExit(f"{len(hits)} Galaxy S9+ (star2lte) devices on adb - "
                         "set S9PLUS_SERIAL to the one to write")
    return hits[0]


SERIAL = find_serial()
BOOT = "/dev/block/platform/11120000.ufs/by-name/BOOT"


def adb(*args):
    return subprocess.check_output([str(ADB), "-s", SERIAL, *args], text=True).strip()


image = Path(sys.argv[1]).resolve()
assert image.is_relative_to((PROJECT / "dist").resolve()), "Image must be in this S9+ project"
blob = image.read_bytes()
assert blob[:8] == b"ANDROID!", "Not an Android-format boot image"
assert struct.unpack_from("<I", blob, 36)[0] == 2048, "Unexpected page size"
assert adb("get-state") == "recovery", "Samsung is not in recovery"
assert adb("shell", "getprop ro.product.device") == "star2lte", "Wrong device"
assert adb("shell", "id -u") == "0", "Recovery is not root"
assert adb("shell", f"readlink -f {BOOT}") == "/dev/block/sda10", "BOOT mapping changed"
assert len(blob) <= int(adb("shell", f"blockdev --getsize64 {BOOT}")), "Image does not fit"
expected = hashlib.sha256(blob).hexdigest()
remote = "/tmp/s9plus-native-boot.img"
print(adb("push", str(image), remote))
assert adb("shell", f"sha256sum {remote}").split()[0] == expected, "USB copy checksum mismatch"
print(adb("shell", f"dd if={remote} of={BOOT} bs=1048576 && sync"))
actual = adb("shell", f"head -c {len(blob)} {BOOT} | sha256sum").split()[0]
assert actual == expected, "BOOT readback checksum mismatch; left in recovery"
print(f"BOOT_READBACK_VERIFIED sha256={expected} bytes={len(blob)}", flush=True)
print(adb("reboot"))
