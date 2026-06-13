#!/usr/bin/env python3
"""
Regenerate the MARSHALL tab section of carrier-gui.dlg.

beta14 design:
  - Radar scope: dark-green field, crosshair, and range rings drawn as
    DOTS (tiny non-rotated rects) — the same primitive that already renders
    the background/crosshair, so rings are guaranteed solid (no rotation).
  - Radio readout: scripted marshal call (prose), nearest few aircraft.
  - Lower-left: marshal stack — a plain rectangle hold (no rotation) + angels
    ladder; aircraft placed by assigned angels.
  - Lower-right: DATA TABLE (MODEX / ALT / RNG / BRG / ANG) the hook fills,
    with example rows when there's no traffic.
"""
import math
from pathlib import Path

CX, CY = 270, 206
R20, R40, R60 = 49, 98, 148
SCOPE_X, SCOPE_Y, SCOPE_W, SCOPE_H = 16, 54, 508, 304

L = []
def emit(s=''): L.append(s)
counts = {}

emit('-- ============================================================== MARSHALL TAB ==')
emit('-- v1.3-beta14: dot-drawn radar rings (no rotation) + data table.')
emit('c.lblMarshallHdr = lbl("CCZ TRACKER  ·  60 nm  ·  N up", PAD, 30, W - PAD*2, LabelSkin, 20)')
emit('')
emit('-- scope field + border')
emit(f'c.mScope = solidW({SCOPE_X}, {SCOPE_Y}, {SCOPE_W}, {SCOPE_H}, SCOPE_BG_SKIN, 1)')
emit(f'c.mBordT = solidW({SCOPE_X}, {SCOPE_Y}, {SCOPE_W}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordB = solidW({SCOPE_X}, {SCOPE_Y+SCOPE_H}, {SCOPE_W}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordL = solidW({SCOPE_X}, {SCOPE_Y}, 2, {SCOPE_H}, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordR = solidW({SCOPE_X+SCOPE_W}, {SCOPE_Y}, 2, {SCOPE_H}, SCOPE_RG_SKIN, 3)')
emit('')
emit('-- crosshair (plain rects, no rotation)')
emit(f'c.mCrossV = solidW({CX}, {CY-R60}, 1, {2*R60}, SCOPE_LN_SKIN, 2)')
emit(f'c.mCrossH = solidW({CX-R60}, {CY}, {2*R60}, 1, SCOPE_LN_SKIN, 2)')
emit('')

def ring_dots(prefix, r, gap=8, dw=4, dh=4):
    n = max(8, int(round(2*math.pi*r/gap)))
    for i in range(n):
        th = 2*math.pi*i/n
        px = CX + r*math.cos(th)
        py = CY + r*math.sin(th)
        emit(f'c.{prefix}{i+1} = solidW({round(px-dw/2)}, {round(py-dh/2)}, {dw}, {dh}, SCOPE_RING_SKIN, 3)')
    counts[prefix] = n

emit('-- range rings drawn as dots (guaranteed solid; no rotation)')
ring_dots('mDotA', R20)
emit('')
ring_dots('mDotB', R40)
emit('')
ring_dots('mDotC', R60)
emit('')

# own-ship marker — a small amber "boat" (hull rect + bow nub) at centre
emit(f'c.mShipHull = solidW({CX-4}, {CY-9}, 8, 18, SHIP_MARK_SKIN, 4)')
emit(f'c.mShipBow  = solidW({CX-2}, {CY-13}, 4, 5, SHIP_MARK_SKIN, 4)')
emit(f'c.lblMRcv = lbl("CV", {CX+8}, {CY-2}, 30, CarrierMark, 14)')
emit(f'c.lblMR20 = lbl("20", {CX+4}, {CY-R20-2}, 20, RadarLbl, 12)')
emit(f'c.lblMR40 = lbl("40", {CX+4}, {CY-R40-2}, 20, RadarLbl, 12)')
emit(f'c.lblMR60 = lbl("60", {CX+4}, {CY-R60+2}, 20, RadarLbl, 12)')
emit(f'c.lblMRN  = lbl("N", {CX-4}, {CY-R60-16}, 14, RadarLbl, 12)')
emit(f'c.lblMRS  = lbl("S", {CX-4}, {CY+R60+2}, 14, RadarLbl, 12)')
emit(f'c.lblMRE  = lbl("E", {CX+R60+6}, {CY-8}, 14, RadarLbl, 12)')
emit(f'c.lblMRW  = lbl("W", {CX-R60-16}, {CY-8}, 14, RadarLbl, 12)')
emit('')
emit('-- aircraft scatter slots on the scope (hook positions by brg/nm)')
emit('for i = 1, 12 do')
emit('    c["rowCcz" .. i] = lbl("", -300, -300, 60, SpotSkin, 14)')
emit('end')
emit('')

