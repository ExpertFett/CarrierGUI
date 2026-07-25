#!/usr/bin/env python3
"""
CarrierGUI SERVER agent  (runs on the DCS dedicated-server machine).

Bridges the running mission to the Railway relay, both directions:
  - reads the 5 recovery files the bridge writes (needs MissionScripting.lua
    desanitized so the bridge can write them) and POSTs them as one snapshot,
  - pulls queued controller commands and writes them to carriergui_cmd.txt,
    which the bridge poll() drains into user flags.

Zero dependencies (stdlib urllib).  Run windowless with pythonw.exe.
Config: carriergui_agent.json next to this file (see config.example.json).
"""
import json, os, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get('CARRIERGUI_AGENT_CFG') or os.path.join(HERE, 'carriergui_agent.json')

FILES = {  # snapshot key -> filename in the DCS writedir
    'ship':    'carriergui_shipstate.txt',
    'stack':   'carriergui_stack.txt',
    'ccz':     'carriergui_ccz.txt',
    'pattern': 'carriergui_pattern.txt',
    'deck':    'carriergui_deck.txt',
}
CMD_FILE = 'carriergui_cmd.txt'   # written here, drained by the bridge


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


def read_files(writedir):
    snap = {}
    for key, fn in FILES.items():
        p = os.path.join(writedir, fn)
        try:
            with open(p, 'r', encoding='utf-8', errors='ignore') as f:
                snap[key] = f.read()
        except OSError:
            snap[key] = ''
    return snap


def main():
    c = load_cfg()
    base = '%s/recovery/%s' % (c['relay_url'], c['server_id'])
    cmdurl = '%s/cmd/%s' % (c['relay_url'], c['server_id'])
    cmdpath = os.path.join(c['dcs_writedir'], CMD_FILE)
    print('CarrierGUI server agent -> %s (server_id=%s)' % (c['relay_url'], c['server_id']))
    while True:
        try:
            http('POST', base, c['relay_token'], read_files(c['dcs_writedir']))
        except Exception as e:
            print('push failed:', e)
        try:
            res = http('GET', cmdurl, c['relay_token'])
            flags = [str(x.get('flag')) for x in res.get('cmds', []) if x.get('flag') is not None]
            if flags:
                # append (bridge clears after draining); newline-separated flags
                with open(cmdpath, 'a', encoding='utf-8') as f:
                    f.write('\n'.join(flags) + '\n')
                print('queued %d command(s) -> %s' % (len(flags), CMD_FILE))
        except Exception as e:
            print('cmd pull failed:', e)
        time.sleep(c['poll_secs'])


if __name__ == '__main__':
    main()
