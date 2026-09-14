CarrierGUI LSO Tools — PLAT-cam NVG gain (+ foul deck / wire / PLAT zoom)
==========================================================================

This is the OPTIONAL shader patch that makes the LSO tab's NVG gain dial
actually change the PLAT camera picture (plus the Foul Deck, Wire, and
PLAT Zoom controls). The panel itself works fine without it — these
buttons just won't affect the image.

INSTALL:  right-click Enable-LsoTools.ps1  ->  Run with PowerShell
          (one UAC/admin prompt; next DCS launch is slow — shader rebuild)

REMOVE:   Disable-LsoTools.ps1 the same way. Fully reversible.

READ THIS BEFORE INSTALLING:

  !! FAILS DCS INTEGRITY CHECK !!
     This patches a core shader (gui.fx). On servers that enforce pure
     scripts/textures you will be blocked from joining until you run
     Disable-LsoTools.ps1. Single-player and IC-relaxed squadron servers
     are fine.

  !! EVERY DCS UPDATE REMOVES IT !!
     DCS updates silently restore the stock shader. If the NVG dial stops
     changing the image after a patch day, just re-run Enable-LsoTools.ps1
     — it is safe to re-run any time and re-finds a clean baseline itself.

The scripts search every common drive for your DCS install automatically
and write an install log next to themselves if anything goes wrong.

More: https://github.com/ExpertFett/CarrierGUI
