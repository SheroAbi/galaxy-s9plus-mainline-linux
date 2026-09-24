#!/bin/bash
# Check what mk_images.sh produced in $BUILD/dist.
. "$(dirname "${BASH_SOURCE[0]}")/../build/env.sh"
mount_build
D=$BUILD/dist
echo "=== sparse header (userdata.img) ==="
xxd -l 28 "$D/userdata.img"
python3 - "$D/userdata.img" <<'PY'
import struct, sys
h=open(sys.argv[1],'rb').read(28)
magic,major,minor,fhdr,chdr,blk,total_blk,total_chunks=struct.unpack('<IHHHHIII',h)
print(f"magic=0x{magic:08x} ({'OK sparse' if magic==0xed26ff3a else 'NOT SPARSE'}) "
      f"v{major}.{minor} block={blk} blocks={total_blk} chunks={total_chunks} "
      f"raw_size={total_blk*blk/2**30:.2f} GiB")
PY
echo
echo "=== boot.img header ==="
rm -rf /tmp/vb && mkdir -p /tmp/vb
"$BUILD/tools/bin/unpackbootimg" -i "$D/boot.img" -o /tmp/vb | head -12
echo
echo "=== flash tars ==="
for t in "$D"/flash-boot/*.md5 "$D"/flash-full/*.md5; do
  echo "--- $(basename $t) ($(du -h "$t" | cut -f1))"
  tar tvf "$t" 2>/dev/null
  echo "    md5 trailer: $(tail -c 60 "$t" | tr -d '\0' | tr -s ' ')"
done
echo
echo "=== rootfs image sanity ==="
e2fsck -fn "$(dirname $D)/out/rootfs.img" 2>&1 | tail -5
rm -rf /tmp/vb
echo VERIFY_OK
