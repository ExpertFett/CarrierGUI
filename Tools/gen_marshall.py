#!/usr/bin/env python3
"""
Regenerate the whole MARSHALL tab section of carrier-gui.dlg.

Layout (panel W=540):
  - Big radar scope: centre (270,212), 60 nm = r150 (2.5 px/nm).  Smooth
    overlapping ring segments, 8 radial spokes, range + cardinal labels.
  - Radio readout: header + a pool of prose lines (the scripted marshal call).
  - Marshal stack diagram: a vertical holding racetrack (no boat) + angels
    altitude ladder; aircraft plotted by assigned angels.

Writes the new section back into the .dlg between the MARSHALL and DECKBOSS
section header comments.
"""
import math
from pathlib import Path

CX, CY = 270, 212
R20, R40, R60 = 50, 100, 150
SCOPE_X, SCOPE_Y, SCOPE_W, SCOPE_H = 16, 58, 508, 308

L = []
def emit(s=''): L.append(s)

emit('-- ============================================================== MARSHALL TAB ==')
emit('-- v1.3-beta11: full-size radar scope + scripted radio readout + marshal')
emit('-- stack racetrack.  Rings are smooth (overlapping rotated segments).')
emit('c.lblMarshallHdr = lbl("CCZ TRACKER  ·  60 nm  ·  N up", PAD, 30, W - PAD*2, LabelSkin, 20)')
emit('')
emit('-- scope face + border')
emit(f'c.mScope = solidW({SCOPE_X}, {SCOPE_Y}, {SCOPE_W}, {SCOPE_H}, SCOPE_BG_SKIN, 1)')
emit(f'c.mBordT = solidW({SCOPE_X}, {SCOPE_Y}, {SCOPE_W}, 1, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordB = solidW({SCOPE_X}, {SCOPE_Y+SCOPE_H}, {SCOPE_W}, 1, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordL = solidW({SCOPE_X}, {SCOPE_Y}, 1, {SCOPE_H}, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordR = solidW({SCOPE_X+SCOPE_W}, {SCOPE_Y}, 1, {SCOPE_H}, SCOPE_RG_SKIN, 3)')
emit('')

# clean crosshair (non-rotated solid rects — always render reliably)
emit('-- crosshair (plain rects, no rotation)')
emit(f'c.mCrossV = solidW({CX}, {CY-R60}, 1, {2*R60}, SCOPE_LN_SKIN, 2)')
emit(f'c.mCrossH = solidW({CX-R60}, {CY}, {2*R60}, 1, SCOPE_LN_SKIN, 2)')
emit('')

def ring(prefix, r, n):
    # LONG, heavily-overlapping segments.  Short bars (beta11) rendered as
    # separated tilted dashes; long bars (like the spokes/LSO arc) render as
    # solid lines.  width = 2.3x chord => ~130% overlap.
    chord = 2*r*math.sin(math.pi/n)
    w = max(8, round(chord*2.3))
    for i in range(n):
        th = 2*math.pi*i/n
        px, py = CX + r*math.cos(th), CY + r*math.sin(th)
        ang = round(math.degrees(th) + 90, 1)
        emit(f'c.{prefix}{i+1} = seg({round(px-w/2)}, {round(py-1)}, {w}, 3, {ang})')

emit('-- smooth range rings (long overlapping segments, 3 px thick)')
ring('mRingA', R20, 24)
emit('')
ring('mRingB', R40, 32)
emit('')
ring('mRingC', R60, 40)
emit('')

# centre + range + cardinal labels
emit(f'c.mDot   = solidW({CX-3}, {CY-3}, 6, 6, SHIP_MARK_SKIN, 3)')
emit(f'c.lblMRcv = lbl("CV", {CX+6}, {CY-2}, 30, CarrierMark, 14)')
emit(f'c.lblMR20 = lbl("20", {CX+4}, {CY-R20-2}, 20, RadarLbl, 12)')
emit(f'c.lblMR40 = lbl("40", {CX+4}, {CY-R40-2}, 20, RadarLbl, 12)')
emit(f'c.lblMR60 = lbl("60", {CX+4}, {CY-R60+2}, 20, RadarLbl, 12)')
emit(f'c.lblMRN  = lbl("N", {CX-4}, {CY-R60-16}, 14, RadarLbl, 12)')
emit(f'c.lblMRS  = lbl("S", {CX-4}, {CY+R60+4}, 14, RadarLbl, 12)')
emit(f'c.lblMRE  = lbl("E", {CX+R60+6}, {CY-8}, 14, RadarLbl, 12)')
emit(f'c.lblMRW  = lbl("W", {CX-R60-16}, {CY-8}, 14, RadarLbl, 12)')
emit('')

