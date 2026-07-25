# CarrierGUI multiplayer relay — design & build plan

Goal: a controller manages carrier recovery on **any** multiplayer server (real
dedicated servers, large player counts), seeing the live radar/marshal/tower/LSO
picture and issuing commands — from a machine that is **not** the server.

## Why a relay is required (the hard constraint)

DCS runs mission scripting **only on the server**. A remote client's
`net.dostring_in("server", …)` returns nothing, and a headless server can't draw
the panel. So the live picture has to be **exported off the server** and carried
to the controller by something outside DCS. This is unavoidable for any
remote/at-scale setup — local/listen hosting is the only no-relay option and it
doesn't scale.

## Reuse what already works

The DCS-server → Railway pipeline from the Ops Bot already solves transport:
a hook writes a **file-queue**, a windowless **WinHTTP daemon** POSTs it to
Railway (avoids the `os.execute` console-flash). CarrierGUI's bridge already
**computes** all the recovery data (`enumerateAndWrite` → stack/ccz/pattern/deck
+ `writeShipState`). We bolt those two together.

## Architecture (data out, commands back)

```
[DCS dedicated server]                 [Railway]                 [Controller]
 bridge (injected)                                                
   enumerateAndWrite ─┐                                           
   writeShipState     ├─> snapshot file ─> WinHTTP daemon ─POST─> /recovery/<serverId>
                      │                                              │  (latest snapshot,
   poll() reads ◄─────┘ <─ command queue <─ daemon GET <─ /cmd/<serverId>   per server)
                                                                     │
                                                          (A) in-DCS companion: GET snapshot
                                                              -> write local carriergui_*.txt
                                                              -> panel slurp() renders it (works today)
                                                              -> panel buttons -> local cmd file
                                                              -> companion POST /cmd
                                                          (B) web dashboard: render snapshot in
                                                              browser; buttons POST /cmd
```

## Data contract (`recovery.v1`)

One JSON snapshot per poll, per server:
```
{ serverId, t, ship:{hdg,fb,wind_from,wind_kts,altimeter,case,wx...},
  stack:[...], ccz:[...], pattern:[...], deck:[...] }
```
(The bridge currently emits pipe-delimited sections; wrap them into this JSON in
the daemon or the export step. Both consumers parse the same contract.)

Commands back (`cmd.v1`): `{ serverId, flag, ts }` — the same user-flag numbers
the F10 menu / panel already use (CASE, broadcast, wind, beacons, lights, LSO).

## Required server change

`MissionScripting.lua` must be **desanitized** (io/lfs) so the bridge can write
the snapshot file. The server already wants this for MSRS. One-time edit on the
server install (server stopped).

## Build phases

1. **Server export** — desanitize; confirm the bridge writes the snapshot;
   add the WinHTTP daemon (port of the Ops Bot daemon) that POSTs it to Railway.
2. **Railway relay** — tiny endpoint: `POST /recovery/<id>` stores latest;
   `GET /recovery/<id>` returns it; `POST /cmd/<id>` queues; `GET /cmd/<id>`
   drains. (Sits next to the existing Railway services.)
3. **Consumer** — the chosen front end:
   - **(A) in-DCS companion**: small Python/exe that GETs the snapshot → writes
     `carriergui_*.txt` locally (panel renders it, slurp fallback already exists);
     watches a local cmd file → POSTs /cmd. Panel buttons need a "relay mode"
     that writes the cmd file instead of `net.dostring_in`.
   - **(B) web dashboard**: render the radar/marshal/tower/LSO from the snapshot;
     buttons POST /cmd. Zero install, scales, leans on the existing web stack.
4. **Command path** — bridge `poll()` already reads user flags; add a step that
   drains the relayed cmd queue (daemon GET → writes flags) so controller actions
   take effect.

## Recommendation

Default: **(A) in-DCS panel + companion** — keeps the VR panel that is "the gui
stuff," reuses the most existing code, and scales fine (controllers are few; the
big player count lives on the server and doesn't touch the panel).
Pick **(B) web dashboard** instead if you want zero per-controller install and
to manage from a tablet/2nd screen — more scalable, but a new UI.

Phases 1–2 + the data contract are **identical for both**, so that's the safe
place to start regardless of the A/B choice.
