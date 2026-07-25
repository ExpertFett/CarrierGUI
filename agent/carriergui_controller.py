#!/usr/bin/env python3
"""
CarrierGUI CONTROLLER agent  (runs on the controller's PC, alongside DCS).

Bridges the Railway relay to the in-DCS panel, both directions:
  - pulls the latest recovery snapshot and writes the 5 files the panel's
    slurp() reads (so the Ctrl+Shift+c panel renders live data while connected
    to a remote server),
  - reads carriergui_panel_cmd.txt (the panel writes a flag number per line in
    relay mode) and POSTs each command to the relay.

Zero dependencies (stdlib urllib).  Run windowless with pythonw.exe.
Config: carriergui_agent.json next to this file (see config.example.json).
"""
import json, os, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get('CARRIERGUI_AGENT_CFG') or os.path.join(HERE, 'carriergui_agent.json')

FILES = {
    'ship':    'carriergui_shipstate.txt',
    'stack':   'carriergui_stack.txt',
    'ccz':     'carriergui_ccz.txt',
    'pattern': 'carriergui_pattern.txt',
    'deck':    'carriergui_deck.txt',
}
PANEL_CMD_FILE = 'carriergui_panel_cmd.txt'   # panel writes, we drain
HEARTBEAT_FILE = 'carriergui_relay_active.txt'  # we rewrite each loop; the panel
                                                # auto-enables relay mode while it
                                                # keeps changing (no hook edit needed)


def load_cfg():
    with open(CFG, 'r', encoding='utf-8') as f:
        c = json.load(f)
    c.setdefault('poll_secs', 1.0)
    for k in ('relay_url', 'relay_token', 'server_id', 'dcs_writedir'):
        if not c.get(k):
            raise SystemExit('config missing "%s" (see config.example.json)' % k)
    c['relay_url'] = c['relay_url'].rstrip('/')
    return c


def http(method, url, token, body=None):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + token)
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode('utf-8') or '{}')


def write_atomic(path, text):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', errors='ignore') as f:
        f.write(text or '')
    os.replace(tmp, path)   # atomic so the panel never reads a half-written file


def main():
    c = load_cfg()
    base = '%s/recovery/%s' % (c['relay_url'], c['server_id'])
    cmdurl = '%s/cmd/%s' % (c['relay_url'], c['server_id'])
    panelcmd = os.path.join(c['dcs_writedir'], PANEL_CMD_FILE)
    hbpath = os.path.join(c['dcs_writedir'], HEARTBEAT_FILE)
    print('CarrierGUI controller agent <- %s (server_id=%s)' % (c['relay_url'], c['server_id']))
    last_stale = None
    tick = 0
    while True:
        tick += 1
        # heartbeat: changing value tells the panel a controller agent is live,
        # so it auto-switches to relay mode (reads relayed files + routes cmds).
        try:
            write_atomic(hbpath, str(tick))
        except Exception:
            pass
        try:
            res = http('GET', base, c['relay_token'])
            snap = res.get('data') or {}
            for key, fn in FILES.items():
                write_atomic(os.path.join(c['dcs_writedir'], fn), snap.get(key, ''))
            if res.get('stale') != last_stale:
                last_stale = res.get('stale')
                print('snapshot %s (age %sms)' % ('STALE' if last_stale else 'live', res.get('ageMs')))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                pass   # server hasn't pushed yet
            else:
                print('pull failed:', e)
        except Exception as e:
            print('pull failed:', e)
        # send any panel button presses back
        try:
            if os.path.exists(panelcmd):
                with open(panelcmd, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = [ln.strip() for ln in f if ln.strip()]
                open(panelcmd, 'w').close()   # clear
                for ln in lines:
                    try:
                        http('POST', cmdurl, c['relay_token'], {'flag': int(ln)})
                        print('sent cmd flag', ln)
                    except Exception as e:
                        print('cmd send failed:', e)
        except Exception as e:
            print('panel cmd read failed:', e)
        time.sleep(c['poll_secs'])


if __name__ == '__main__':
    main()
