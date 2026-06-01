#!/usr/bin/env python3
"""
Generates Hooks/assets/dial-face.png — the static background image for the
v1.0 LSO NVG gain dial.

Pure stdlib (zlib + struct + binascii + math). No PIL / Pillow / NumPy.
Anti-aliased half-arc with a rim, major ticks at 0/25/50/75/100% and
minor ticks at every 10%, a center hub, and a dark translucent fill so the
PLAT picture isn't obscured behind it.

Output is 280x160 RGBA PNG. Transparent background.

Run from repo root:
    python Tools/make_dial_face.py
"""
import binascii
import math
import struct
import zlib
from pathlib import Path

# ---- canvas ----------------------------------------------------------------
W, H = 280, 160
CX, CY = 140, 150        # dial center near image bottom (half-arc opens up)

# Radii (px) — outer→inner
R_OUTER     = 138        # rim outside edge
R_RIM_IN    = 130        # rim inside edge (8px ring)
R_MAJ_OUT   = 128        # major tick outer
R_MAJ_IN    =  96        # major tick inner (32px long)
R_MIN_OUT   = 124        # minor tick outer
R_MIN_IN    = 108        # minor tick inner (16px long)
R_FACE      = 124        # face fill stops here (just inside rim)
R_HUB       =   6        # center hub radius

# Angular widths (deg, half-width)
W_MAJ = 1.8
W_MIN = 1.0

# Colors (R, G, B, A 0-255)
COL_RIM   = (210, 215, 220, 235)   # cool silver
COL_MAJ   = (235, 245, 235, 235)   # bright tick
COL_MIN   = (170, 180, 175, 200)   # softer tick
COL_FACE  = ( 10,  22,  14, 170)   # dark glass with green tint
COL_HUB   = (235, 245, 235, 240)

# 11 gain positions, mapped to angles. v0.9 layout: 180° = 0%, 0° = 100%.
TICK_DEGS = [180 - i * 18 for i in range(11)]    # 180, 162, 144, ... 18, 0
MAJ_INDICES = {0, 2, 5, 8, 10}                   # 0, 20-ish, 50, 80-ish, 100
# Use actual 25% / 75% positions for major: index 0 / index ~2.5 / 5 / ~7.5 / 10.
# Since steps are every 10 (index 0-10) we use the closest: 0, 3 (~30%), 5, 7 (~70%), 10.
# Pick the visually-cleanest set:
MAJ_INDICES = {0, 5, 10}                         # only 0 / 50 / 100 are "major"


def smoothstep(a: float, b: float, x: float) -> float:
    """0..1 with a smooth Hermite curve between a and b (or b and a if a > b)."""
    if a == b:
        return 1.0 if x >= a else 0.0
    if a < b:
        if x <= a: return 0.0
        if x >= b: return 1.0
        t = (x - a) / (b - a)
    else:
        if x >= a: return 0.0
        if x <= b: return 1.0
        t = (a - x) / (a - b)
    return t * t * (3.0 - 2.0 * t)


def over(bg, fg):
    """Porter-Duff 'over': fg on top of bg. Both are (R,G,B,A) 0-255 ints."""
    fa = fg[3] / 255.0
    if fa <= 0:
        return bg
    ba = bg[3] / 255.0
    oa = fa + ba * (1.0 - fa)
    if oa <= 0:
        return (0, 0, 0, 0)
    inv = 1.0 / oa
    return (
        int((fg[0] * fa + bg[0] * ba * (1.0 - fa)) * inv + 0.5),
        int((fg[1] * fa + bg[1] * ba * (1.0 - fa)) * inv + 0.5),
        int((fg[2] * fa + bg[2] * ba * (1.0 - fa)) * inv + 0.5),
        int(oa * 255 + 0.5),
    )


