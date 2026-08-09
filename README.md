# CarrierGUI

An in-DCS, VR-friendly **carrier air-boss panel**: marshal, tower, LSO and deck
control on one hotkey — **Ctrl+Shift+C** — rendered inside DCS so it works in VR
without alt-tabbing. Built for squadron CQ nights and LSO/controller duty.

> Personal project, free to share within DCS squadrons. Not affiliated with
> Eagle Dynamics or any third party.

## What you get

| Tab | What it shows |
|-----|---------------|
| **MARSHALL** | 60 nm CCZ radar with bearing leaders, flight-clustered marshal table ("203 +1"), angels/EAT assignments, scripted marshal radio readback (CV-1 phrasing), MOTHER data block, live weather, turn-into-wind + CASE broadcast buttons |
| **TOWER** | CASE I 5 nm overhead + angels 2–6 stack ladder (500 ft rungs), click-to-Charlie stack management, auto-commence, **LEVEL-OFF radar** (the commence→break / spin band nobody can see otherwise), CASE II/III marshal racetrack with radial/DME/EAT |
| **LSO** | Live pattern plot sized from real squadron tacviews, groove timer, **AUTO-PADDLES** — native LSO grading of every pass (zones X/IM/IC/AR, shorthand like `(H)X (LUL)IM`, wire estimate, OK/FAIR/NG/CUT/Bolter/WO), WAVE OFF / CUT lights, PLAT NVG gain, recovery-sequence list |
| **DECKBOSS** | Real top-down deck image with live aircraft plots, ON DECK list with zones, **conga-line taxi route** overlay, deck lights + TACAN/ICLS/LINK4/ACLS controls |

Off-altitude jets flag **red** in every table (>100 ft off assigned marshal
altitude). Altitudes are rounded to 50 ft for a clean read.

## Install (Open Mod Manager)

1. Download `CarrierGUI_vX.Y.ozp` from [Releases](../../releases).
2. Add it to OMM with target **Saved Games\DCS** (or your DCS variant's
   Saved Games folder) and install. The panel is IC-safe — pure
   `Scripts\Hooks`, no game-file edits.
3. *(Recommended)* also install `(ROOT)_CarrierGUI_Images_vX.Y.ozp` with target
   **your DCS install folder** — adds the MARSHALL radar-scope and DECKBOSS
   deck images (without it you get functional dot-ring fallbacks).

Manual install: open the `.ozp` as a zip, copy its `Scripts` folder into
`Saved Games\DCS\`.

## Quick start

1. In a mission (any slot — pilot, LSO, spectator), press **Ctrl+Shift+C**.
2. The **login screen** appears. Two ways to feed the panel:
   - **CONNECT (Olympus)** — your squad's [DCS Olympus](https://github.com/Pax1601/DCSOlympus)
     server address (port 3000 or 4512) + Game-master password. Full live
     picture on any server running Olympus — no mission patching needed.
   - **LOCAL / HOST MODE** — single-player, or when you host the mission:
     reads the mission directly and adds live wind / weather / QNH.
3. Pick a tab and run the recovery.

### Sizing (VR)

- **Ctrl+Shift+I / Ctrl+Shift+K** — bigger / smaller from any tab, instant
  (75 / 100 / 125 / 150 %).
- Or **drag the window corner** — rebuilds at that size on release.
- Or the **UI SIZE** button on the login screen.

## Optional add-ons

| Package | What | Notes |
|---------|------|-------|
| `(ROOT)_CarrierGUI_Images` | radar + deck scope images | targets the DCS **install** folder |
| `CarrierGUI-Controller` | Export.lua data source ("Tacview model") | full picture as a **client** on servers without Olympus; read-only |
| `CarrierGUI-Olympus` | standalone Python agent | legacy alternative to the built-in Olympus login |
| LSO tools patch (`LSO/Enable-LsoTools.ps1`, repo only) | PLAT-cam **NVG gain** | edits game files — **fails DCS integrity check**; SP / IC-off servers only; re-run after every DCS update |
| Mission patcher (`Patcher/`) | embeds the control bridge + deck-lights triggers into a `.miz` | needed for the control buttons on dedicated servers; drag-drop `Patch Mission.bat` |

## Notes & limitations

- Carrier **control** actions (lights, beacons, wind, broadcasts) run in SP /
  hosted missions, or on servers whose missions carry the bridge (`Patcher/`).
  In pure Olympus mode against a server you don't administer, the panel is a
  full **display** and control buttons no-op.
- Deck lights specifically require the mission patcher (DCS limitation: the
  lights API only exists in trigger actions).
- BRC/radials display **magnetic** (exact per-map, per-date declination via
  DCS's own magvar library).
- AUTO-PADDLES grades from 1 Hz telemetry — treat it as a very consistent
  practice LSO, not a NATOPS authority.

## For developers

`docs/ARCHITECTURE.md` has the DCS Lua state map and the hard-won gotchas
(DialogLoader's global-free dlg environment, trigger predicates, hotkey
binding, TGA orientation, magvar API). Packages build with
`python Tools/build_ozp.py <version>` (+ `build_controller_ozp.py`,
`build_olympus_ozp.py`).

## Credits

Built by **CSG-3 | Fett | 415** with heavy AI assistance. Deck-spotting
diagram by Nanne118. Pattern geometry derived from squadron tacview data.
