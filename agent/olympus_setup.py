#!/usr/bin/env python3
"""CarrierGUI Olympus setup - one-time config wizard.
Writes carriergui_olympus.json next to this file."""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.path.join(HERE, 'carriergui_olympus.json')


def ask(prompt, default=''):
    s = input(prompt + (' [%s]' % default if default != '' else '') + ': ').strip()
    return s or default


def main():
    print('=== CarrierGUI Olympus setup ===')
    print('Connects to your DCS Olympus backend (the same one DCS:OPT Live uses).\n')
    host = ask('Olympus host / IP')
    port = ask('Olympus port (often 4512, or 3000 for the web UI)', '4512')
    pw = ask('Olympus "Game master" role password')
    guess = os.path.join(os.environ.get('USERPROFILE', ''), 'Saved Games', 'DCS')
    wd = ask('DCS Saved Games folder', guess)
    if not wd.endswith(('\\', '/')):
        wd += os.sep
    if not (host and pw):
        print('\nHost and password are required. Re-run Setup-Olympus.bat.')
        input('Press Enter to close.'); return
    cfg = {'olympus_host': host, 'olympus_port': int(port) if port.isdigit() else 4512,
           'olympus_password': pw, 'dcs_writedir': wd, 'poll_secs': 1.0}
    with open(CFG, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)
    safe = dict(cfg); safe['olympus_password'] = '***'
    print('\nSaved carriergui_olympus.json:')
    print(json.dumps(safe, indent=2))
    print('\nNext: double-click Start-Olympus-Agent.vbs, launch DCS, join the server,')
    print('press Ctrl+Shift+c.')
    input('\nPress Enter to close.')


if __name__ == '__main__':
    main()
