#!/usr/bin/env python3
"""
Apply the MARSHALL scope learnings to the TOWER overhead stack scope:
  - replace the old seg() sunburst rings with solid DOT rings (2/4/6 nm),
  - add a contact BLIP-dot pool (tOhDot) to pair with the datablock labels,
  - brighten the ship/centre marker.
Splices into carrier-gui.dlg, replacing the tRing* seg block.
"""
import math, re
from pathlib import Path

CX, CY = 130, 103
R2, R4, R6 = 18, 36, 54   # 2 / 4 / 6 nm

dot_lines = []
def ring(prefix, r, gap=4, d=4):
    n = max(8, int(round(2 * math.pi * r / gap)))
    for i in range(n):
        th = 2 * math.pi * i / n
        px = CX + r * math.cos(th)
        py = CY + r * math.sin(th)
        dot_lines.append(
            f'c.{prefix}{i+1} = solidW({round(px-d/2)}, {round(py-d/2)}, {d}, {d}, SCOPE_RING_SKIN, 3)')
    return n

counts = {}
dot_lines.append('-- stack-scope range rings 2/4/6 nm (solid dots; replaces seg sunburst)')
counts['tDotA'] = ring('tDotA', R2)
dot_lines.append('')
counts['tDotB'] = ring('tDotB', R4)
dot_lines.append('')
counts['tDotC'] = ring('tDotC', R6)

dlg = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\Hooks\carrier-gui.dlg")
src = dlg.read_text(encoding='utf-8')

# 1) replace the seg ring block (from the first c.tRingA1 line through the
#    last c.tRingC.. line) with the dot rings.
pat = re.compile(r"(?:c\.tRing[ABC]\d+\s*=\s*seg\([^\n]*\n)+")
new = '\n'.join(dot_lines) + '\n'
src, n = pat.subn(new, src, count=1)
assert n == 1, f"tower ring block: {n}"

# 2) brighter centre marker + add a blip-dot pool alongside the twrOh datablocks
src = src.replace(
    'c.tShip    = solidW(127, 100,   6,   6, SHIP_MARK_SKIN, 3)',
    'c.tShip    = solidW(126, 100,   8,   8, SHIP_MARK_SKIN, 4)')
src = src.replace(
    '''for i = 1, 10 do
    c["twrOh" .. i] = lbl("", -200, -200, 40, SpotSkin, 14)
end''',
    '''for i = 1, 10 do
    c["tOhDot" .. i] = solidW(-300, -300, 5, 5, CONTACT_SKIN, 4)
    c["twrOh"  .. i] = lbl("", -300, -300, 60, SpotSkin, 13)
end''')

dlg.write_text(src, encoding='utf-8')
print(f"TOWER scope: dot ring counts {counts}")
