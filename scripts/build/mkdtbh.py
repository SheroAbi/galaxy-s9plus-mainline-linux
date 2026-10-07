"""Pack device trees into the Samsung DTBH table S-Boot reads (dt.img).

A Python port of dtbTool-exynos (github.com/dsankouski/dtbtool-exynos), so the
build needs no prebuilt binary. For this board its output is byte-identical
to the tool's: one 32-byte entry per DTB, the blobs page-aligned after a
one-page header.

  mkdtbh.py -o dt.img [-s 2048] [--platform 0x50a6] [--subtype 0x217584da] board.dtb...

Each DTB's root node must carry model_info-chip, model_info-hw_rev and
model_info-hw_rev_end. platform and subtype are not read from the tree: like
dtbTool-exynos, every entry gets the codes Samsung's tool writes by default.
"""
import argparse
import struct
import sys
from pathlib import Path

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
PAGE_SIZES = (2048, 4096, 8192, 16384, 32768, 65536, 131072)


def root_props(dtb):
    """The properties of the root node, as {name: raw bytes}."""
    if len(dtb) < 40 or struct.unpack_from(">I", dtb, 0)[0] != FDT_MAGIC:
        raise ValueError("not a flattened device tree")
    off_struct, off_strings = struct.unpack_from(">II", dtb, 8)
    pos, depth, props = off_struct, 0, {}
    while True:
        token = struct.unpack_from(">I", dtb, pos)[0]
        pos += 4
        if token == FDT_BEGIN_NODE:
            depth += 1
            if depth > 1:
                return props  # the root's properties all come before its first child
            end = dtb.index(b"\0", pos)
            pos = (end + 4) & ~3
        elif token == FDT_PROP:
            length, name_off = struct.unpack_from(">II", dtb, pos)
            pos += 8
            name = dtb[off_strings + name_off:dtb.index(b"\0", off_strings + name_off)]
            props[name.decode()] = dtb[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif token == FDT_NOP:
            continue
        elif token in (FDT_END_NODE, FDT_END):
            return props
        else:
            raise ValueError(f"bad FDT token {token:#x} at {pos - 4:#x}")


def cell(props, name, path):
    raw = props.get(name)
    if raw is None or len(raw) < 4 or len(raw) % 4:
        raise ValueError(f"{path}: root node has no usable {name}")
    return struct.unpack_from(">I", raw)[0]


def dtbh(dtbs, page, platform, subtype):
    """dtbs: [(path, bytes)]. Returns the complete dt.img."""
    def align(n):
        return (n + page - 1) // page * page

    entries = []
    for path, blob in dtbs:
        props = root_props(blob)
        entries.append((cell(props, "model_info-chip", path),
                        cell(props, "model_info-hw_rev", path),
                        cell(props, "model_info-hw_rev_end", path), blob))
    # magic, version, count, the entries, an end-of-table word
    header = align(12 + 32 * len(entries) + 4)
    out = bytearray(b"DTBH" + struct.pack("<II", 2, len(entries)))
    offset = header
    for chip, rev, rev_end, blob in entries:
        out += struct.pack("<8I", chip, platform, subtype, rev, rev_end,
                           offset, align(len(blob)), 0x20)
        offset += align(len(blob))
    out += bytes(header - len(out))
    for *_, blob in entries:
        out += blob + bytes(align(len(blob)) - len(blob))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dtbs", nargs="+", type=Path)
    ap.add_argument("-o", "--output", required=True, type=Path)
    ap.add_argument("-s", "--pagesize", type=int, default=2048, choices=PAGE_SIZES)
    ap.add_argument("--platform", type=lambda v: int(v, 0), default=0x50A6)
    ap.add_argument("--subtype", type=lambda v: int(v, 0), default=0x217584DA)
    args = ap.parse_args()
    try:
        table = dtbh([(p, p.read_bytes()) for p in args.dtbs],
                     args.pagesize, args.platform, args.subtype)
    except (OSError, ValueError) as e:
        sys.exit(f"mkdtbh: {e}")
    args.output.write_bytes(table)
    print(f"{args.output}: DTBH v2, {len(args.dtbs)} DTB, {len(table):,} bytes")


if __name__ == "__main__":
    main()
