#!/usr/bin/env python3
"""CarrierGUI controller setup — one-time config wizard.
Asks for the squad's relay URL / token / server-id, auto-detects your DCS
Saved Games folder, and writes carriergui_agent.json next to this file."""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.path.join(HERE, 'carriergui_agent.json')


def ask(prompt, default=''):
    s = input(prompt + (' [%s]' % default if default else '') + ': ').strip()
    return s or default


def main():
    print('=== CarrierGUI controller setup ===')
    print('Get the relay URL, token and server-id from your squad admin.\n')
    url = ask('Relay URL (e.g. https://yourrelay.up.railway.app)').rstrip('/')
    tok = ask('Relay token')
    sid = ask('Server ID (must match the server exactly)')

    guess = os.path.join(os.environ.get('USERPROFILE', ''), 'Saved Games', 'DCS')
    wd = ask('DCS Saved Games folder', guess)
    if not wd.endswith(('\\', '/')):
        wd += os.sep

    if not (url and tok and sid):
        print('\nURL, token and server-id are all required. Re-run Setup.bat.')
        input('Press Enter to close.')
        return

    cfg = {'relay_url': url, 'relay_token': tok, 'server_id': sid,
           'dcs_writedir': wd, 'poll_secs': 1.0}
    with open(CFG, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)
    print('\nSaved carriergui_agent.json:')
    print(json.dumps(cfg, indent=2))
    if not os.path.isdir(wd):
        print('\nWARNING: that DCS folder does not exist yet — double-check the path.')
    print('\nDone. Next: double-click Start-Controller-Agent.vbs, launch DCS,')
    print('join the squad server, and press Ctrl+Shift+c.')
    input('\nPress Enter to close.')


if __name__ == '__main__':
    main()
