# CarrierGUI relay

Tiny zero-dependency Node relay that lets a controller manage carrier recovery on
**any** DCS server. The DCS server POSTs its live recovery snapshot here; the
controller (in-DCS companion or web dashboard) GETs it. Commands flow back the
same way. In-memory only — it's live data.

See `../docs/MULTIPLAYER-RELAY.md` for the full architecture.

## Deploy (Railway, next to your other services)

1. New service from this `relay/` folder.
2. Set env var **`RELAY_TOKEN`** to a long random string (shared with the server
   daemon + the controller).
3. Railway provides `PORT` automatically. Start command: `npm start`.

## Endpoints (all require `Authorization: Bearer <RELAY_TOKEN>`)

| Method | Path | Who | Purpose |
|--------|------|-----|---------|
| POST | `/recovery/:id` | server | push latest snapshot (body = JSON) |
| GET  | `/recovery/:id` | consumer | latest snapshot (`{data,t,ageMs,stale}`) |
| POST | `/cmd/:id` | consumer | queue a command (`{flag}`) |
| GET  | `/cmd/:id` | server | drain queued commands |
| GET  | `/health` | — | liveness (no auth) |

`:id` = your `serverId` (any `[A-Za-z0-9_.-]`, ≤64). One relay handles many
servers. Snapshots older than 15 s are returned with `stale:true`.

## Local test

```
RELAY_TOKEN=test node server.js
curl -H "Authorization: Bearer test" -X POST localhost:8090/recovery/cv73 -d '{"ship":{"case":"III"}}'
curl -H "Authorization: Bearer test" localhost:8090/recovery/cv73
```