def render() -> bytes:
    """Render the dial and return raw RGBA bytes plus filter bytes."""
    rows = []
    for y in range(H):
        row = bytearray()
        row.append(0)  # PNG row-filter byte: 0 = None
        for x in range(W):
            dx = x - CX
            dy = y - CY                     # image y is down
            r  = math.hypot(dx, dy)
            ang = math.degrees(math.atan2(-dy, dx))
            if ang < 0:
                ang += 360

            px = (0, 0, 0, 0)

            # Only render in the upper half-disc (0° to 180°).
            in_half = (0 <= ang <= 180)
            if in_half:
                # face fill: alpha 1 inside R_FACE, fades to 0 by R_FACE+1
                fa = smoothstep(R_FACE + 1.0, R_FACE - 0.5, r)
                if fa > 0:
                    px = over(px, (COL_FACE[0], COL_FACE[1], COL_FACE[2],
                                   int(COL_FACE[3] * fa)))

                # rim ring R_RIM_IN..R_OUTER (anti-aliased on both edges)
                ra = min(smoothstep(R_RIM_IN - 0.5, R_RIM_IN + 0.5, r),
                         smoothstep(R_OUTER + 0.5, R_OUTER - 0.5, r))
                if ra > 0:
                    px = over(px, (COL_RIM[0], COL_RIM[1], COL_RIM[2],
                                   int(COL_RIM[3] * ra)))

                # tick marks
                if R_MIN_IN <= r <= R_MAJ_OUT:
                    for i, td in enumerate(TICK_DEGS):
                        d_ang = abs(ang - td)
                        if d_ang > 3.0:
                            continue
                        is_major = i in MAJ_INDICES
                        # use major params if this position is major
                        if is_major:
                            if not (R_MAJ_IN <= r <= R_MAJ_OUT):
                                continue
                            ta = smoothstep(W_MAJ + 0.4, W_MAJ - 0.4, d_ang)
                            colr = COL_MAJ
                        else:
                            if not (R_MIN_IN <= r <= R_MIN_OUT):
                                continue
                            ta = smoothstep(W_MIN + 0.4, W_MIN - 0.4, d_ang)
                            colr = COL_MIN
                        if ta > 0:
                            px = over(px, (colr[0], colr[1], colr[2],
                                           int(colr[3] * ta)))
                        break

            # center hub (covers full disc near origin, both halves)
            hub_a = smoothstep(R_HUB + 0.5, R_HUB - 0.5, r)
            if hub_a > 0:
                px = over(px, (COL_HUB[0], COL_HUB[1], COL_HUB[2],
                               int(COL_HUB[3] * hub_a)))

            row.extend(px)
        rows.append(bytes(row))
    return b''.join(rows)


def write_png(path: Path, raw: bytes) -> None:
    """Encode raw RGBA scanlines (with filter bytes) to a minimal PNG."""
    def chunk(typ: bytes, data: bytes) -> bytes:
        return (struct.pack('>I', len(data)) + typ + data +
                struct.pack('>I', binascii.crc32(typ + data) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(raw, 9)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', ihdr)
    png += chunk(b'IDAT', idat)
    png += chunk(b'IEND', b'')

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def write_tga(path: Path, raw: bytes) -> None:
    """
    Encode raw RGBA scanlines (with PNG-style filter bytes) to a 32-bit BGRA
    uncompressed TGA, top-down. DCS's dxgui picture loader accepts TGA with
    alpha — Supercarrier's PLATCameraUI uses it (cuePanelAircraft.tga,
    FLOLS.tga, etc). PNG: not accepted. BMP V4 (with alpha bitfields):
    not accepted either (DCS only takes V3 BITMAPINFOHEADER).
    """
    # Strip PNG filter byte per row, swap RGBA -> BGRA.
    row_stride = 1 + W * 4
    pixels = bytearray()
    for y in range(H):
        row_start = y * row_stride + 1   # skip filter byte
        for x in range(W):
            i = row_start + x * 4
            r, g, b, a = raw[i], raw[i+1], raw[i+2], raw[i+3]
            pixels.append(b)
            pixels.append(g)
            pixels.append(r)
            pixels.append(a)

    # 18-byte TGA header
    #   image type = 2 (uncompressed true-color)
    #   pixel depth = 32 (BGRA)
    #   image descriptor = 0x28 = 8 alpha bits + bit5 set (top-down origin)
    header = struct.pack(
        '<BBBHHBHHHHBB',
        0,           # ID length
        0,           # color map type (none)
        2,           # image type (uncompressed RGB / true-color)
        0, 0, 0,     # color map spec (origin, length, depth bits)
        0, 0,        # X-origin, Y-origin
        W, H,        # width, height
        32,          # pixel depth
        0x28,        # image descriptor: 8 alpha bits, top-down
    )

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + bytes(pixels))


def main() -> None:
    out_dir = Path(__file__).resolve().parent.parent / 'Hooks' / 'assets'
    out_png = out_dir / 'dial-face.png'
    out_tga = out_dir / 'dial-face.tga'

    print(f'Rendering {W}x{H} dial face …')
    raw = render()

    write_png(out_png, raw)
    print(f'Wrote {out_png} ({out_png.stat().st_size} bytes)  [preview]')

    write_tga(out_tga, raw)
    print(f'Wrote {out_tga} ({out_tga.stat().st_size} bytes)  [used by DCS]')

    # Tidy up any stale BMP from beta2.
    bmp = out_dir / 'dial-face.bmp'
    if bmp.exists():
        bmp.unlink()
        print(f'Removed stale {bmp}')


if __name__ == '__main__':
    main()
