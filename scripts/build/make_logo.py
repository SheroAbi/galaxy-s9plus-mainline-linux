#!/usr/bin/env python3
"""Render the boot logo the kernel shows when fbcon takes over the panel.

Output is a plain PPM the kernel's own pnmtologo turns into
logo_linux_clut224. Four colours, so it converts cleanly. The canvas is
deliberately wider than half the 1440-pixel panel: fbcon draws one logo per
online CPU side by side, and at this width only one fits.

    make_logo.py <out.ppm>
"""
import sys

W, H = 1180, 270
BG = (0, 0, 0)
FG = (255, 255, 255)
DIM = (128, 132, 140)
ACCENT = (0, 160, 255)

# 5x7 block font, one string per row, '#' set
F = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "9": ["01110", "10001", "10001", "01111", "00001", "10001", "01110"],
    "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    " ": ["00000"] * 7,
}

px = [[BG] * W for _ in range(H)]


def text(s, x, y, scale, colour, spacing=1):
    for ch in s.upper():
        g = F[ch]
        for r, row in enumerate(g):
            for c, bit in enumerate(row):
                if bit == "1":
                    for dy in range(scale):
                        for dx in range(scale):
                            yy, xx = y + r * scale + dy, x + c * scale + dx
                            if 0 <= yy < H and 0 <= xx < W:
                                px[yy][xx] = colour
        x += (len(g[0]) + spacing) * scale
    return x


def width(s, scale, spacing=1):
    return sum((len(F[c.upper()][0]) + spacing) * scale for c in s) - spacing * scale


def centred(s, y, scale, colour, spacing=1):
    return text(s, (W - width(s, scale, spacing)) // 2, y, scale, colour, spacing)


centred("SHERO OS", 40, 16, FG, 1)                  # 5x7 -> 80x112 per glyph
centred("LINUX KERNEL MADE BY SHERO", 196, 6, DIM)  # 30x42 per glyph
# a thin accent rule under the title
for x in range((W - 700) // 2, (W + 700) // 2):
    for y in range(168, 172):
        px[y][x] = ACCENT

out = [f"P3\n{W} {H}\n255\n"]
for row in px:
    out.append(" ".join(f"{r} {g} {b}" for r, g, b in row) + "\n")
open(sys.argv[1], "w").write("".join(out))
cols = {c for row in px for c in row}
print(f"{sys.argv[1]}: {W}x{H}, {len(cols)} colours")
