# CarrierGUI architecture & gotchas

## DCS Lua state map

CarrierGUI is split into three pieces because no single DCS Lua environment can
reach everything it needs. Verified through (painful) trial and error.

| Environment | Has | Lacks |
|-------------|-----|-------|
| **Hook env** (`carrier-gui-hook.lua`) | `DCS.*`, `net.*`, `DialogLoader`, `lfs`, `dxgui`, `Skin` | mission scripting |
| **`net.dostring_in("server", ...)` sandbox** | `trigger.action.*`, `env`, `timer`, `Group`, `Unit`, `coalition`, `atmosphere`, std libs | `a_*`, `mission.trig`, MOOSE |
| **`a_do_script` env** (the bridge) | the above **+** `env.mission` readable **+** `controller:setTask/pushTask` | still no `a_*`, no `mission.trig` |
| **Trigger action-string eval env** | `a_*`, `c_*`, all DCS scripting | (this is where the patcher's lights triggers run) |

`a_set_carrier_illumination_mode` lives only in the last env, which is why the
**lights** buttons require the patcher to write native mission triggers — the
bridge can't reach that function.

## Data flow

```
button click (hook env)
   └─ net.dostring_in("server", 'trigger.action.setUserFlag("N", true)')
        └─ bridge poll loop (1 Hz) sees flag N == 1
             ├─ beacons  → controller:pushTask(WrappedAction ...)
             ├─ wind     → controller:setTask(Mission route, action="Off Road")
             └─ marshall → trigger.action.outText(...)
        └─ lights flags (10-14) are seen by patcher-written triggers instead,
           which call a_set_carrier_illumination_mode in the trigger eval env
```

The hook also reads a flag back via `net.dostring_in("server", "return ...")` to
detect whether the current mission is patched (bridge sets
`carriergui_bridge_loaded` on load; the panel shows "Bridge online" vs
"NOT PATCHED").

## Gotchas (do NOT relearn these)

### Trigger format (patcher)
- **DCS has no `triggerStart` predicate.** Use `triggerOnce` (one-shot; pair with
  a `c_time_after seconds=1` rule for "mission start") or `triggerFront`
  (rising-edge). An early build used `triggerStart` and DCS *silently* never
  fired anything.
- `triggerFront` flag actions **must clear the flag** afterward (`a_clear_flag`)
  or the next press isn't a rising edge and won't fire.
- Flag references in rules are **strings**: `["flag"] = "11"`, with `["value"] = 1`.
- An entry needs `["eventlist"] = ""` and `["colorItem"]`.
- Inline script action shape is just `{ ["text"] = ..., ["predicate"] = "a_do_script" }`
  — no `zone_list` / `meters` / `file`.
- Insert new entries at **column 0 of the actions-table close-brace line**, else
  the close brace's tab indent prefixes our entries and breaks strip-by-indent.
- Mission files use **LF**. The patcher does bytes I/O — `read_text` would
  CRLF-translate on Windows (and `read_text(newline=)` is Python 3.13+, but the
  bundled interpreter is 3.12).

### Hook / dxgui
- Hotkey is lowercase: `"Ctrl+Shift+c"`. Capital `C` doesn't fire.
- Register the hotkey via `window:addHotKeyCallback(...)`, **not** `DCS.bindHotKey`
  (which doesn't exist in this env).
- Build the window with `DialogLoader.spawnDialogFromFile`, not `dxgui.Window.new()`.
- Create the window in `onSimulationFrame` (lazy), not `onSimulationStart`.
- `addHotKeyCallback` only binds after `setVisible(true)` has been called once.
- **`setVisible(false)` destroys the dialog.** Hide via `setSize(0, 0)` while
  keeping `setVisible(true)`.
- Reference implementation that works: `DCS-SRS-OverlayGameGUI.lua`.

### Bridge
- Idempotency guard `_G.__CARRIER_GUI_BRIDGE_LOADED` (the load trigger can run more
  than once).
- Beacon params are cached by **unit name** (`unit:getName()`), not group name.
- Ship route tasks use `action = "Off Road"`; `"Turning Point"` is aircraft-only.
- DCS Lua is 5.1 — no `goto`/`continue`, no `_ENV`; use `setfenv`.

### Build / packaging
- The patcher needs a Python interpreter. The release bundles the official Python
  **embeddable** distribution in `Patcher/python/` so end users install nothing.
  It's gitignored; `Tools/build_release.py` fetches it at build time.

## Elevator control (experimental — v1.4 ELEVATOR tab)

ED *built* player-facing carrier elevator control and then disabled it. Evidence
in the stock install (`Mods/tech/Supercarrier/`):

- `AirBossScreensUI/Elevators.lua` — a 4-button AirBoss "Elevators control" screen
  wired to a native engine global **`setElevatorCommand(shipId, idx 0-3, cmd)`**
  (`cmd` 1 = down, 2 = up). Every `onChange` handler is **commented out**.
- The state read-back (`room.elv_state[]`) is still live, so the engine *tracks*
  elevator positions for the UI even with command disabled.
- `AirBossScreensUI/AirBoss.lua` never even instantiates the Elevators screen
  (`construct()` builds map / ship_state / ship_navigation / lights_control only).
  So it's disabled at two levels.
- It mirrors the `ship_navigation` (AirBoss speed/heading order) architecture,
  which DOES work and sync in MP — so the disable may not be a sync failure.

### What the in-game probe found (v1.4-beta, 2026-06-19)

The hook's diagnostics block probed every Lua state it can reach:

```
elevator fn probe: hook=nil  gui=nil  export=nil  server=nil
```

`setElevatorCommand` is **not** a global in the hook env, nor in the `gui`,
`export`, or `server` states (all returned `nil`, not `n/a` — the probes ran).
Two corroborating facts from the stock files:

- `setFoulDeck` / `setDesiredRope` / `adjustGate` (the functions the LSO patch
  calls) are **plain Lua functions defined in `PLATCameraUI.lua`** that just
  toggle GUI widgets — they are *not* engine globals and not proof of Lua→sim
  control.
- `setElevatorCommand` is **defined nowhere** in any shipped Lua file; it is only
  *referenced* (commented out) in `Elevators.lua` as `base.setElevatorCommand`.

So it can only be a C++ engine global injected into the **AirBoss screen Lua
state** — the private state where `Elevators.lua`/`AirBoss.lua` run, which the
GameGUI hook cannot reach via any shared state. `edSupercarrier.dll` ASCII-string
scan: `AirBoss`/`Supercarrier` present, but `setElevatorCommand` (and even
working siblings like `setFoulDeck`) absent — inconclusive (names likely live in
core DCS bins, not this DLL), so it does **not** prove the binding was cut.

### How the ELEVATOR tab drives it now (file bridge)

Because the hook can't call the function, the tab uses a file-IPC bridge — the
same pattern as the LSO foul/wire/zoom controls:

1. RAISE/LOWER write `Saved Games/DCS/carriergui_elev_cmd.txt` = `"idx,cmd"`.
2. `LSO/Enable-ElevatorTools.ps1` patches `AirBossScreensUI/AirBoss.lua`,
   injecting a probe + command poll into `update(shipId)` (runs **inside** the
   AirBoss state, with a valid `shipId`). It calls `setElevatorCommand(shipId,
   idx, cmd)` and writes `carriergui_elev_result.txt`.
3. The hook reads that result file each poll → `lblElevStatus` ("Bridge: ...").

The injected probe prints to dcs.log + the result file whether the engine fn is
`function` or `nil` **in the AirBoss state** — that is the definitive existence
test the hook probe can't give. `update()` only ticks when the AirBoss room is
active, so the in-game AirBoss/deck UI must be open. `setElevatorCommand` needs
the carrier object id; the hook gets it from `CG_QUERY` (`id=` → `carrier.shipId`)
but the *patch* uses the `shipId` C++ hands `update()` directly.

### RESOLVED (2026-06-20) — DEAD END

Ran `Enable-ElevatorTools`, loaded a CVN mission, drove the bridge. The patched
`AirBoss.update()` ticked and processed a command; `carriergui_elev_result.txt`:

```
setElevatorCommand=nil (binding absent) idx=3 cmd=1
```

`setElevatorCommand` is `nil` **inside the AirBoss screen state itself** — the
exact `_G` where `Elevators.lua` expects it. So ED removed the **engine binding**,
not just the UI. The commented-out `Elevators.lua` calls reference a function that
no longer exists in any reachable Lua state. **There is no Lua-mod path to command
the Supercarrier elevators in current DCS** — only a restored ED binding (or an
out-of-scope native DLL/memory hack) could do it. The "mods make it possible"
rumor does not hold for current builds.

Remaining long-shot (NOT pursued, ~low odds): the binding *might* be injected only
when the Elevators screen is actually instantiated (`Elevators.create()`, never
called by stock). But `Elevators.lua` accesses it as a plain state global, not a
per-screen param, so a cut binding is by far the likeliest explanation.

Cleanup: revert the now-pointless core-file patch with `LSO/Disable-ElevatorTools.ps1`.
The CarrierGUI ELEVATOR tab is kept as a documented negative result (the probe
line shows the dead end); the hook/dlg stay IC-neutral.

### Other solutions considered (all dead, 2026-06-20)

- **Set the model draw argument from script.** No setter on the mission `Unit`
  object — only `getDrawArgumentValue` (read). A real setter (`setArgument(obj,
  arg, val)`) exists ONLY in the DemoScenes/encyclopedia render API
  (`Scripts/DemoScenes/*`), which operates on non-networked menu models, not
  mission units. There is a standing ED **wishlist** asking for a script function
  to animate units — i.e. it officially does not exist.
- **Indirect AI deck logic** (spawn/despawn AI to make the deck manager cycle an
  elevator): unreliable, can't pick elevator/timing, modern SC elevators barely
  move even for AI. Not a control method.
- **Static-object fake**: statics don't animate or move vertically and can't carry
  aircraft. (Community "deck template" tools only spawn/remove static dressing.)
- **3D/EDM model mod**: huge effort, fails IC, and still can't *drive* animation
  without an engine binding — only a permanently up/down static variant.
- **Olympus / LotATC / MOOSE Airboss**: all use the same sanctioned API; none
  expose elevator control.
- **Native DLL/memory hack**: the only thing that could touch the C++ elevator
  state, but a client hack can't sync (server is authoritative), a server hack is
  a ToS/anti-cheat/maintenance nightmare, and it breaks every patch. Out of scope.

Only real paths to *direct command*: ED restoring the binding (worth a wishlist
+1 — the disabled UI is in their files), or a native hack (not viable).

### ⚠ CORRECTION (2nd pass) — elevators DO move in MP, via the AI deck cycle

The "dead end" above applies only to **direct command**. A second pass found the
elevators are alive and server-driven in stock DCS:

- **The animation args are documented in the ship DB** (`CoreMods/tech/USS_Nimitz/
  Database/USS_CVN_7X.lua`, identical on 71/72/73/74/75 *and* Heatblur's Forrestal —
  an engine-wide convention):
  ```lua
  GT.animation_arguments.elevators        = {57, 58, 59, 60}
  GT.animation_arguments.elevators_doors  = {47, 48, 53, 54}
  GT.animation_arguments.elevators_fences_top    = {27, 29, 31, 33}
  GT.animation_arguments.elevators_fences_bottom = {28, 30, 32, 34}
  ```
- **`GT.Elevators` is a live, data-driven elevator system** in
  `USS_Nimitz_RunwaysAndRoutes.lua` (~line 466) — *active, not commented out*:
  ```lua
  -- ElevatorTypes : SPAWN = 0, DESPAWN = 1, BOTH = 2
  { ElevatorIdx = 1, ElevatorType = 1, TerminalIdx = 1, Points = {...} }
  ```
  Nimitz-class: **elevators 1/2/3 = DESPAWN**, **elevator 4 = SPAWN**, each with a
  taxi route down to the hangar deck (`y = 8.45`, matching `hangar_deck` in
  `GroundCrew.lua`; flight deck is `y = 20.1494`). Flight-deck parking spots are
  named for their lift (`lift1_1`, `lift2_2`, …) with despawn timers
  (`3.0*60.0` = 3 min).
- **ED's own FAQ**: *"The elevators work automatically for the AI to move aircraft
  off the deck to prevent over-crowding. Later with the inclusion of the Air Boss
  station, players will also be allowed to manually raise and lower them."* — the
  manual half was never delivered, matching the commented-out `Elevators.lua`.

**Why this matters for MP:** the AI deck cycle runs on the **server**, so the
elevator motion it produces is authoritative and replicates to every client. The
lever was never a command function — it is **AI deck traffic**. Inducing that
(spawning AI onto the boat → elevator 4 up; letting AI despawn at a lift spot →
elevator 1/2/3 down) uses only sanctioned mission scripting: **IC-safe, no core
file edits, MP-native.**

**Instrument shipped (v1.4):** `CG_QUERY` now reads args 57-60 / 47,48,53,54 via
`getDrawArgumentValue` **in the mission (server) state** — authoritative values —
into `carrier.elevArgs` / `carrier.elevDoors`, and `readShipState` logs
`ELEVATOR n MOVED a -> b` to dcs.log on any change. Pure read, no UI yet. Use it
to confirm whether/when elevators cycle, then build the induced-movement trigger.
