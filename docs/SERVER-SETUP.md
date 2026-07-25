# CarrierGUI on a server

There are two ways to run CarrierGUI on a server. Pick by how you host.

---

## A. Dedicated server — F10 radio menu  (no GUI panel)

A headless dedicated server (`DCS_server.exe`) can't render the Ctrl+Shift+c
panel or read it from a remote client. So on a dedicated server the controls
live on the **in-game F10 radio menu**, built by the mission **bridge**. Any
connected player opens **F10 → Carrier Control**; all calls broadcast to pilots
as on-screen text. No GUI, no client install.

### Install (per mission)

1. **Patch the mission** the server runs — drag its `.miz` onto
   `Patcher\Patch Mission.bat` (or run
   `Patcher\python\python.exe Patcher\patch_miz.py <mission>.miz`). This embeds
   the bridge + the F10 menu + the deck-lights triggers. A `.miz.bak` backup is
   made. **Re-patch every new/updated mission.**
2. Drop the patched `.miz` in the server's `…\Missions\` folder and select it in
   the server mission list.
3. Start the server. Nothing else to install — the bridge ships inside the
   mission.

### Use (any connected player)

**F10 → Carrier Control:**
- **Recovery Case** → Set CASE I / II / III
- **Broadcast Marshal Stack** · **Charlie / Push Stack**
- **Turn Into Wind** → Stop / 30m / 60m / 90m / 2h / 4h / 8h
- **Beacons** → TACAN / ICLS / LINK4 / ACLS on·off
- **Deck Lights** → Off / Auto / Nav / Launch / Recovery
- **LSO Calls** → Wave Off / Cut / Bingo / Recovery Complete / Foul / Clear

Each pick takes effect within ~1 s (the bridge polls at 1 Hz) and the result is
broadcast to all players. **A Supercarrier (or LHA) must be in the mission** for
the marshal/beacon/wind/lights actions to have a target — the CASE broadcasts
work regardless.

### Notes

- The menu is built for **all players** by default. To restrict it (e.g. one
  coalition), say the word and I'll switch it to `addCommandForCoalition`.
- **No GUI radar/tables on a dedicated server** — that needs an external relay
  app (separate project).

---

## B. Listen-server host — the full GUI panel

If one person **hosts the mission AND runs the panel** (everyone else just
flies), the panel works exactly like single-player **on the host machine**,
because the mission runs locally there.

1. **Patch the mission** (same as above — embeds the bridge).
2. **Install the panel** on the host: copy `Hooks\carrier-gui-hook.lua` +
   `Hooks\carrier-gui.dlg` to `%USERPROFILE%\Saved Games\DCS\Scripts\Hooks\`
   (or install the `dist\CarrierGUI_v1.3-betaNN.ozp` with Open Mod Manager).
3. Host the patched mission, press **Ctrl+Shift+c**.

**Only the host gets live data.** A remote client's panel comes up empty — DCS
runs mission scripting only on the host, so `net.dostring_in("server", …)` has
nothing to read on another machine.

---

## Integrity Check (both modes)

| Piece | IC status |
|-------|-----------|
| Mission bridge + F10 menu (inside the `.miz`) | ✅ part of the mission. |
| Panel (`Scripts\Hooks` hook + `.dlg`) | ✅ IC-safe — Scripts/Hooks aren't checked. |
| PLAT-cam NVG shader patch (`gui.fx`) | ❌ fails IC — **SP / IC-OFF only.** Skip on IC-on servers; you lose only the PLAT night-vision. |

`MissionScripting.lua` needs no changes in either mode. Demo preview jets are
auto-disabled in multiplayer.
