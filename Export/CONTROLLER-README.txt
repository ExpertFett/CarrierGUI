================================================================
 CarrierGUI - Controller install  (the easy "turn on and work" way)
================================================================

Reads the live recovery picture straight from your DCS client's object export -
the same data source Tacview uses. No relay, no background agent, no Python.

INSTALL (Open Mod Manager)
  1. Add CarrierGUI-Controller_v*.ozp to your OMM library and ENABLE it.

ONE-TIME SETUP
  2. In  Saved Games\DCS\CarrierGUI-Controller , run  Setup-Export.bat
     (wires CarrierGUI into your DCS Export.lua - safe alongside Tacview/SRS;
      idempotent, run it again any time).

RUN
  3. Launch DCS, join the server, slot in near the carrier (or a recovery slot),
     press  Ctrl+Shift+c .  The panel shows the live recovery picture.

CONTROL (optional)
  Export is READ-ONLY - it shows the picture.  To command AI carrier ops
  (set CASE, broadcast marshal, turn into wind, beacons), the server's mission
  must be patched with the CarrierGUI bridge; then control from the in-cockpit
  F10 radio menu -> Carrier Control.

GOOD TO KNOW
  - Needs the server to allow object export (most do; it's what Tacview uses).
    On locked-down public servers the far marshal stack (20-30 nm) can be thin -
    that's the server's setting, not a bug.
  - Wind / altimeter / weather aren't available to client export, so those
    readouts stay blank in this mode.
  - Heavy-duty alternative (guaranteed far-marshal coverage + panel-button
    control) is the relay setup - see the Admin pack.
================================================================
