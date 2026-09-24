"""Extract the exact kernel/DTB from an archived build, never a mutable out/."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

from boot_parts import parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    ap.add_argument("destination", type=Path)
    args = ap.parse_args()
    source = args.source.resolve(strict=True)
    boot = source / "boot.img" if source.is_dir() else source
    data = parts(boot.read_bytes())
    kernel, table = data["kernel"], data["dt"]
    if kernel[56:60] != b"ARM\x64":
        raise ValueError("source must contain a raw arm64 kernel, not another loader")
    if table[:4] != b"DTBH" or struct.unpack_from("<II", table, 4) != (2, 1):
        raise ValueError("expected exactly one Samsung DTBH v2 device tree")
    chip, platform, subtype, rev, rev_end, offset, padded_size, flags = struct.unpack_from("<8I", table, 12)
    if chip != 0x2652 or not rev <= 26 <= rev_end:
        raise ValueError("DTBH does not select this Exynos9810 rev26 board")
    if table[offset:offset + 4] != b"\xd0\x0d\xfe\xed":
        raise ValueError("invalid DTB offset")
    size = struct.unpack_from(">I", table, offset + 4)[0]
    if size > padded_size or offset + size > len(table):
        raise ValueError("truncated device tree")
    dtb = table[offset:offset + size]
    if b"samsung,star2lte\0" not in dtb:
        raise ValueError("not a Galaxy S9+ device tree")
    args.destination.mkdir(parents=True, exist_ok=True)
    (args.destination / "Image").write_bytes(kernel)
    (args.destination / "dtb").write_bytes(dtb)
    manifest = {"source": str(boot), "source_sha256": hashlib.sha256(boot.read_bytes()).hexdigest(),
                "Image_sha256": hashlib.sha256(kernel).hexdigest(), "dtb_sha256": hashlib.sha256(dtb).hexdigest(),
                "Image_bytes": len(kernel), "dtb_bytes": len(dtb)}
    (args.destination / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest))


if __name__ == "__main__":
    main()