# aircraft scatter slots on the scope (hook repositions by brg/nm)
emit('-- aircraft scatter slots (hook positions each by brg/nm; N up)')
emit('for i = 1, 12 do')
emit('    c["rowCcz" .. i] = lbl("", -300, -300, 60, SpotSkin, 14)')
emit('end')
emit('')

# Radio readout
emit('-- ── radio readout (scripted marshal call) ──────────────────────────')
emit('c.lblMarRadioHdr = lbl("RADIO READOUT", PAD, 378, W - PAD*2, LabelSkin, 18)')
emit('local CallSkin = mkLabelSkin("0xd8e0c8ff", 13)')
emit('for i = 1, 16 do')
emit('    c["rowMarCall" .. i] = lbl("", PAD, 400 + (i-1)*15, W - PAD*2, CallSkin, 15)')
emit('end')
emit('')

# Marshal stack racetrack (vertical hold, no boat) + angels ladder
STK_TOP, STK_BOT = 690, 800
PILL_L, PILL_R = 250, 330
emit('-- ── marshal stack (vertical holding racetrack, no boat) ─────────────')
emit('c.lblMarStackHdr = lbl("MARSHAL STACK  ·  angels", PAD, 648, W - PAD*2, LabelSkin, 18)')
# pill legs
emit(f'c.sPillL = solidW({PILL_L}, {STK_TOP}, 2, {STK_BOT-STK_TOP}, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillR = solidW({PILL_R}, {STK_TOP}, 2, {STK_BOT-STK_TOP}, SCOPE_RG_SKIN, 3)')
# caps: top semicircle (bulge up), bottom semicircle (bulge down)
pcx = (PILL_L + PILL_R)//2 + 1
pr = (PILL_R - PILL_L)//2
def cap(prefix, ccy, lo, hi, n):
    step = (hi-lo)/n
    chord = 2*pr*math.sin(math.radians(abs(step))/2)
    w = max(8, round(chord*2.3))
    for i in range(n):
        mid = math.radians(lo + step*(i+0.5))
        px, py = pcx + pr*math.cos(mid), ccy + pr*math.sin(mid)
        ang = round(math.degrees(mid)+90, 1)
        emit(f'c.{prefix}{i+1} = seg({round(px-w/2)}, {round(py-1)}, {w}, 3, {ang})')
emit('-- top cap (semicircle bulging up)')
cap('sCapT', STK_TOP, 180, 360, 7)
emit('-- bottom cap (semicircle bulging down)')
cap('sCapB', STK_BOT, 0, 180, 7)
emit('')
# angels ladder labels on the left, rungs (angels 2..7), aircraft slots
emit('-- angels ladder (2..7) + aircraft slots (hook places modex by angels)')
for a in range(2, 8):
    y = STK_BOT - (a-2)*22
    emit(f'c.lblStkA{a} = lbl("{a}", {PILL_L-30}, {y-7}, 24, RadarLbl, 13)')
emit('for i = 1, 12 do')
emit('    c["stkSlot" .. i] = lbl("", -300, -300, 50, SpotSkin, 14)')
emit('end')
emit('')
emit('c.lblMarStatus = lbl("(waiting for inbound traffic...)", PAD, 832, W - PAD*2, CapSkin, 16)')
emit('')

section = '\n'.join(L) + '\n'

dlg = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\Hooks\carrier-gui.dlg")
text = dlg.read_text(encoding='utf-8')
lines = text.split('\n')
# find header lines
start = next(i for i, ln in enumerate(lines) if 'MARSHALL TAB ==' in ln)
end   = next(i for i, ln in enumerate(lines) if 'DECKBOSS TAB ==' in ln)
new_lines = lines[:start] + section.split('\n') + lines[end:]
dlg.write_text('\n'.join(new_lines), encoding='utf-8')
print(f"MARSHALL section replaced (was {end-start} lines, now {len(section.splitlines())})")
