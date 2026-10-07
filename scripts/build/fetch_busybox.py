"""Fetch the static arm64 busybox the initramfs is built from.

  fetch_busybox.py <destination file>

It comes from Ubuntu's busybox-static package (noble-updates, else noble),
checked against the SHA-256 in the signed archive index, so no prebuilt
binary has to come from this repository. The busybox must be statically
linked: the initramfs has no C library, and a dynamic one also breaks the
build itself, where qemu-aarch64-static lists its applets and stops with
"Could not open '/lib/ld-linux-aarch64.so.1'".

UBUNTU_MIRROR overrides the mirror (default http://ports.ubuntu.com/ubuntu-ports).
"""
import gzip
import hashlib
import io
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

MIRROR = os.environ.get("UBUNTU_MIRROR", "http://ports.ubuntu.com/ubuntu-ports").rstrip("/")
SUITES = ("noble-updates", "noble")
PACKAGE = "busybox-static"


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def find_package():
    for suite in SUITES:
        index = gzip.decompress(fetch(f"{MIRROR}/dists/{suite}/main/binary-arm64/Packages.gz"))
        for stanza in index.decode("utf-8", "replace").split("\n\n"):
            fields = dict(line.split(": ", 1) for line in stanza.splitlines()
                          if ": " in line and not line.startswith(" "))
            if fields.get("Package") == PACKAGE:
                return suite, fields
    sys.exit(f"{PACKAGE} not found in {MIRROR}")


def ar_members(deb):
    if deb[:8] != b"!<arch>\n":
        raise ValueError("not a .deb (ar) archive")
    pos = 8
    while pos + 60 <= len(deb):
        name = deb[pos:pos + 16].decode().strip().rstrip("/")
        size = int(deb[pos + 48:pos + 58].decode().strip())
        yield name, deb[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)


def data_tar(deb_path, deb):
    """The package's file tree as an uncompressed tar."""
    if shutil.which("dpkg-deb"):
        return subprocess.run(["dpkg-deb", "--fsys-tarfile", deb_path],
                              check=True, capture_output=True).stdout
    for name, body in ar_members(deb):
        if name == "data.tar.zst":
            try:
                from compression import zstd  # Python 3.14+
                return zstd.decompress(body)
            except ImportError:
                if not shutil.which("zstd"):
                    sys.exit("need dpkg-deb or zstd to unpack the package")
                return subprocess.run(["zstd", "-dc"], input=body, check=True,
                                      capture_output=True).stdout
        if name == "data.tar.xz":
            import lzma
            return lzma.decompress(body)
        if name == "data.tar.gz":
            return gzip.decompress(body)
    raise ValueError("no data.tar.* in the package")


def check_static_arm64(elf):
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:
        raise ValueError("not a 64-bit little-endian ELF file")
    if struct.unpack_from("<H", elf, 18)[0] != 183:
        raise ValueError("not an AArch64 binary")
    phoff = struct.unpack_from("<Q", elf, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", elf, 54)
    for i in range(phnum):
        if struct.unpack_from("<I", elf, phoff + i * phentsize)[0] == 3:  # PT_INTERP
            raise ValueError("dynamically linked (has an ELF interpreter)")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().split("\n\n")[1])
    dest = Path(sys.argv[1])
    suite, fields = find_package()
    url = f"{MIRROR}/{fields['Filename']}"
    print(f"{PACKAGE} {fields['Version']} ({suite}): {url}")
    deb = fetch(url)
    if hashlib.sha256(deb).hexdigest() != fields["SHA256"]:
        sys.exit("SHA-256 mismatch against the archive index")
    deb_path = dest.with_name(dest.name + ".deb")
    deb_path.parent.mkdir(parents=True, exist_ok=True)
    deb_path.write_bytes(deb)
    try:
        with tarfile.open(fileobj=io.BytesIO(data_tar(str(deb_path), deb))) as tar:
            member = next((m for m in tar.getmembers()
                           if m.isfile() and m.name.rstrip("/").endswith("bin/busybox")), None)
            if member is None:
                sys.exit("no bin/busybox in the package")
            elf = tar.extractfile(member).read()
    finally:
        deb_path.unlink(missing_ok=True)
    try:
        check_static_arm64(elf)
    except ValueError as e:
        sys.exit(f"unusable busybox: {e}")
    tmp = dest.with_name(dest.name + ".part")
    tmp.write_bytes(elf)
    tmp.chmod(0o755)
    tmp.replace(dest)
    print(f"{dest}: {len(elf):,} bytes, static arm64, sha256 {hashlib.sha256(elf).hexdigest()}")


if __name__ == "__main__":
    main()
