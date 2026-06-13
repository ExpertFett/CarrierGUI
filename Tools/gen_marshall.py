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
# scope reads to 60 nm at r=148 (2.467 px/nm); rings drawn at 10/25/50 nm
PXNM = 148.0 / 60.0
R10, R25, R50 = round(10*PXNM), round(25*PXNM), round(50*PXNM)   # 25 / 62 / 123
REDGE = 148
SX, SY, SW, SH = 16, 54, 508, 304

L = []
def emit(s=''): L.append(s)
counts = {}

emit('-- ============================================================== MARSHALL TAB ==')
emit('-- v1.3-beta16: solid dot rings + one marshal call + MOTHER info + stack + table')
emit('c.lblMarshallHdr = lbl("CCZ TRACKER  ·  60 nm", PAD, 30, W - PAD*2, LabelSkin, 20)')
emit('')
emit('-- scope field + border')
emit(f'c.mScope = solidW({SX}, {SY}, {SW}, {SH}, SCOPE_BG_SKIN, 1)')
emit(f'c.mBordT = solidW({SX}, {SY}, {SW}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordB = solidW({SX}, {SY+SH}, {SW}, 2, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordL = solidW({SX}, {SY}, 2, {SH}, SCOPE_RG_SKIN, 3)')
emit(f'c.mBordR = solidW({SX+SW}, {SY}, 2, {SH}, SCOPE_RG_SKIN, 3)')
emit('')
emit('-- crosshair (plain rects)')
emit(f'c.mCrossV = solidW({CX}, {CY-REDGE}, 1, {2*REDGE}, SCOPE_LN_SKIN, 2)')
emit(f'c.mCrossH = solidW({CX-REDGE}, {CY}, {2*REDGE}, 1, SCOPE_LN_SKIN, 2)')
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

emit('-- range rings at 10 / 25 / 50 nm (dense dots = solid circles)')
ring_dots('mDotA', R10)
emit('')
ring_dots('mDotB', R25)
emit('')
ring_dots('mDotC', R50)
emit('')

emit('-- own-ship boat marker at scope centre (hull + bow)')
emit(f'c.mShipHull = solidW({CX-4}, {CY-9}, 8, 18, SHIP_MARK_SKIN, 4)')
emit(f'c.mShipBow  = solidW({CX-2}, {CY-13}, 4, 5, SHIP_MARK_SKIN, 4)')
emit(f'c.lblMRcv = lbl("CV", {CX+8}, {CY-2}, 30, CarrierMark, 14)')
emit(f'c.lblMR20 = lbl("10", {CX+4}, {CY-R10-2}, 20, RadarLbl, 12)')
emit(f'c.lblMR40 = lbl("25", {CX+4}, {CY-R25-2}, 20, RadarLbl, 12)')
emit(f'c.lblMR60 = lbl("50", {CX+4}, {CY-R50+2}, 20, RadarLbl, 12)')
emit(f'c.lblMRN  = lbl("N", {CX-4}, {CY-REDGE-16}, 14, RadarLbl, 12)')
emit(f'c.lblMRS  = lbl("S", {CX-4}, {CY+REDGE+2}, 14, RadarLbl, 12)')
emit(f'c.lblMRE  = lbl("E", {CX+REDGE+6}, {CY-8}, 14, RadarLbl, 12)')
emit(f'c.lblMRW  = lbl("W", {CX-REDGE-16}, {CY-8}, 14, RadarLbl, 12)')
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
# (beta18: removed the green 1-4 position numbers inside the pill — the
#  angels labels on the left are enough, per feedback.)
emit('for i = 1, 12 do')
emit('    c["stkSlot" .. i] = lbl("", -300, -300, 44, SpotSkin, 13)')
emit('end')
emit('')

emit('-- ── marshal assignment TABLE (right, bordered grid) ───────────────')
# table box
TX, TW = 238, 290
THDR_Y = 532          # section label
TTOP   = 552          # table top border (header row)
TROWH  = 17
TNROW  = 13
TBOT   = TTOP + (TNROW + 1) * TROWH    # +1 for header row
# column x-edges within the table (6 columns): MODEX ALT RNG BRG ANG EAT
colx = [TX, TX+50, TX+96, TX+140, TX+182, TX+222, TX+TW]
emit(f'c.lblMTblHdr = lbl("MARSHAL STACK  ·  auto-assigned", {TX}, {THDR_Y}, 290, LabelSkin, 16)')
# outer border
emit(f'c.mTblBT = solidW({TX}, {TTOP}, {TW}, 1, SCOPE_RG_SKIN, 3)')
emit(f'c.mTblBB = solidW({TX}, {TBOT}, {TW+1}, 1, SCOPE_RG_SKIN, 3)')
emit(f'c.mTblBL = solidW({TX}, {TTOP}, 1, {TBOT-TTOP}, SCOPE_RG_SKIN, 3)')
emit(f'c.mTblBR = solidW({TX+TW}, {TTOP}, 1, {TBOT-TTOP+1}, SCOPE_RG_SKIN, 3)')
# header underline
emit(f'c.mTblHL = solidW({TX}, {TTOP+TROWH}, {TW}, 1, SCOPE_RG_SKIN, 3)')
# column dividers
for ci in range(1, 6):
    emit(f'c.mTblV{ci} = solidW({colx[ci]}, {TTOP}, 1, {TBOT-TTOP}, SCOPE_LN_SKIN, 2)')
# column header labels (centred-ish in each column)
heads = ['MODEX', 'ALT', 'RNG', 'BRG', 'ANG', 'EAT']
for ci, h in enumerate(heads):
    emit(f'c.lblMTh{ci+1} = lbl("{h}", {colx[ci]+4}, {TTOP+3}, {colx[ci+1]-colx[ci]}, CapSkin, 14)')
# per-cell label pool: 6 cells x TNROW rows -> mCell<row>_<col>
emit('-- per-cell labels (hook fills text per column)')
emit(f'local _cx = {{{", ".join(str(x+4) for x in colx[:6])}}}')
emit(f'for r = 1, {TNROW} do')
emit(f'  for ccol = 1, 6 do')
emit(f'    c["mCell" .. r .. "_" .. ccol] = lbl("", _cx[ccol], {TTOP+TROWH}+(r-1)*{TROWH}+2, 48, RowSkinMon, 15)')
emit('  end')
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
