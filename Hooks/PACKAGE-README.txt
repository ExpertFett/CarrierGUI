CarrierGUI — in-DCS carrier air-boss panel (VR-friendly)
=========================================================

TOGGLE:  Ctrl+Shift+C   (in a mission, any slot)
RESIZE:  Ctrl+Shift+I / Ctrl+Shift+K  (or drag the window corner)

FIRST OPEN — the login screen:
  CONNECT ............ your squad's DCS Olympus server (port 3000 or 4512)
                       + the Game-master password.  Full live picture on any
                       server running Olympus; nothing else to install.
  LOCAL / HOST MODE .. single-player or when YOU host the mission.
                       Adds live wind / weather / QNH.

TABS:
  MARSHALL .. 60 nm radar, marshal table + EATs, radio readback, wind/CASE
  TOWER ..... CASE I overhead + angels 2-6 stack, click-to-Charlie,
              level-off radar; CASE II/III marshal racetrack
  LSO ....... live pattern plot, groove timer, AUTO-PADDLES pass grading,
              WAVE OFF / CUT, PLAT NVG gain, recovery sequence
  DECKBOSS .. top-down deck picture, ON DECK list, conga route,
              lights + TACAN / ICLS / LINK4 / ACLS

RECOMMENDED EXTRA:
  (ROOT)_CarrierGUI_Images_*.ozp — install with OMM target = your DCS
  INSTALL folder.  Adds the radar-scope + deck images (otherwise the panel
  uses simple dot-ring fallbacks).

NOTES:
  * This package is IC-safe: pure Scripts\Hooks, no game files touched.
  * Control buttons (lights/beacons/wind/broadcasts) act in SP / hosted
    missions or missions patched with the bridge — on a remote server the
    panel is a live DISPLAY.
  * More: https://github.com/ExpertFett/CarrierGUI
