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
