#!/usr/bin/env python3
"""
CarrierGUI OLYMPUS agent  (the "connect like OPT" path).

Connects straight to a running DCS Olympus backend with host + password (the same
way DCS:OPT Live does), pulls the FULL unit picture (no MP culling), computes the
carrier-recovery data, and writes the carriergui_*.txt files the panel reads.

No CarrierGUI server install, no mission patch, no relay, no desanitize — Olympus
is the server-side piece you already run.  Read-only situational picture; carrier
commands (CASE/broadcast/beacons) still go through the F10 menu / mission bridge.

Olympus client (auth + binary units decoder) is reused verbatim from OPT's
backend/services/olympus_bridge.py (proven against live Olympus).

Config: carriergui_olympus.json next to this file (see olympus.example.json).
"""
import base64, hashlib, json, math, os, struct, time
import urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.environ.get('CARRIERGUI_OLYMPUS_CFG') or os.path.join(HERE, 'carriergui_olympus.json')

NM = 1852.0
ROLE = 'Game master'
CV_PAT = ('CVN', 'Stennis', 'VINSON', 'Forrestal', 'Roosevelt', 'Lincoln',
          'Washington', 'Truman', 'Eisenhower', 'LHA', 'Tarawa', 'Wasp', 'America')
SUP_PAT = ('KC130', 'KC-130', 'KC135', 'KC-135', 'S-3B', 'S_3B', 'E-2', 'E_2', 'E-3', 'A-50')
CSMAP = {'CVN_71': 'Roughrider', 'CVN_72': 'Champion', 'CVN_73': 'Battle Cat',
         'CVN_75': 'Truman', 'Stennis': 'Champion', 'VINSON': 'Gold Eagle'}

# ── Olympus binary units decoder (from OPT olympus_bridge.py) ────────────────
_UNIT_FIELDS = {
    1: ("category", "str"), 2: ("alive", "bool"), 3: ("alarmState", "u8"),
    4: ("radarState", "bool"), 5: ("human", "bool"), 6: ("controlled", "bool"),
    7: ("coalition", "u8"), 8: ("country", "u8"), 9: ("name", "str"),
    10: ("unitName", "str"), 11: ("callsign", "str"), 12: ("unitID", "u32"),
    13: ("groupID", "u32"), 14: ("groupName", "str"), 15: ("state", "u8"),
    16: ("task", "str"), 17: ("hasTask", "bool"), 18: ("position", "latlng"),
    19: ("speed", "f64"), 20: ("horizontalVelocity", "f64"), 21: ("verticalVelocity", "f64"),
    22: ("heading", "f64"), 23: ("track", "f64"), 24: ("isActiveTanker", "bool"),
    25: ("isActiveAWACS", "bool"), 26: ("onOff", "bool"), 27: ("followRoads", "bool"),
    28: ("fuel", "u16"), 29: ("desiredSpeed", "f64"), 30: ("desiredSpeedType", "bool"),
    31: ("desiredAltitude", "f64"), 32: ("desiredAltitudeType", "bool"), 33: ("leaderID", "u32"),
    34: ("formationOffset", "offset"), 35: ("targetID", "u32"), 36: ("targetPosition", "latlng"),
    37: ("ROE", "u8"), 38: ("reactionToThreat", "u8"), 39: ("emissionsCountermeasures", "u8"),
    40: ("TACAN", "tacan"), 41: ("radio", "radio"), 42: ("generalSettings", "gensettings"),
    43: ("ammo", "ammo"), 44: ("contacts", "contacts"), 45: ("activePath", "activepath"),
    46: ("isLeader", "bool"), 47: ("operateAs", "u8"), 48: ("shotsScatter", "u8"),
    49: ("shotsIntensity", "u8"), 50: ("health", "u8"), 51: ("racetrackLength", "f64"),
    52: ("racetrackAnchor", "latlng"), 53: ("racetrackBearing", "f64"), 54: ("timeToNextTasking", "f64"),
    55: ("barrelHeight", "f64"), 56: ("muzzleVelocity", "f64"), 57: ("aimTime", "f64"),
    58: ("shotsToFire", "u32"), 59: ("shotsBaseInterval", "f64"), 60: ("shotsBaseScatter", "f64"),
    61: ("engagementRange", "f64"), 62: ("targetingRange", "f64"), 63: ("aimMethodRange", "f64"),
    64: ("acquisitionRange", "f64"), 65: ("airborne", "bool"),
}
_END = 0xFF


