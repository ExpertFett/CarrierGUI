================================================================
 CarrierGUI — Controller install (manage carrier recovery on any server)
================================================================

WHAT THIS IS
  The in-DCS carrier-recovery panel (Ctrl+Shift+c) that works while connected
  to a remote multiplayer server. A tiny background agent pulls the live picture
  from your squad's relay and feeds the panel; your button presses go back the
  same way. Everything needed is bundled (no Python install).

INSTALL (via Open Mod Manager)
  1. Add CarrierGUI-Controller_v*.ozp to your OMM mod library and ENABLE it.
     (Installs the panel into Saved Games\DCS\Scripts\Hooks and this companion
      folder into Saved Games\DCS\CarrierGUI-Controller.)

ONE-TIME SETUP
  2. In Saved Games\DCS\CarrierGUI-Controller, run  Setup.bat
     Enter the Relay URL, token, and Server-ID your squad admin gives you.

RUN IT
  3. Double-click  Start-Controller-Agent.vbs   (runs hidden in the background).
  4. Launch DCS, join the squad server, slot in, press  Ctrl+Shift+c.
     The panel auto-detects the agent and shows the live recovery picture; all
     the control buttons work through the relay.

NOTES
  - The panel shows "STALE" if the server stops sending (server down / agent off).
  - To stop the agent: end "pythonw.exe" in Task Manager (or just close it on reboot).
  - No agent running? The panel falls back to normal (host/SP) behavior.
  - You only need Setup once; the agent reads carriergui_agent.json each launch.
================================================================
