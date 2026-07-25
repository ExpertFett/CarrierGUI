================================================================
 CarrierGUI - Server Admin Pack
================================================================

Sets up the relay + your DCS dedicated server so controllers can manage carrier
recovery from anywhere. Controllers install the SEPARATE
CarrierGUI-Controller_v*.ozp in Open Mod Manager - you just give them the relay
URL, token, and server-id.

WHAT'S IN HERE
  relay\      tiny Node relay service -> deploy to Railway
  Server\     Install-Server.ps1 (desanitize + bridge + injector + agent)
  Patcher\    Patch Mission.bat (embeds the bridge into your .miz) + bundled Python
  agent\      the server agent + its windowless launcher

ONE-TIME SETUP
  1. RELAY (Railway): deploy the relay\ folder as a new service and set the env
     var RELAY_TOKEN to a long random string. See relay\README.md. Note the URL.

  2. SERVER: open PowerShell in this folder and run:
        Server\Install-Server.ps1
     (If your paths differ, pass:
        -ServerInstall "D:\DCS World Server"
        -ServerProfile "%USERPROFILE%\Saved Games\DCS.dcs_serverrelease")
     It will: desanitize io/lfs in MissionScripting.lua (backup made), install the
     bridge + injector into the server's Scripts\Hooks, stage the server agent
     (with its own Python + launcher), and ask for your relay URL / token /
     server-id.

  3. MISSIONS: drag each .miz onto  Patcher\Patch Mission.bat  to embed the
     bridge + carrier lights triggers. Re-patch any new/updated mission.

RUN
  4. Start the server agent (runs hidden): double-click
        <server profile>\CarrierGUI-Server\Start-ServerAgent.vbs
     (or auto-start it alongside your dedicated server).
  5. Start the dedicated server on a patched mission.

GIVE YOUR CONTROLLERS
  - the relay URL, the token, and the server-id (exactly as entered)
  - the CarrierGUI-Controller_v*.ozp (they enable it in Open Mod Manager)

VERIFY
  - server dcs.log shows  [CarrierGUI Bridge]  on mission start
  - run agent\carriergui_serveragent.py directly once to watch it push snapshots
    (no "push failed" lines once the relay + a carrier mission are up)

NOTE
  Desanitizing applies server-wide, so only run missions you trust. (You likely
  already need it for MSRS / SRS.)
================================================================