def _read_field(data, o, t):
    if t in ("bool", "u8"):
        return data[o], o + 1
    if t == "u16":
        return struct.unpack_from("<H", data, o)[0], o + 2
    if t == "u32":
        return struct.unpack_from("<I", data, o)[0], o + 4
    if t == "f64":
        return struct.unpack_from("<d", data, o)[0], o + 8
    if t == "str":
        ln = struct.unpack_from("<H", data, o)[0]
        return data[o + 2:o + 2 + ln].split(b"\x00")[0].decode("latin1"), o + 2 + ln
    if t == "latlng":
        lat, lng, alt = struct.unpack_from("<ddd", data, o)
        return {"lat": lat, "lng": lng, "alt": alt}, o + 24
    if t == "offset":
        return None, o + 24
    if t == "tacan":
        return None, o + 7
    if t == "radio":
        return None, o + 6
    if t == "gensettings":
        return None, o + 5
    if t == "ammo":
        size = struct.unpack_from("<H", data, o)[0]
        return None, o + 2 + size * 38
    if t == "contacts":
        size = struct.unpack_from("<H", data, o)[0]
        return None, o + 2 + size * 5
    if t == "activepath":
        size = struct.unpack_from("<H", data, o)[0]
        return None, o + 2 + size * 24
    raise ValueError(t)


def _next_unit_boundary(data, o):
    i, n = o, len(data)
    while i < n - 9:
        if (data[i] == _END and data[i + 5] == 0x01 and data[i + 7] == 0x00
                and 0 < data[i + 6] < 64 and 32 <= data[i + 8] < 127):
            return i + 1
        i += 1
    return n


def decode_units(raw, limit=5000):
    units = []
    n = len(raw)
    if n < 12:
        return units
    o = 8
    while o < n - 4 and len(units) < limit:
        try:
            oly_id = struct.unpack_from("<I", raw, o)[0]
            o += 4
            u = {"olympusID": oly_id}
            while o < n:
                idx = raw[o]; o += 1
                if idx == _END:
                    break
                spec = _UNIT_FIELDS.get(idx)
                if spec is None:
                    o = _next_unit_boundary(raw, o - 1); break
                key, typ = spec
                val, o = _read_field(raw, o, typ)
                if val is not None:
                    u[key] = val
            units.append(u)
        except Exception:
            o = _next_unit_boundary(raw, o)
    return units


def _basic_auth(password):
    sent = hashlib.sha256((password or "").encode("utf-8")).hexdigest() if password else ""
    raw = f"{ROLE}:{sent}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def fetch_units(host, port, password):
    url = f"http://{host}:{int(port)}/olympus/units?time=0"
    req = urllib.request.Request(url, headers={"Authorization": _basic_auth(password)}, method="GET")
    with urllib.request.urlopen(req, timeout=8) as r:
        return decode_units(r.read())


# ── recovery computation (port of CG_QUERY / bridge to Olympus units) ────────
def norm(a):
    a %= 360
    return a + 360 if a < 0 else a


def ang_delta(a, b):
    d = (a - b) % 360
    return d - 360 if d > 180 else d


def matchany(s, pats):
    return any(p in (s or '') for p in pats)


def rel_ne(lat, lon, clat, clon):
    north = (lat - clat) * 111320.0
    east = (lon - clon) * 111320.0 * math.cos(math.radians(clat))
    return north, east


def heading_deg(h):
    # Olympus heading is radians (DCS native). If a server reports degrees this
    # would need /1; values are clamped/normalised so a wrong unit shows as
    # rotated headings only (positions are unaffected) -- easy to spot + flip.
    return norm(math.degrees(h or 0.0))


