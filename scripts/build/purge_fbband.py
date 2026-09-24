#!/usr/bin/env python3
"""Remove the early colour bands from arch/arm64/kernel/head.S.

Five `fbband` calls paint stripes into the bootloader framebuffer while the
MMU is still off, so an early death could be located by which colours showed
up (scripts/patch_fbband.py, scripts/apply_early_trace.py). They served their
purpose; what is left of them on a working device is coloured stripes across
the bottom of the boot logo. The `s9p_stage` marks stay -- those write PMU
registers and cost nothing on screen.

    purge_fbband.py <kernel tree>
"""
import re
import sys
from pathlib import Path

p = Path(sys.argv[1]) / "arch/arm64/kernel/head.S"
s = p.read_text()
before = len(re.findall(r"^\s*fbband\b", s, re.M))
s = re.sub(r"^[ \t]*fbband[ \t].*\n", "", s, flags=re.M)
# the macro itself and its helper defines become dead weight
s = re.sub(r"/\* S9P-FBBAND \*/\n(?:.*\n)*?\t\.endm\n", "", s, count=1)
after = len(re.findall(r"^\s*fbband\b", s, re.M))
p.write_text(s)
print(f"head.S: removed {before - after} fbband call(s), {after} left; "
      f"macro present: {'fbband,' in s}")
