# CarrierGUI agents — in-DCS panel on any server (Architecture A)

These two small zero-dependency Python agents bridge the Railway relay to DCS, so
a controller running the **in-DCS panel** can manage carrier recovery on **any**
multiplayer server. Run them windowless with `pythonw.exe`.

```
[DCS server box]                        [Railway relay]            [Controller PC]
 bridge writes carriergui_*.txt   ──>   /recovery/<id>   ──>   controller agent writes
 server agent POSTs them                                        carriergui_*.txt locally
 server agent writes carriergui_cmd.txt <── /cmd/<id>  <──      panel buttons -> panel_cmd
 bridge drains cmd -> user flags                                controller agent POSTs them
```

Data flow verified end-to-end (snapshot + command round-trip).

## 0. Relay (once)
Deploy `../relay/` to Railway, set `RELAY_TOKEN`. (See `../relay/README.md`.)

## 1. DCS server box
1. **Desanitize** `MissionScripting.lua` in the server install (comment out the
   `sanitizeModule('io')` and `sanitizeModule('lfs')` lines) — so the bridge can
   write the snapshot files and read the command file. (Server already wants this
   for MSRS.)
2. The injector hook + bridge are already deployed (`Scripts\Hooks\`); the bridge
   writes the 5 `carriergui_*.txt` files + drains `carriergui_cmd.txt`.
3. Copy this `agent/` folder onto the server. Make `carriergui_agent.json` from
   `config.example.json`:
   - `dcs_writedir` = the **server** profile, e.g.
     `C:\\Users\\Fett\\Saved Games\\DCS.dcs_serverrelease\\`
   - `server_id` = a name for this server (e.g. `cv73`)
4. Run: `pythonw carriergui_serveragent.py` (auto-start with the server).

## 2. Controller PC
1. Install the panel hook + dlg (the normal CarrierGUI client install), then set
   **`local RELAY_MODE = true`** near the top of `carrier-gui-hook.lua`. This makes
   the panel read the relayed files and send button presses through the relay
   instead of the (unreachable) remote mission.
2. Copy this `agent/` folder. Make `carriergui_agent.json`:
   - `dcs_writedir` = the **client** profile, e.g. `C:\\Users\\Fett\\Saved Games\\DCS\\`
   - `server_id` = **same** as the server's
   - same `relay_url` + `relay_token`
3. Run: `pythonw carriergui_controller.py`
4. Launch DCS, connect to the server, **Ctrl+Shift+c** → the panel shows the live
   recovery picture; CASE / broadcast / wind / beacons / lights / LSO buttons all
   work via the relay.

## Notes
- `server_id` ties a server's snapshot to its controllers — run many servers off
  one relay by giving each a unique id.
- The panel marks data **STALE** if the relay snapshot is older than 15 s (server
  agent stopped or server down).
- Python: use the interpreter bundled at `..\Patcher\python\pythonw.exe` if the
  box has no system Python.
