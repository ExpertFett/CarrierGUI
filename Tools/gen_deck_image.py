#!/usr/bin/env python3
r"""
Convert a top-down deck reference image (deck_source.png) into the panel deck
background:
  - Hooks/deck_overhead.tga   — 32-bit, BOTTOM-UP (descriptor 0x08, the only
                                orientation DCS bkg.file loads; matches FLOLS).
  - deck_overhead_preview.png — same pixels as RGB, for eyeballing at scale.

Target width is the panel deck area; height follows the source aspect so the
deck isn't distorted.  Prints the final WxH so the .dlg overlay rect + the hook
overlay mapping can match it exactly.
"""
import struct
from pathlib import Path
from PIL import Image
import numpy as np

ROOT = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI")
SRC  = ROOT / "deck_source.png"
TGA  = ROOT / "Hooks" / "deck_overhead.tga"
PREV = ROOT / "deck_overhead_preview.png"

TARGET_W = 520   # panel deck-area width

im = Image.open(SRC).convert("RGBA")
w, h = im.size
target_h = round(TARGET_W * h / w)
im = im.resize((TARGET_W, target_h), Image.LANCZOS)

im.convert("RGB").save(PREV)

arr  = np.array(im)                 # H x W x 4, RGBA, top-down
bgra = arr[:, :, [2, 1, 0, 3]]      # -> BGRA
bgra = bgra[::-1, :, :]             # -> bottom-up rows
hdr = struct.pack('<BBBHHBHHHHBB',
                  0, 0, 2, 0, 0, 0, 0, 0,
                  TARGET_W, target_h, 32, 0x08)
TGA.write_bytes(hdr + bgra.tobytes())

print(f"deck image: {TARGET_W}x{target_h}")
print(f"  tga:     {TGA}  ({TGA.stat().st_size} bytes)")
print(f"  preview: {PREV}")
