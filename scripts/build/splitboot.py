"""Split an Android boot image into its parts.

Used to take the one image this phone's bootloader is known to accept apart,
so pieces of it can be recombined with ours and the rejection bisected.

  splitboot.py <boot.img> <outdir>
"""
import struct
import sys
from pathlib import Path


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    b = src.read_bytes()
    assert b[:8] == b"ANDROID!", "not an Android boot image"
    ks, ka, rs, ra, ss, sa, ta, ps, dts = struct.unpack_from("<9I", b, 8)

    def up(n):
        return (n + ps - 1) // ps * ps

    off = ps
    for name, size in (("kernel", ks), ("ramdisk", rs),
                       ("second", ss), ("dt.img", dts)):
        if size:
            (out / name).write_bytes(b[off:off + size])
            print(f"  {name:<8} {size:>12,}  @ {off:,}")
        off += up(size)

    tail = b[off:off + 16]
    print(f"  trailer  {tail!r}")
    print(f"  payload ends at {off:,} of {len(b):,}")


if __name__ == "__main__":
    main()