def compute(units):
    cv = None
    for u in units:
        cat = (u.get('category') or '').lower()
        if u.get('position') and (cat in ('navyunit', 'navy', 'ship') or matchany(u.get('name', ''), CV_PAT)):
            if matchany(u.get('name', ''), CV_PAT):
                cv = u; break
    if not cv:
        return None
    p = cv['position']
    clat, clon, calt = p['lat'], p['lng'], p.get('alt', 0)
    brc = heading_deg(cv.get('heading'))
    fb = norm(brc - 9)
    bR, fR = math.radians(brc), math.radians(fb)
    bc, bs = math.cos(bR), math.sin(bR)
    fc, fs = math.cos(fR), math.sin(fR)
    cco = cv.get('coalition')

    ccz, stack, pattern, deck = [], [], [], []
    for u in units:
        if u is cv or not u.get('position'):
            continue
        cat = (u.get('category') or '').lower()
        if cat not in ('aircraft', 'helicopter'):
            continue
        if cco is not None and u.get('coalition') != cco:
            continue
        if not u.get('alive', True):
            continue
        q = u['position']
        north, east = rel_ne(q['lat'], q['lng'], clat, clon)
        nm = math.hypot(north, east) / NM
        if nm > 60:
            continue
        altM = q.get('alt', 0)
        altFt = int(altM * 3.28084)
        airborne = u.get('airborne', altM > calt + 30)
        modex = u.get('callsign') or u.get('unitName') or u.get('name') or '?'
        role = 'TKR' if (matchany(u.get('name', ''), SUP_PAT) or u.get('isActiveTanker') or u.get('isActiveAWACS')) else 'FTR'
        # prefer track (course over ground) for aircraft, like OPT LiveMap
        achdg = heading_deg(u.get('track') if u.get('track') is not None else u.get('heading'))
        brg = norm(math.degrees(math.atan2(east, north)))
        gs = int((u.get('speed') or 0) * 1.94384)
        acAhead = north * bc + east * bs
        acStbd = north * (-bs) + east * bc

        if not airborne and gs < 50 and abs(acAhead) < 185 and -65 < acStbd < 55:
            deck.append(f"{modex}|{int(round(acAhead))}|{int(round(acStbd))}")
            continue
        if not airborne:
            continue

        point = 'enroute'
        if nm <= 4:
            dBRC = abs(ang_delta(achdg, brc))
            dREC = abs(ang_delta(achdg, norm(brc + 180)))
            if nm < 0.45:
                point = 'TRAP'
            elif acAhead < 300 and abs(acStbd) < 650 and altM < 150 and dBRC < 60:
                point = 'GROOVE'
            elif acStbd < -650 and dREC < 55:
                point = 'DOWNWIND' if acAhead > 350 else ('ABEAM' if acAhead > -550 else '180')
            elif acStbd < -300 and acAhead < -250 and altM < 175:
                point = '180'
            elif acStbd > -550 and dBRC < 45 and altM > 165:
                point = 'INITIAL'
            elif altM > 150 and 45 <= dBRC <= 130 and acAhead > -300:
                point = 'BREAK'
            else:
                point = 'pattern'
        jy = (north * fc + east * fs) / NM
        jx = (-north * fs + east * fc) / NM
        if role != 'TKR' and nm < 25:
            stack.append(f"{modex}|{altFt}|{gs}|0|{point}|HOLD|{jx:.2f}|{jy:.2f}")
        if 8 < nm < 60:
            ccz.append(f"{modex}|{int(round(brg))}|{nm:.1f}|{altFt}|{gs}|{role}|{int(round(achdg))}")
        if nm < 12 and role != 'TKR':
            pattern.append(f"{modex}|{altFt}|{gs}|{point}|{int(round(acAhead))}|{int(round(acStbd))}")

    cs = CSMAP.get(cv.get('name', ''), cv.get('name') or 'Mother')
    ship = f"hdg={int(round(brc))}\nfb={int(round(fb))}\ncallsign={cs}\ntod={int(time.time())}\n"
    return {'shipstate': ship, 'stack': '\n'.join(stack), 'ccz': '\n'.join(ccz),
            'pattern': '\n'.join(pattern), 'deck': '\n'.join(deck)}


def write_atomic(path, text):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', errors='ignore') as f:
        f.write(text or '')
    os.replace(tmp, path)


def main():
    with open(CFG, 'r', encoding='utf-8') as f:
        c = json.load(f)
    for k in ('olympus_host', 'olympus_password', 'dcs_writedir'):
        if not c.get(k):
            raise SystemExit(f'config missing "{k}" (see olympus.example.json)')
    host = c['olympus_host']; port = c.get('olympus_port', 4512); pw = c['olympus_password']
    wd = c['dcs_writedir']; poll = c.get('poll_secs', 1.0)
    files = {'shipstate': 'carriergui_shipstate.txt', 'stack': 'carriergui_stack.txt',
             'ccz': 'carriergui_ccz.txt', 'pattern': 'carriergui_pattern.txt', 'deck': 'carriergui_deck.txt'}
    print(f'CarrierGUI Olympus agent -> {host}:{port}')
    tick = 0
    while True:
        tick += 1
        try:
            units = fetch_units(host, port, pw)
            snap = compute(units)
            if snap:
                for key, fn in files.items():
                    write_atomic(os.path.join(wd, fn), snap[key])
                write_atomic(os.path.join(wd, 'carriergui_relay_active.txt'), str(tick))
            else:
                print('no carrier in Olympus units yet')
        except urllib.error.HTTPError as e:
            print('auth/HTTP error:', e.code, '- check password/role' if e.code in (401, 403) else '')
        except Exception as e:
            print('poll failed:', e)
        time.sleep(poll)


if __name__ == '__main__':
    main()
