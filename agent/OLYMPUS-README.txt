================================================================
 CarrierGUI - Controller install (OLYMPUS - connect like DCS:OPT Live)
================================================================

Connects straight to your squad's DCS Olympus backend with host + password,
pulls the FULL unit picture (no MP culling), and feeds the in-DCS panel. No
mission patch, no hooks, no relay, no desanitize - Olympus is the server side,
which your squad already runs. Everything bundled (no Python install).

REQUIRES
  - The server runs DCS Olympus (most squads do).
  - You know the Olympus host/port and the "Game master" role password.

INSTALL (Open Mod Manager)
  1. Enable CarrierGUI-Olympus_v*.ozp in OMM.

ONE-TIME SETUP
  2. In  Saved Games\DCS\CarrierGUI-Olympus , run  Setup-Olympus.bat
     Enter the Olympus host, port (often 4512, or 3000 for the web UI), and the
     Game master password.

RUN
  3. Double-click  Start-Olympus-Agent.vbs  (runs hidden).
  4. Launch DCS, join the server, press  Ctrl+Shift+c .  Full live recovery
     picture - marshal stack and all, no range culling.

CONTROL
  Read-only picture. To command AI carrier ops (CASE/broadcast/wind/beacons),
  use the F10 radio menu (needs the mission patched with the bridge), the same
  as the other modes.

NOTES
  - Uses the same Olympus API as DCS:OPT Live (Game master role).
  - The panel shows STALE if Olympus stops responding.
  - No wind/altimeter yet in this mode (could be added from Olympus mission data).
================================================================
