#!/usr/bin/env python3
"""
Regenerate the MARSHALL tab section of carrier-gui.dlg.

beta16 layout (panel W=540, H=900):
  - Radar scope (dark green, dot rings — denser/solid, crosshair, boat marker).
  - RADIO READOUT: ONE scripted marshal call (4-5 lines).
  - MOTHER: boat info block (BRC / FB / wind across deck / altimeter).
  - Lower-left  STACK: hold pill + angels ladder + fixed 1-4 positions.
  - Lower-right INBOUND: data table (MODEX / ALT / RNG / BRG / ANG).
"""
import math
from pathlib import Path

CX, CY = 270, 206
R20, R40, R60 = 49, 98, 148
SX, SY, SW, SH = 16, 54, 508, 304

L = []
def emit(s=''): L.append(s)
counts = {}

emit('-- ============================================================== MARSHALL TAB ==')
emit('-- v1.3-beta16: solid dot rings + one marshal call + MOTHER info + stack + table')
emit('c.lblMarshallHdr = lbl("CCZ TRACKER  ·  60 nm  ·  N up", PAD, 30, W - PAD*2, LabelSkin, 20)')
emit('')
emit('-- scope field + border')
emit(f'c.mScope = solidW({SX}, {SY}, {SW}, {SH}, SCOPE_BG_SKIN, 1)')
emit(f'c.mBordT = solidW({SX}, {SY}, {SW}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordB = solidW({SX}, {SY+SH}, {SW}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordL = solidW({SX}, {SY}, 2, {SH}, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordR = solidW({SX+SW}, {SY}, 2, {SH}, SCOPE_RG_SKIN, 3)')
emit('')
emit('-- crosshair (plain rects)')
emit(f'c.mCrossV = solidW({CX}, {CY-R60}, 1, {2*R60}, SCOPE_LN_SKIN, 2)')
emit(f'c.mCrossH = solidW({CX-R60}, {CY}, {2*R60}, 1, SCOPE_LN_SKIN, 2)')
emit('')

def ring_dots(prefix, r, gap=6, d=5):
    # dense overlapping square dots -> reads as a solid light-green ring
    n = max(8, int(round(2*math.pi*r/gap)))
    for i in range(n):
        th = 2*math.pi*i/n
        px = CX + r*math.cos(th)
        py = CY + r*math.sin(th)
        emit(f'c.{prefix}{i+1} = solidW({round(px-d/2)}, {round(py-d/2)}, {d}, {d}, SCOPE_RING_SKIN, 3)')
    counts[prefix] = n

emit('-- range rings (dense dots = solid circles)')
ring_dots('mDotA', R20)
emit('')
ring_dots('mDotB', R40)
emit('')
ring_dots('mDotC', R60)
emit('')

emit('-- own-ship boat marker at scope centre (hull + bow)')
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

# Radio readout — one call
emit('-- ── radio readout (one scripted marshal call) ─────────────────────')
emit('c.lblMarRadioHdr = lbl("RADIO READOUT", PAD, 362, W - PAD*2, LabelSkin, 18)')
emit('local CallSkin = mkLabelSkin("0xd8e0c8ff", 13)')
emit('for i = 1, 5 do')
emit('    c["rowMarCall" .. i] = lbl("", PAD, 384 + (i-1)*15, W - PAD*2, CallSkin, 15)')
emit('end')
emit('')

# MOTHER info block (replaces the 2nd radio call)
emit('-- ── MOTHER (boat info) ────────────────────────────────────────────')
emit('c.lblMotherHdr = lbl("MOTHER", PAD, 466, W - PAD*2, LabelSkin, 18)')
emit('c.lblBoat1 = lbl("BRC ---   FB ---   ALT --.--", PAD, 488, W - PAD*2, ValueSkin, 18)')
emit('c.lblBoat2 = lbl("WIND ---/-- kt   ACROSS DECK --", PAD, 508, W - PAD*2, ValueSkin, 18)')
emit('')

# Lower section: stack (left) + table (right)
emit('-- ── marshal stack (left) ──────────────────────────────────────────')
emit('c.lblMarStackHdr = lbl("STACK", PAD, 532, 120, LabelSkin, 18)')
PL, PR, PT, PB = 100, 180, 566, 806
# rung Y for angels a (2..7): a2 at 786 (inset 20 above PB), a7 at 586
def rungY(a): return 786 - (a-2)*40
emit(f'c.sPillL = solidW({PL}, {PT}, 2, {PB-PT}, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillR = solidW({PR}, {PT}, 2, {PB-PT}, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillT = solidW({PL}, {PT}, {PR-PL}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.sPillB = solidW({PL}, {PB}, {PR-PL+2}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.lblStkAng = lbl("angels", {PL-30}, {PT-18}, 60, CapSkin, 12)')
for a in range(2, 8):
    y = rungY(a)
    emit(f'c.lblStkA{a} = lbl("{a}", {PL-24}, {y-8}, 22, RadarLbl, 13)')
    emit(f'c.sRung{a} = solidW({PL}, {y}, {PR-PL}, 1, SCOPE_LN_SKIN, 2)')
# fixed stack POSITION numbers 1..4 inside the pill (pos1=angels2 bottom)
for pos in range(1, 5):
    y = rungY(pos + 1)
    emit(f'c.lblStkP{pos} = lbl("{pos}", {(PL+PR)//2-4}, {y-8}, 16, DeckHdr, 14)')
emit('for i = 1, 12 do')
emit('    c["stkSlot" .. i] = lbl("", -300, -300, 44, SpotSkin, 13)')
emit('end')
emit('')

emit('-- ── inbound data table (right) ────────────────────────────────────')
TX = 280
emit(f'c.lblMTblHdr  = lbl("INBOUND", {TX}, 532, 250, LabelSkin, 18)')
emit(f'c.lblMTblCols = lbl("MODEX  ALT    RNG   BRG  ANG", {TX}, 554, 250, CapSkin, 14)')
emit('for i = 1, 13 do')
emit(f'    c["mTbl" .. i] = lbl("", {TX}, 574 + (i-1)*16, 252, RowSkinMon, 15)')
emit('end')
emit('')
emit('c.lblMarStatus = lbl("(no inbound traffic)", PAD, 834, W - PAD*2, CapSkin, 16)')
emit('')

section = '\n'.join(L) + '\n'
dlg = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\Hooks\carrier-gui.dlg")
text = dlg.read_text(encoding='utf-8')
lines = text.split('\n')
start = next(i for i, ln in enumerate(lines) if 'MARSHALL TAB ==' in ln)
end   = next(i for i, ln in enumerate(lines) if 'DECKBOSS TAB ==' in ln)
dlg.write_text('\n'.join(lines[:start] + section.split('\n') + lines[end:]), encoding='utf-8')
print(f"MARSHALL replaced. ring dot counts: {counts}")
