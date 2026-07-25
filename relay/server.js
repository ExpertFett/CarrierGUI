// CarrierGUI relay  (recovery.v1 / cmd.v1)
// Tiny zero-dependency relay so a controller can manage carrier recovery on any
// DCS server: the server POSTs its live recovery snapshot here, the controller
// (in-DCS companion OR web dashboard) GETs it; commands flow back the same way.
// Deploy next to the other Railway services.  In-memory only — it's live data,
// nothing to persist.
//
//   POST /recovery/:id   body = snapshot JSON      (server -> relay)
//   GET  /recovery/:id                              (consumer -> relay)
//   POST /cmd/:id        body = { flag }            (consumer -> relay)
//   GET  /cmd/:id        drains queued commands     (server -> relay)
//   GET  /health
//
// Auth: every request needs  Authorization: Bearer <RELAY_TOKEN>  (env var).
// Stale snapshots (> SNAPSHOT_TTL_MS) are reported but still served with `stale:true`.

const http = require('http');

const PORT = process.env.PORT || 8090;
const TOKEN = process.env.RELAY_TOKEN || '';            // set on Railway
const SNAPSHOT_TTL_MS = 15000;                          // mark stale after 15 s
const MAX_BODY = 256 * 1024;                            // 256 KB cap

const snapshots = Object.create(null);  // id -> { data, t }
const cmds = Object.create(null);       // id -> [ {flag, ts}, ... ]

function now() { return Date.now(); }

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function authed(req) {
  if (!TOKEN) return true;                               // no token configured = open (dev only)
  const h = req.headers['authorization'] || '';
  return h === 'Bearer ' + TOKEN;
}

function readBody(req, cb) {
  let buf = '', tooBig = false;
  req.on('data', (c) => {
    if (tooBig) return;
    buf += c;
    if (buf.length > MAX_BODY) { tooBig = true; }
  });
  req.on('end', () => {
    if (tooBig) return cb(new Error('body too large'));
    if (!buf) return cb(null, {});
    try { cb(null, JSON.parse(buf)); } catch (e) { cb(e); }
  });
  req.on('error', cb);
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const parts = u.pathname.split('/').filter(Boolean);  // ['recovery','<id>']

  if (req.method === 'GET' && u.pathname === '/health') {
    return send(res, 200, { ok: true, servers: Object.keys(snapshots).length });
  }
  if (!authed(req)) return send(res, 401, { error: 'unauthorized' });

  const kind = parts[0];
  const id = parts[1];
  if ((kind !== 'recovery' && kind !== 'cmd') || !id) {
    return send(res, 404, { error: 'not found' });
  }
  // basic id hygiene
  if (!/^[A-Za-z0-9_.-]{1,64}$/.test(id)) return send(res, 400, { error: 'bad id' });

  if (kind === 'recovery' && req.method === 'POST') {
    return readBody(req, (err, data) => {
      if (err) return send(res, 400, { error: 'bad body: ' + err.message });
      snapshots[id] = { data, t: now() };
      send(res, 200, { ok: true });
    });
  }
  if (kind === 'recovery' && req.method === 'GET') {
    const s = snapshots[id];
    if (!s) return send(res, 404, { error: 'no snapshot' });
    return send(res, 200, { data: s.data, t: s.t, ageMs: now() - s.t, stale: (now() - s.t) > SNAPSHOT_TTL_MS });
  }
  if (kind === 'cmd' && req.method === 'POST') {
    return readBody(req, (err, body) => {
      if (err) return send(res, 400, { error: 'bad body: ' + err.message });
      if (body.flag === undefined) return send(res, 400, { error: 'missing flag' });
      (cmds[id] = cmds[id] || []).push({ flag: body.flag, ts: now() });
      if (cmds[id].length > 200) cmds[id].splice(0, cmds[id].length - 200);  // safety cap
      send(res, 200, { ok: true });
    });
  }
  if (kind === 'cmd' && req.method === 'GET') {
    const q = cmds[id] || [];
    cmds[id] = [];                                        // drain
    return send(res, 200, { cmds: q });
  }
  return send(res, 405, { error: 'method not allowed' });
});

server.listen(PORT, () => console.log('CarrierGUI relay on :' + PORT + (TOKEN ? ' (token set)' : ' (NO TOKEN - dev only)')));
