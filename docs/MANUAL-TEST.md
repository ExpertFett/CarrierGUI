# Manual test — in-DCS panel on the dedicated server (one PC, localhost relay)

This validates the whole relay chain on a single machine before you put the relay
on Railway. You run the dedicated server + your DCS client on the same PC; the
relay runs on localhost. (Use plain `python` while testing so you see the logs;
switch to `pythonw` later to run them windowless.)

Paths assume the repo at `C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI`.

## 1. Relay (localhost)
Terminal:
```
set RELAY_TOKEN=test
node "C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\relay\server.js"
```
Leave it running. Check: open http://localhost:8090/health → `{"ok":true,...}`.

## 2. Desanitize the server (server STOPPED)
Edit `D:\DCS World Server\Scripts\MissionScripting.lua`, comment out **lines 17
and 18** (leave `os` alone):
```
--sanitizeModule('io')
--sanitizeModule('lfs')
```
This lets the bridge write the snapshot files + read the command file.

## 3. Update the server bridge (beta47 — adds command draining)
Copy
`...\CarrierGUI\Patcher\carrier-gui-bridge.lua`
→ `C:\Users\Fett\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\carrier-gui-bridge.lua`
(overwrite). The injector hook loads it on mission start.

Then **re-patch the mission** so the embedded copy matches (safety — whichever
load path wins, it's the new bridge): drag
`...\Missions\Hornet_School_VFRv6.5night.miz` onto `Patcher\Patch Mission.bat`.
(The `.miz` already on the server can just be re-patched in place.)

## 4. Server agent
Terminal:
```
set CARRIERGUI_AGENT_CFG=C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\agent\server.local.json
python "C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\agent\carriergui_serveragent.py"
```
Leave running. (Once the server's up and the mission has a carrier, it should
stop printing "push failed" and just push silently.)

## 5. Controller hook (your DCS client)
Copy both
`...\CarrierGUI\Hooks\carrier-gui-hook.lua` and `carrier-gui.dlg`
→ `C:\Users\Fett\Saved Games\DCS\Scripts\Hooks\`
Then edit the hook and set:
```
local RELAY_MODE = true
```

## 6. Controller agent
Terminal:
```
set CARRIERGUI_AGENT_CFG=C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\agent\controller.local.json
python "C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI\agent\carriergui_controller.py"
```

## 7. Run the test
1. Start the dedicated server on the **Hornet night** mission (it has CVN_73).
2. Start DCS, connect to your server (`localhost`), slot into a Hornet.
3. **Ctrl+Shift+c** → the panel shows the live recovery picture (relayed from the
   server). Spawn/marshal a jet and watch it appear.
4. Press **Set CASE III / Broadcast Marshal Stack** etc. → the command rides the
   relay back to the server and fires (pilots see the broadcast).

## What "working" looks like
- **Relay**: `/health` ok; server-agent console pushing; controller-agent console
  prints "snapshot live".
- **Files**: `C:\Users\Fett\Saved Games\DCS\carriergui_ccz.txt` (etc.) appear and
  update ~1/s.
- **Panel**: shows traffic; reads **STALE** if you stop the server agent.
- **Commands**: a panel button press shows in the controller-agent console
  ("sent cmd flag N"), then the server-agent console ("queued 1 command").

## If something's off
- Panel empty → is the controller agent writing files to `Saved Games\DCS\`? Is
  `RELAY_MODE = true`? Restart DCS after editing the hook.
- No files on the server side → MissionScripting not desanitized, or the bridge
  isn't loading (check the server `dcs.log` for `[CarrierGUI Bridge]`).
- `push failed`/`pull failed` in an agent → relay not running or wrong
  `relay_url`/`relay_token`.
