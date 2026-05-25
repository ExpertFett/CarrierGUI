# CarrierGUI

An in-DCS, VR-friendly GUI that replaces the F10 radio menu for AI carrier
control. Toggle it with **Ctrl+Shift+c** — it renders inside DCS, so it works
in VR without alt-tabbing.

> Personal project, free to share within DCS squadrons. Not affiliated with
> Eagle Dynamics or any third party.

## Features

**Carrier tab**
- **Lights** — Off / Auto / Nav / Launch / Recovery
- **TACAN / ICLS / LINK 4 / ACLS** — on/off, using the channels/freqs set in the
  mission editor
- **Turn Into Wind** — Stop / 30m / 60m / 90m / 2h / 4h / 8h (auto-computes
  heading + speed from live wind)

**Marshall tab**
- **Recovery CASE** — broadcast CASE I / II / III to all players
- **Marshal stack** — broadcast a USN-standard CASE III stack (radial / DME /
  angels per flight), auto-read from the carrier's live heading
- **Charlie / push** — broadcast the expected push time

The bridge auto-discovers any CVN- or LHA-class carrier in the mission — no
specific group/unit names required.

## How it works (3 pieces)

| Piece | Runs in | Job |
|-------|---------|-----|
| `Hooks/carrier-gui-hook.lua` + `.dlg` | DCS GUI hook env | Draws the panel, registers the hotkey, fires numbered user flags |
| `Patcher/carrier-gui-bridge.lua` | in-mission script (embedded per-`.miz`) | Polls flags; drives beacons, wind, and marshall broadcasts |
| `Patcher/patch_miz.py` | standalone Python | Embeds the bridge + writes the 5 lights triggers into a `.miz` |

Lights need trigger-eval-env access to `a_set_carrier_illumination_mode`, so
they're written as native mission triggers by the patcher. Everything else the
bridge handles directly.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the DCS Lua state map and
the hard-won gotchas (trigger predicates, hotkey binding, etc.).

## Install (pilots)

1. Download the latest release zip and extract it (keep the folder together).
2. Double-click **`Install.bat`** — copies the hook into every detected DCS
   Saved Games folder.
3. Restart DCS, start a mission, press **Ctrl+Shift+c**.

## Patch a mission (mission designers)

For the buttons to do anything in a given mission, the `.miz` must contain the
bridge. Pilots don't patch — only whoever distributes the squadron's missions.

1. Drag one or more `.miz` files onto **`Patcher/Patch Mission.bat`**.
2. Hand out the patched `.miz`. (A `.miz.bak` backup is made on first patch.)

Re-running is safe and idempotent. To undo: drag onto `Patcher/Revert Mission.bat`.

The patcher ships with a bundled Python in `Patcher/python/` (in the release
zip), so end users need nothing installed.

## Flag map

```
 1-8     beacons (TACAN/ICLS/LINK4/ACLS off/on)   bridge WrappedAction
 10-14   lights (Off/Auto/Nav/Launch/Recovery)    patcher-written triggers
 100-106 wind (Stop/30m/60m/90m/2h/4h/8h)         bridge controller:setTask
 200     marshal-stack broadcast                  bridge outText
 201     Charlie broadcast                         bridge outText
 202-204 recovery CASE I / II / III broadcast      bridge outText
```

Numbering matches the common CSG3 / squadron MOOSE F10 scripts, so both can
coexist harmlessly.

## Build a release

```
python Tools/build_release.py 0.4
```

Downloads the Python embeddable (if missing), stages the installer layout, and
writes `dist/CarrierGUI-v0.4.zip`. Attach that zip to a GitHub Release.

## Status

Active reconstruction. Current version **v0.4**. Carrier-tab buttons confirmed
working in the field; marshall tab and the dxgui stepper controls are new and
being validated in-game.