# Radio readout (prose)
emit('-- ── radio readout (scripted marshal call) ──────────────────────────')
emit('c.lblMarRadioHdr = lbl("RADIO READOUT", PAD, 366, W - PAD*2, LabelSkin, 18)')
emit('local CallSkin = mkLabelSkin("0xd8e0c8ff", 13)')
emit('for i = 1, 8 do')
emit('    c["rowMarCall" .. i] = lbl("", PAD, 388 + (i-1)*15, W - PAD*2, CallSkin, 15)')
emit('end')
emit('')

# Lower section: stack (left) + data table (right)
emit('-- ── marshal stack (left: hold rectangle + angels ladder) ───────────')
emit('c.lblMarStackHdr = lbl("STACK", PAD, 514, 120, LabelSkin, 18)')
PL, PR, PT, PB = 70, 150, 556, 800
emit(f'c.sPillL = solidW({PL}, {PT}, 2, {PB-PT}, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillR = solidW({PR}, {PT}, 2, {PB-PT}, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillT = solidW({PL}, {PT}, {PR-PL}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillB = solidW({PL}, {PB}, {PR-PL+2}, 2, SCOPE_RG_SKIN, 3)')
# angels ladder on the LEFT (altitude), rungs across the pill
RSTEP = (PB-PT)//6
for a in range(2, 8):
    y = PB - (a-2)*RSTEP
    emit(f'c.lblStkA{a} = lbl("{a}", {PL-26}, {y-8}, 22, RadarLbl, 13)')
    emit(f'c.sRung{a} = solidW({PL}, {y}, {PR-PL}, 1, SCOPE_LN_SKIN, 2)')
emit('c.lblStkAng = lbl("angels", ' + str(PL-30) + ', ' + str(PT-18) + ', 60, CapSkin, 12)')
# stack POSITION numbers 1..4 INSIDE the pill at the lowest 4 rungs
# (position 1 = angels 2 = first to commence)
for pos in range(1, 5):
    a = pos + 1                       # pos1->angels2 ... pos4->angels5
    y = PB - (a-2)*RSTEP
    emit(f'c.lblStkP{pos} = lbl("{pos}", {(PL+PR)//2-4}, {y-8}, 16, DeckHdr, 14)')
emit('for i = 1, 12 do')
emit('    c["stkSlot" .. i] = lbl("", -300, -300, 46, SpotSkin, 13)')
emit('end')
emit('')

emit('-- ── data table (right: MODEX / ALT / RNG / BRG / ANG) ──────────────')
TX = 196
emit(f'c.lblMTblHdr  = lbl("INBOUND", {TX}, 514, 340, LabelSkin, 18)')
emit(f'c.lblMTblCols = lbl("MODEX   ALT     RNG    BRG   ANG", {TX}, 536, 340, CapSkin, 14)')
emit('for i = 1, 14 do')
emit(f'    c["mTbl" .. i] = lbl("", {TX}, 556 + (i-1)*16, 340, RowSkinMon, 15)')
emit('end')
emit('')
emit('c.lblMarStatus = lbl("(no inbound traffic)", PAD, 832, W - PAD*2, CapSkin, 16)')
emit('')

section = '\n'.join(L) + '\n'
dlg = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\Hooks\carrier-gui.dlg")
text = dlg.read_text(encoding='utf-8')
lines = text.split('\n')
start = next(i for i, ln in enumerate(lines) if 'MARSHALL TAB ==' in ln)
end   = next(i for i, ln in enumerate(lines) if 'DECKBOSS TAB ==' in ln)
dlg.write_text('\n'.join(lines[:start] + section.split('\n') + lines[end:]), encoding='utf-8')
print(f"MARSHALL replaced. ring dot counts: {counts}")
