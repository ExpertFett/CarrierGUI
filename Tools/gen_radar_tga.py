#!/usr/bin/env python3
"""
Generate Hooks/radar_scope.tga — a transparent overlay with smooth, anti-
aliased light-green range rings for the MARSHALL scope.  Pure stdlib (writes
the TGA bytes directly; no PIL).

The hook applies this image to a full-scope overlay widget (above the dot
rings) via setSkin with bkg.file = absolute path.  If DCS loads it, you get
clean solid rings; if not, the dots underneath remain (no regression).

Geometry must match the .dlg scope:
  scope rect x16..524 y54..358 (508 x 304); centre (270,206) -> image (254,152)
  rings at 10/25/50 nm = r 25 / 62 / 123 px (148 px = 60 nm).
"""
import struct
from pathlib import Path

W, H = 508, 304
CXi, CYi = 254, 152
RINGS = [25, 62, 123]
# light green 0x5fe08a -> R,G,B
RGB = (0x5f, 0xe0, 0x8a)

import math
buf = bytearray(W * H * 4)   # BGRA, top-left origin

def put(x, y, a):
    if 0 <= x < W and 0 <= y < H and a > 0:
        i = (y * W + x) * 4
        # keep the strongest alpha if rings overlap a pixel
        if a >= buf[i + 3]:
            buf[i + 0] = RGB[2]   # B
            buf[i + 1] = RGB[1]   # G
            buf[i + 2] = RGB[0]   # R
            buf[i + 3] = a

# Draw each ring 2 px thick with ~1 px anti-aliased edges.
HALF = 1.4   # ring half-thickness (px)
for y in range(H):
    dy = y - CYi
    for x in range(W):
        dx = x - CXi
        d = math.sqrt(dx * dx + dy * dy)
        for r in RINGS:
            e = abs(d - r)
            if e <= HALF:
                a = 255
            elif e <= HALF + 1.0:
                a = int(255 * (1.0 - (e - HALF)))   # AA feather
            else:
                a = 0
            if a > 0:
                put(x, y, a)

hdr = struct.pack(
    '<BBBHHBHHHHBB',
    0,      # id length
    0,      # color map type
    2,      # image type: uncompressed true-color
    0, 0, 0,   # color map spec (origin, length, depth)
    0, 0,      # x/y origin
    W, H,      # width, height
    32,        # pixel depth
    0x28,      # descriptor: 8 alpha bits (0x08) + top-left origin (0x20)
)

out = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\Hooks\radar_scope.tga")
out.write_bytes(hdr + bytes(buf))
print(f"wrote {out}  ({out.stat().st_size} bytes, {W}x{H}, rings {RINGS})")
