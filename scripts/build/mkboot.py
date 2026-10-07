"""Build a Samsung Android boot image (header v0 with a dt.img section).

Two ways to fill the header:

  * from a reference image (--ref): every header field is copied from an
    image the phone has already accepted, so the only thing that differs is
    the payload under test. pack_uniloader.sh uses this with TWRP.
  * from scratch: the load addresses come from --base and the offsets, like
    the mkbootimg of Samsung's kernel trees (which knows --dt). build71.sh
    uses this, so the build needs no prebuilt mkbootimg; the result is
    byte-identical to what that mkbootimg wrote for the same inputs.

  mkboot.py --ref <boot.img> --kernel <Image> [--dt <dt.img>]
            [--ramdisk <f>] [--cmdline "..."] -o <out.img>
  mkboot.py --kernel <Image> --ramdisk <f> [--dt <dt.img>] [--cmdline "..."]
            [--base 0x10000000] [--kernel_offset 0x8000] [--pagesize 2048] ... -o <out.img>
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
    num = lambda v: int(v, 0)  # noqa: E731
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", help="image to copy header fields from")
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--dt")
    ap.add_argument("--ramdisk")
    ap.add_argument("--cmdline")
    ap.add_argument("-o", "--output", required=True)
    # only without --ref; the defaults are the ones build71.sh has always used
    ap.add_argument("--base", type=num, default=0x10000000)
    ap.add_argument("--kernel_offset", type=num, default=0x00008000)
    ap.add_argument("--ramdisk_offset", type=num, default=0x01000000)
    ap.add_argument("--second_offset", type=num, default=0x00F00000)
    ap.add_argument("--tags_offset", type=num, default=0x00000100)
    ap.add_argument("--pagesize", type=num, default=2048)
    ap.add_argument("--board", default="")
    args = ap.parse_args()

    kernel = Path(args.kernel).read_bytes()
    dt = Path(args.dt).read_bytes() if args.dt else b""

    if args.ref:
        ref = Path(args.ref).read_bytes()
        assert ref[:8] == b"ANDROID!", "reference is not an Android boot image"
        page = struct.unpack_from("<I", ref, 36)[0]
        if args.ramdisk:
            ramdisk = Path(args.ramdisk).read_bytes()
        else:
            # The reference image's own ramdisk, so nothing else changes.
            ks, rs = struct.unpack_from("<I", ref, 8)[0], struct.unpack_from("<I", ref, 16)[0]
            koff = page + (ks + page - 1) // page * page
            ramdisk = ref[koff:koff + rs]
        hdr = bytearray(ref[:HEADER_SIZE])
    else:
        if not args.ramdisk:
            ap.error("--ramdisk is required without --ref")
        ramdisk = Path(args.ramdisk).read_bytes()
        page = args.pagesize
        board = args.board.encode()
        assert len(board) < 16, "board name too long"
        hdr = bytearray(HEADER_SIZE)
        # magic, kernel size/addr, ramdisk size/addr, second size/addr, tags
        # addr, page size, dt size (Samsung's slot), unused, board name
        struct.pack_into("<8s10I16s", hdr, 0, b"ANDROID!",
                         0, args.base + args.kernel_offset,
                         0, args.base + args.ramdisk_offset,
                         0, args.base + args.second_offset,
                         args.base + args.tags_offset, page, 0, 0, board)
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
