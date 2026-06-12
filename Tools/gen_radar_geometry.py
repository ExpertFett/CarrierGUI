#!/usr/bin/env python3
"""
Emit literal Lua lines for the radar scope geometry in carrier-gui.dlg.

DialogLoader's sandbox has no math.* so every coordinate must be a literal.
v1.3-beta10: finer segmentation so rings read as smooth circles, bearing
tick marks, the LSO 180-turn semicircle, and a 6 nm stack scope.

Output convention (matches the dlg helpers):
    seg(x, y, w, h, angle)        -- ring/arc segment, pivot at centre
"""
import math

def ring(prefix, cx, cy, r, n, thick=2):
    chord = 2 * r * math.sin(math.pi / n)
    w = max(3, round(chord + 1))
    out = []
    for i in range(n):
        theta = 2 * math.pi * i / n
        px = cx + r * math.cos(theta)
        py = cy + r * math.sin(theta)
        ang = round(math.degrees(theta) + 90, 1)
        x = round(px - w / 2)
        y = round(py - thick / 2)
        out.append(f'c.{prefix}{i+1} = seg({x}, {y}, {w}, {thick}, {ang})')
    return out

def ticks(prefix, cx, cy, r_in, r_out, every_deg=30, thick=2):
    """Radial tick marks around the rim (pointing at the centre)."""
    out = []
    n = 360 // every_deg
    length = round(r_out - r_in)
    rmid = (r_in + r_out) / 2
    for i in range(n):
        theta = math.radians(i * every_deg - 90)   # start at N (up)
        px = cx + rmid * math.cos(theta)
        py = cy + rmid * math.sin(theta)
        ang = round(math.degrees(theta), 1)
        x = round(px - length / 2)
        y = round(py - thick / 2)
        out.append(f'c.{prefix}{i+1} = seg({x}, {y}, {length}, {thick}, {ang})')
    return out

def arc(prefix, cx, cy, r, deg_from, deg_to, n, thick=2):
    """Partial arc. Screen-space degrees: 0 = +x (right), 90 = +y (down)."""
    out = []
    step = (deg_to - deg_from) / n
    chord = 2 * r * math.sin(math.radians(abs(step)) / 2)
    w = max(3, round(chord + 1))
    for i in range(n):
        mid = math.radians(deg_from + step * (i + 0.5))
        px = cx + r * math.cos(mid)
        py = cy + r * math.sin(mid)
        ang = round(math.degrees(mid) + 90, 1)
        x = round(px - w / 2)
        y = round(py - thick / 2)
        out.append(f'c.{prefix}{i+1} = seg({x}, {y}, {w}, {thick}, {ang})')
    return out

blocks = []

blocks.append('-- MARSHALL CCZ rings: centre (270,190), 20/40/60 nm = r 37/73/110')
blocks += ring('mRingA', 270, 190, 37, 20)
blocks.append('')
blocks += ring('mRingB', 270, 190, 73, 32)
blocks.append('')
blocks += ring('mRingC', 270, 190, 110, 44)
blocks.append('')
blocks.append('-- bearing ticks every 30 deg just outside the 60 nm ring')
blocks += ticks('mTick', 270, 190, 112, 122, 30)

blocks.append('')
blocks.append('-- TOWER stack scope: centre (130,103), 2/4/6 nm = r 18/36/54')
blocks += ring('tRingA', 130, 103, 18, 12)
blocks.append('')
blocks += ring('tRingB', 130, 103, 36, 20)
blocks.append('')
blocks += ring('tRingC', 130, 103, 54, 28)

blocks.append('')
blocks.append('-- LSO horizontal racetrack: left 180-turn semicircle,')
blocks.append('-- centre (120,155) r=65, from 90deg (bottom) to 270deg (top)')
blocks += arc('pArcL', 120, 155, 65, 90, 270, 10)

print('\n'.join(blocks))
