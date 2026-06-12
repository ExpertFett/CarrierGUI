#!/usr/bin/env python3
"""
Emit literal Lua lines for the radar scope geometry in carrier-gui.dlg.

DialogLoader's sandbox has no math.* so every coordinate must be a literal.
This script does the trig offline and prints ready-to-paste `seg(...)` calls.

Ring segments: 16-gon approximation.  Each segment is a thin Static placed
with its CENTER on the circle, rotated to the local tangent.  If DCS ignores
the angle param the segments render unrotated — which still reads as a
dashed circle, so the failure mode is acceptable.

Output convention (matches the dlg helper):
    seg(name, cx-w/2, cy-h/2, w, h, angle)
where (cx, cy) is the segment centre.
"""
import math

def ring(prefix, cx, cy, r, n=16, thick=2):
    chord = 2 * r * math.sin(math.pi / n)
    w = chord + 2
    out = []
    for i in range(n):
        theta = 2 * math.pi * i / n
        px = cx + r * math.cos(theta)
        py = cy + r * math.sin(theta)
        ang = round(math.degrees(theta) + 90, 1)
        x = round(px - w / 2)
        y = round(py - thick / 2)
        out.append(f'c.{prefix}{i+1:<2} = seg({x}, {y}, {round(w)}, {thick}, {ang})')
    return out

def arc(prefix, cx, cy, r, deg_from, deg_to, n, thick=2):
    """Partial arc, n segments. Angles in screen-space degrees (0=E, 90=S)."""
    out = []
    step = (deg_to - deg_from) / n
    chord = 2 * r * math.sin(math.radians(abs(step)) / 2)
    w = chord + 2
    for i in range(n):
        mid = math.radians(deg_from + step * (i + 0.5))
        px = cx + r * math.cos(mid)
        py = cy + r * math.sin(mid)
        ang = round(math.degrees(mid) + 90, 1)
        x = round(px - w / 2)
        y = round(py - thick / 2)
        out.append(f'c.{prefix}{i+1:<2} = seg({x}, {y}, {round(w)}, {thick}, {ang})')
    return out

print('-- ===== MARSHALL CCZ rings: centre (270,190), 20/40/60nm = r 37/73/110')
for line in ring('mRingA', 270, 190, 37, 12):  print(line)
print()
for line in ring('mRingB', 270, 190, 73, 16):  print(line)
print()
for line in ring('mRingC', 270, 190, 110, 20): print(line)

print()
print('-- ===== TOWER overhead mini-scope rings: centre (130,103), r 26/52')
for line in ring('tRingA', 130, 103, 26, 10): print(line)
print()
for line in ring('tRingB', 130, 103, 52, 14): print(line)

print()
print('-- ===== LSO racetrack 180-turn arcs (left side, between DOWNWIND-leg')
print('-- x=140 and the bottom leg y=260; turn centre (270,260)? no — port turn')
print('-- arc joins x=140 vertical bottom to y=260 horizontal left end.')
print('-- Turn centre (270, 158)?? -> use simple quarter arcs at the two left')
print('-- corners: top-left corner (BREAK->DOWNWIND) centre (170,85) r=30,')
print('-- bottom-left corner (180->90) centre (170,230) r=30.')
for line in arc('pArcTL', 170, 85, 30, 180, 270, 4):  print(line)
print()
for line in arc('pArcBL', 170, 230, 30, 90, 180, 4):  print(line)
