"""Build an Android boot image, copying the layout of a reference image.

The build normally goes through mkbootimg inside WSL, but the stub is
assembled in a different distro than the one holding the build image, and the
format is simple enough that bouncing between them is not worth it. Copying
every header field from an image the phone has already accepted means the only
thing that differs is the payload under test.

  mkboot.py --ref <boot.img> --kernel <Image> [--dt <dt.img>]
            [--ramdisk <f>] [--cmdline "..."] -o <out.img>
"""
import argparse
import hashlib
import struct
from pathlib import Path

HEADER_SIZE = 1632


def image_id(kernel, ramdisk, second, dt):
    """The SHA1 mkbootimg stores at offset 576.

    sboot checks it. Copying a reference header without recomputing this gets
    the image rejected with INFORM3 = SEC_RESET_REASON_SECURE and a fallback
    boot into recovery -- which looks exactly like a kernel hanging at the
    logo, and cost a full round of misdiagnosis.
    """
    sha = hashlib.sha1()
    for part in (kernel, ramdisk, second):
        sha.update(part)
        sha.update(struct.pack("<I", len(part)))
    if dt:
        sha.update(dt)
        sha.update(struct.pack("<I", len(dt)))
    return sha.digest().ljust(32, b"\0")


def pad(data, page):
    over = len(data) % page
    return data + bytes(page - over) if over else data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True, help="image to copy header fields from")
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--dt")
    ap.add_argument("--ramdisk")
    ap.add_argument("--cmdline")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    ref = Path(args.ref).read_bytes()
    assert ref[:8] == b"ANDROID!", "reference is not an Android boot image"
    page = struct.unpack_from("<I", ref, 36)[0]

    kernel = Path(args.kernel).read_bytes()
    if args.ramdisk:
        ramdisk = Path(args.ramdisk).read_bytes()
    else:
        # The reference image's own ramdisk, so nothing else changes.
        ks, rs = struct.unpack_from("<I", ref, 8)[0], struct.unpack_from("<I", ref, 16)[0]
        koff = page + (ks + page - 1) // page * page
        ramdisk = ref[koff:koff + rs]
    dt = Path(args.dt).read_bytes() if args.dt else b""

    hdr = bytearray(ref[:HEADER_SIZE])
    struct.pack_into("<I", hdr, 8, len(kernel))
    struct.pack_into("<I", hdr, 16, len(ramdisk))
    struct.pack_into("<I", hdr, 24, 0)          # second stage
    struct.pack_into("<I", hdr, 40, len(dt))
    if args.cmdline is not None:
        raw = args.cmdline.encode()
        assert len(raw) < 512, "cmdline too long"
        hdr[64:64 + 512] = raw + bytes(512 - len(raw))
    hdr[576:576 + 32] = image_id(kernel, ramdisk, b"", dt)

    out = (pad(bytes(hdr), page) + pad(kernel, page) +
           pad(ramdisk, page) + pad(dt, page))

    # Samsung's sboot refuses an image without this trailer: it resets with
    # INFORM3 = SEC_RESET_REASON_SECURE (0x12345677, "image secure check
    # fail") and comes up in recovery, which looks exactly like a kernel that
    # hangs at the logo. Every image the bootloader accepts carries it --
    # TWRP's included, right after the last padded section.
    out += b"SEANDROIDENFORCE"

    Path(args.output).write_bytes(out)

    print(f"{args.output}: {len(out):,} bytes "
          f"(kernel {len(kernel):,}, ramdisk {len(ramdisk):,}, dt {len(dt):,}, "
          f"page {page}, +SEANDROIDENFORCE)")


if __name__ == "__main__":
    main()
