-- carrier-gui-olympus-client.lua  (v1.3-beta50)
-- ============================================================================
-- In-hook DCS Olympus client — CarrierGUI's PRIMARY data path ("log in with
-- Olympus").  Pure Lua 5.1, self-contained: connects to an Olympus backend with
-- host + Game-master password (exactly like DCS:OPT Live), pulls the binary
-- units feed, decodes it, computes the carrier-recovery picture, and hands the
-- hook the same five section strings the readers already consume.
--
-- No Python agent, no relay, no mission patch, no desanitize.  Olympus is the
-- server-side piece the squad already runs.
--
-- DEPLOY: Saved Games\DCS\Scripts\Hooks\carrier-gui-olympus-client.lua
-- (same folder as the hook — one-folder install).  DCS auto-runs every .lua in
-- Scripts\Hooks, which is harmless here: standalone it only defines a table and
-- returns.  The hook dofile()s this same file to get the CGOLY API.
--
-- Protocol (proven by DCS:OPT's backend/services/olympus_bridge.py):
--   GET http://<host>:<port>/olympus/units?time=0
--   Authorization: Basic base64("Game master:" .. sha256hex(password))
--   Body = packed binary delta feed: [u64 time] then per unit
--   [u32 id] then (1-byte DataIndex)(value)... until 0xff.
--
-- Networking: luasocket (bundled with DCS), NON-BLOCKING state machine — the
-- fetch is spread across frames so a big feed never stalls the render thread.
-- HTTP/1.0 + Connection: close for dead-simple framing (chunked handled
-- defensively anyway).
--
-- Self-tests run at load (sha256 / base64 / f64 / u16 / u32 against Python-
-- generated ground truth) and log PASS/FAIL to dcs.log — a silent decode bug
-- can't masquerade as "no traffic".
-- ============================================================================

local CGOLY = {}

local function L(msg)
    if log and log.write then log.write('CarrierGUI-Olympus', log.INFO, msg) end
end

-- ── luasocket ────────────────────────────────────────────────────────────────
local socket = nil
do
    local ok, s = pcall(function()
        -- standard DCS hook pattern (same as Olympus's own hook / SRS)
        package.path  = package.path  .. ';' .. lfs.currentdir() .. 'LuaSocket\\?.lua'
        package.cpath = package.cpath .. ';' .. lfs.currentdir() .. 'LuaSocket\\?.dll'
        return require('socket')
    end)
    if ok and s then socket = s else L('luasocket unavailable: ' .. tostring(s)) end
end
function CGOLY.socketAvailable() return socket ~= nil end

-- ── 32-bit ops via arithmetic (Lua 5.1, no bitlib) ──────────────────────────
local floor = math.floor
local MOD = 2 ^ 32

local function bxor32(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + p end
        a = (a - x) / 2; b = (b - y) / 2; p = p * 2
    end
    return r
end
local function band32(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if x == 1 and y == 1 then r = r + p end
        a = (a - x) / 2; b = (b - y) / 2; p = p * 2
    end
    return r
end
local function bnot32(a) return 4294967295 - a end
local function rrot(x, n) return (floor(x / 2 ^ n) + (x % 2 ^ n) * 2 ^ (32 - n)) % MOD end
local function shr(x, n) return floor(x / 2 ^ n) end

-- ── SHA-256 (FIPS 180-4) ────────────────────────────────────────────────────
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256(msg)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local len = #msg
    -- padding: 0x80, zeros, 8-byte big-endian bit length
    msg = msg .. string.char(128)
    while (#msg % 64) ~= 56 do msg = msg .. string.char(0) end
    local bits = len * 8
    local lenBytes = {}
    for i = 8, 1, -1 do
        lenBytes[i] = string.char(bits % 256)
        bits = floor(bits / 256)
    end
    msg = msg .. table.concat(lenBytes)

    for chunk = 0, #msg / 64 - 1 do
        local w = {}
        local base = chunk * 64
        for i = 1, 16 do
            local o = base + (i - 1) * 4
            local b1, b2, b3, b4 = msg:byte(o + 1, o + 4)
            w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 17, 64 do
            local s0 = bxor32(bxor32(rrot(w[i - 15], 7), rrot(w[i - 15], 18)), shr(w[i - 15], 3))
            local s1 = bxor32(bxor32(rrot(w[i - 2], 17), rrot(w[i - 2], 19)), shr(w[i - 2], 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for i = 1, 64 do
            local S1 = bxor32(bxor32(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
            local ch = bxor32(band32(e, f), band32(bnot32(e), g))
            local t1 = (h + S1 + ch + K[i] + w[i]) % MOD
            local S0 = bxor32(bxor32(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
            local mj = bxor32(bxor32(band32(a, b), band32(a, c)), band32(b, c))
            local t2 = (S0 + mj) % MOD
            h = g; g = f; f = e; e = (d + t1) % MOD
            d = c; c = b; b = a; a = (t1 + t2) % MOD
        end
        H[1] = (H[1] + a) % MOD; H[2] = (H[2] + b) % MOD
        H[3] = (H[3] + c) % MOD; H[4] = (H[4] + d) % MOD
        H[5] = (H[5] + e) % MOD; H[6] = (H[6] + f) % MOD
        H[7] = (H[7] + g) % MOD; H[8] = (H[8] + h) % MOD
    end
    local out = {}
    for i = 1, 8 do out[i] = string.format('%08x', H[i]) end
    return table.concat(out)
end

-- ── base64 ──────────────────────────────────────────────────────────────────
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = floor(n / 262144) % 64
        local c2 = floor(n / 4096) % 64
        local c3 = floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or '=')
            .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
    end
    return table.concat(out)
end

-- ── binary readers (little-endian) ──────────────────────────────────────────
local function u16(s, o) local b1, b2 = s:byte(o, o + 1) return b1 + b2 * 256 end
local function u32(s, o)
    local b1, b2, b3, b4 = s:byte(o, o + 3)
    return ((b4 * 256 + b3) * 256 + b2) * 256 + b1
end
local function f64(s, o)
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(o, o + 7)
    local sign = (b8 >= 128) and -1 or 1
    local expo = (b8 % 128) * 16 + floor(b7 / 16)
    local mant = ((((((b7 % 16) * 256 + b6) * 256 + b5) * 256 + b4) * 256 + b3) * 256 + b2) * 256 + b1
    if expo == 0 then
        if mant == 0 then return 0 end
        return sign * mant * 2 ^ -1074
    elseif expo == 2047 then
        if mant == 0 then return sign * math.huge end
        return 0 / 0
    end
    return sign * (1 + mant / 2 ^ 52) * 2 ^ (expo - 1023)
end

-- ── Olympus units feed decoder (DataIndex table from DCS:OPT, proven live) ──
-- key, wire-type per index.  Complex aggregates are length-consumed, not kept.
local FIELDS = {
    [1] = { 'category', 's' }, [2] = { 'alive', 'b' }, [3] = { 'alarmState', 'b' },
    [4] = { 'radarState', 'b' }, [5] = { 'human', 'b' }, [6] = { 'controlled', 'b' },
    [7] = { 'coalition', 'b' }, [8] = { 'country', 'b' }, [9] = { 'name', 's' },
    [10] = { 'unitName', 's' }, [11] = { 'callsign', 's' }, [12] = { 'unitID', 'u4' },
    [13] = { 'groupID', 'u4' }, [14] = { 'groupName', 's' }, [15] = { 'state', 'b' },
    [16] = { 'task', 's' }, [17] = { 'hasTask', 'b' }, [18] = { 'position', 'll' },
    [19] = { 'speed', 'd' }, [20] = { 'hVel', 'd' }, [21] = { 'vVel', 'd' },
    [22] = { 'heading', 'd' }, [23] = { 'track', 'd' }, [24] = { 'isActiveTanker', 'b' },
    [25] = { 'isActiveAWACS', 'b' }, [26] = { 'onOff', 'b' }, [27] = { 'followRoads', 'b' },
    [28] = { 'fuel', 'u2' }, [29] = { 'desiredSpeed', 'd' }, [30] = { 'desiredSpeedType', 'b' },
    [31] = { 'desiredAltitude', 'd' }, [32] = { 'desiredAltitudeType', 'b' }, [33] = { 'leaderID', 'u4' },
    [34] = { nil, 'skip24' }, [35] = { 'targetID', 'u4' }, [36] = { nil, 'skip24' },
    [37] = { 'ROE', 'b' }, [38] = { 'reactionToThreat', 'b' }, [39] = { 'emissionsCountermeasures', 'b' },
    [40] = { nil, 'skip7' }, [41] = { nil, 'skip6' }, [42] = { nil, 'skip5' },
    [43] = { nil, 'ammo' }, [44] = { nil, 'contacts' }, [45] = { nil, 'path' },
    [46] = { 'isLeader', 'b' }, [47] = { 'operateAs', 'b' }, [48] = { 'shotsScatter', 'b' },
    [49] = { 'shotsIntensity', 'b' }, [50] = { 'health', 'b' }, [51] = { 'racetrackLength', 'd' },
    [52] = { nil, 'skip24' }, [53] = { 'racetrackBearing', 'd' }, [54] = { 'timeToNextTasking', 'd' },
    [55] = { 'barrelHeight', 'd' }, [56] = { 'muzzleVelocity', 'd' }, [57] = { 'aimTime', 'd' },
    [58] = { 'shotsToFire', 'u4' }, [59] = { 'shotsBaseInterval', 'd' }, [60] = { 'shotsBaseScatter', 'd' },
    [61] = { 'engagementRange', 'd' }, [62] = { 'targetingRange', 'd' }, [63] = { 'aimMethodRange', 'd' },
    [64] = { 'acquisitionRange', 'd' }, [65] = { 'airborne', 'b' },
}
local END = 0xFF

local function readField(data, o, t)
    if t == 'b' then return data:byte(o), o + 1 end
    if t == 'u2' then return u16(data, o), o + 2 end
    if t == 'u4' then return u32(data, o), o + 4 end
    if t == 'd' then return f64(data, o), o + 8 end
    if t == 's' then
        local ln = u16(data, o)
        local raw = data:sub(o + 2, o + 1 + ln)
        local z = raw:find('\0', 1, true)
        if z then raw = raw:sub(1, z - 1) end
        return raw, o + 2 + ln
    end
    if t == 'll' then
        local lat = f64(data, o)
        local lng = f64(data, o + 8)
        local alt = f64(data, o + 16)
        return { lat = lat, lng = lng, alt = alt }, o + 24
    end
    if t == 'skip24' then return nil, o + 24 end
    if t == 'skip7' then return nil, o + 7 end
    if t == 'skip6' then return nil, o + 6 end
    if t == 'skip5' then return nil, o + 5 end
    if t == 'ammo' then return nil, o + 2 + u16(data, o) * 38 end
    if t == 'contacts' then return nil, o + 2 + u16(data, o) * 5 end
    if t == 'path' then return nil, o + 2 + u16(data, o) * 24 end
    return nil, nil  -- unknown type
end

-- fallback resync: next 0xff that starts a fresh unit
-- (0xff [u32 id][0x01][u16 len][ascii])
local function nextBoundary(data, o)
    local n = #data
    local i = o
    while i <= n - 8 do
        if data:byte(i) == END and data:byte(i + 5) == 0x01 and data:byte(i + 7) == 0x00 then
            local ln = data:byte(i + 6)
            local ch = data:byte(i + 8)
            if ln > 0 and ln < 64 and ch >= 32 and ch < 127 then return i + 1 end
        end
        i = i + 1
    end
    return n + 1
end

-- minimum bytes each wire type needs at offset o (so a truncated tail bails
-- gracefully instead of erroring on string.byte -> nil arithmetic)
local MINLEN = { b = 1, u2 = 2, u4 = 4, d = 8, ll = 24, skip24 = 24,
                 skip7 = 7, skip6 = 6, skip5 = 5, s = 2, ammo = 2, contacts = 2, path = 2 }

local function decodeUnits(raw)
    local units = {}
    local n = #raw
    if n < 12 then return units end
    local o = 9  -- skip u64 time header (bytes 1..8)
    while o <= n - 4 and #units < 5000 do
        local okUnit = true
        local id = u32(raw, o)
        o = o + 4
        local u = {}
        while o <= n do
            local idx = raw:byte(o)
            o = o + 1
            if idx == END then break end
            local spec = FIELDS[idx]
            if not spec then
                o = nextBoundary(raw, o - 1)
                okUnit = false
                break
            end
            local need = MINLEN[spec[2]]
            if need and o + need - 1 > n then okUnit = false o = n + 1 break end
            local val, no = readField(raw, o, spec[2])
            if not no or no > n + 1 then okUnit = false o = n + 1 break end
            if spec[1] and val ~= nil then u[spec[1]] = val end
            o = no
        end
        if okUnit or u.position then units[#units + 1] = u end
    end
    return units
end

-- ── recovery computation (same math as the hook's mission-side CG_QUERY) ────
local NM = 1852.0
local CV_PAT = { 'CVN', 'Stennis', 'VINSON', 'Forrestal', 'Roosevelt', 'Lincoln',
                 'Washington', 'Truman', 'Eisenhower', 'LHA', 'Tarawa', 'Wasp', 'America' }
local SUP_PAT = { 'KC130', 'KC-130', 'KC135', 'KC-135', 'S-3B', 'S_3B', 'E-2', 'E_2', 'E-3', 'A-50',
                  'A-6', 'A_6', 'Intruder' }  -- A-6 = F-14 community recovery tanker
-- Plane-guard helo suppression: a helo orbiting on-station (close + low) is the
-- SAR/guard bird, not a recovery — hide it, but keep RECOVERING helos visible.
local GUARD_NM = 3      -- within this range of the boat …
local GUARD_FT = 1000   -- … and below this altitude = treated as the guard helo
-- AUTHORITATIVE DCS ATC callsigns (Scripts/Speech/common.lua, MARSHAL-NN).
local CSMAP = { CVN_71 = 'Rough Rider', CVN_72 = 'Union', CVN_73 = 'Warfighter',
                CVN_74 = 'Courage', CVN_75 = 'Lone Warrior', Stennis = 'Courage',
                VINSON = 'Gold Eagle' }

local function norm(a) a = a % 360 if a < 0 then a = a + 360 end return a end
local function angDelta(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end
local function matchAny(s, pats)
    if not s then return false end
    for _, p in ipairs(pats) do if s:find(p, 1, true) then return true end end
    return false
end
local function hdgDeg(h) return norm(math.deg(h or 0)) end   -- Olympus = radians

-- Prefer a modex-looking trailing number from the ME unit name (matches the
-- hook's onboard_num behavior as closely as the feed allows), else callsign.
local function modexOf(u)
    local un = u.unitName or ''
    local m = un:match('(%d%d%d)%s*$')
    local v
    if m then v = m
    elseif u.callsign and u.callsign ~= '' then v = u.callsign
    elseif un ~= '' then v = un
    else v = u.name or '?' end
    -- wire strings can contain anything; strip the section delimiters
    return (v:gsub('[|\r\n]', ' '))
end

local function compute(units)
    -- carrier pick: must be ALIVE (Olympus keeps sunk units with alive=0 —
    -- without this a wreck, or the first of two carriers in feed order, wins)
    local cv = nil
    for _, u in ipairs(units) do
        if u.position and u.alive ~= 0 and matchAny(u.name, CV_PAT) then cv = u break end
    end
    if not cv then return nil end
    local clat, clon = cv.position.lat, cv.position.lng
    local calt = cv.position.alt or 0
    local brc = hdgDeg(cv.heading)
    local fb = norm(brc - 9)
    local bR, fR = math.rad(brc), math.rad(fb)
    local bc, bs = math.cos(bR), math.sin(bR)
    local fc, fs = math.cos(fR), math.sin(fR)
    local latScale = 111320.0
    local lonScale = 111320.0 * math.cos(math.rad(clat))

    local ccz, stack, pattern, deck = {}, {}, {}, {}
    for _, u in ipairs(units) do
        repeat
            if u == cv or not u.position then break end
            local cat = (u.category or ''):lower()
            if cat ~= 'aircraft' and cat ~= 'helicopter' then break end
            if cv.coalition and u.coalition and u.coalition ~= cv.coalition then break end
            if u.alive == 0 then break end
            local north = (u.position.lat - clat) * latScale
            local east = (u.position.lng - clon) * lonScale
            local nm = math.sqrt(north * north + east * east) / NM
            if nm > 60 then break end
            local altM = u.position.alt or 0
            local altFt = floor(altM * 3.28084)
            local airborne
            if u.airborne ~= nil then airborne = (u.airborne == 1) else airborne = altM > calt + 30 end
            local modex = modexOf(u)
            local role = 'FTR'
            if cat == 'helicopter' then role = 'HELO' end
            if matchAny(u.name, SUP_PAT) or u.isActiveTanker == 1 or u.isActiveAWACS == 1 then role = 'TKR' end
            -- Ignore tankers/AWACS entirely; suppress the on-station guard helo.
            if role == 'TKR' then break end
            if role == 'HELO' and nm < GUARD_NM and altFt < GUARD_FT then break end
            local achdg = hdgDeg(u.track ~= nil and u.track or u.heading)
            local brg = norm(math.deg(math.atan2(east, north)))
            local gs = floor((u.speed or 0) * 1.94384)
            local acAhead = north * bc + east * bs
            local acStbd = north * (-bs) + east * bc

            if (not airborne) and gs < 50 and math.abs(acAhead) < 185
               and acStbd > -65 and acStbd < 55 then
                deck[#deck + 1] = string.format('%s|%d|%d', modex,
                    floor(acAhead + 0.5), floor(acStbd + 0.5))
                break
            end
            if not airborne then break end

            local point = 'enroute'
            if nm <= 4 then
                local dBRC = math.abs(angDelta(achdg, brc))
                local dREC = math.abs(angDelta(achdg, norm(brc + 180)))
                if nm < 0.45 then point = 'TRAP'
                elseif acAhead < 300 and math.abs(acStbd) < 650 and altM < 150 and dBRC < 60 then point = 'GROOVE'
                elseif acStbd < -650 and dREC < 55 then
                    if acAhead > 350 then point = 'DOWNWIND'
                    elseif acAhead > -550 then point = 'ABEAM'
                    else point = '180' end
                elseif acStbd < -300 and acAhead < -250 and altM < 175 then point = '180'
                elseif acStbd > -550 and dBRC < 45 and altM > 165 then point = 'INITIAL'
                elseif altM > 150 and dBRC >= 45 and dBRC <= 130 and acAhead > -300 then point = 'BREAK'
                else point = 'pattern' end
            end
            local jy = (north * fc + east * fs) / NM
            local jx = (-north * fs + east * fc) / NM
            if role ~= 'TKR' and nm < 25 then
                stack[#stack + 1] = string.format('%s|%d|%d|0|%s|HOLD|%.2f|%.2f',
                    modex, altFt, gs, point, jx, jy)
            end
            if nm < 60 and nm > 8 then
                ccz[#ccz + 1] = string.format('%s|%d|%.1f|%d|%d|%s|%d',
                    modex, floor(brg + 0.5) % 360, nm, altFt, gs, role, floor(achdg + 0.5) % 360)
            end
            if nm < 12 and role ~= 'TKR' then
                pattern[#pattern + 1] = string.format('%s|%d|%d|%s|%d|%d',
                    modex, altFt, gs, point, floor(acAhead + 0.5), floor(acStbd + 0.5))
            end
        until true
    end

    local cs = CSMAP[cv.name or ''] or cv.name or 'Mother'
    -- MISSION time-of-day when available (hook env has DCS.*); wall clock only
    -- as a last resort.  EATs key off this, so mission time is the contract.
    local tod = 43200
    local okT = pcall(function()
        local st = DCS.getCurrentMission().mission.start_time
        tod = floor((st + (DCS.getModelTime() or 0)) % 86400)
    end)
    if not okT then
        pcall(function()
            tod = tonumber(os.date('%H')) * 3600 + tonumber(os.date('%M')) * 60 + tonumber(os.date('%S'))
        end)
    end
    -- lat/lon so the hook can derive magnetic variation (BRC/radials are shown
    -- magnetic); spd = ship's own speed in kt (WOD proxy — the feed has no wind).
    local cvSpdKt = floor((cv.speed or 0) * 1.94384 + 0.5)
    -- 1-decimal headings (whole-degree pre-rounding caused ±1° vs the game)
    local ship = string.format('hdg=%.1f\nfb=%.1f\ncallsign=%s\ntod=%d\nlat=%.4f\nlon=%.4f\nspd=%d\n',
        brc % 360, fb % 360, cs, tod, clat, clon, cvSpdKt)
    return { ship = ship, stack = table.concat(stack, '\n'), ccz = table.concat(ccz, '\n'),
             pattern = table.concat(pattern, '\n'), deck = table.concat(deck, '\n') }
end

-- ── connection state machine (non-blocking; spread across frames) ───────────
local S = {
    enabled = false, host = nil, port = 4512, auth = nil,
    state = 'idle', sock = nil, buf = '', reqSent = 0, req = '',
    started = 0, lastPoll = 0, lastOk = 0, fails = 0,
    everOk = false, lastError = nil, result = nil,
    POLL = 1.0, CONNECT_TIMEOUT = 5.0, FETCH_TIMEOUT = 10.0, MAX_BODY = 4 * 1024 * 1024,
}

local function closeSock()
    if S.sock then pcall(function() S.sock:close() end) end
    S.sock = nil
    S.state = 'idle'
    S.buf = ''
    S.reqSent = 0
end

local function fail(why)
    S.fails = S.fails + 1
    S.lastError = why
    closeSock()
end

function CGOLY.configure(host, port, password)
    closeSock()                       -- abandon any in-flight request first
    S.host = host
    S.port = tonumber(port) or 4512
    -- ALWAYS hash (protocol = sha256hex of the role password, even when blank)
    S.auth = 'Basic ' .. b64('Game master:' .. sha256(password or ''))
    -- resolve DNS ONCE here (a one-time block at button press is fine; doing it
    -- in tick() would stall the render thread every retry on a bad hostname)
    S.hostIp = host
    if socket and not host:match('^%d+%.%d+%.%d+%.%d+$') then
        local ip = socket.dns and socket.dns.toip and socket.dns.toip(host)
        if ip then
            S.hostIp = ip
        else
            S.lastError = 'cannot resolve host "' .. tostring(host) .. '"'
            return nil, S.lastError
        end
    end
    S.req = 'GET /olympus/units?time=0 HTTP/1.0\r\n'
        .. 'Host: ' .. host .. ':' .. tostring(S.port) .. '\r\n'
        .. 'Authorization: ' .. S.auth .. '\r\n'
        .. 'Connection: close\r\n\r\n'
    return true
end

function CGOLY.start()
    S.enabled = true
    S.everOk = false
    S.fails = 0
    S.lastError = nil
    S.lastPoll = 0     -- fire immediately
    closeSock()
end

function CGOLY.stop()
    S.enabled = false
    S.everOk = false
    S.result = nil
    closeSock()
end

function CGOLY.active() return S.enabled and S.everOk end
function CGOLY.status()
    return {
        enabled = S.enabled, ok = S.everOk, fails = S.fails,
        lastError = S.lastError, state = S.state,
        ageSecs = (S.lastOk > 0 and socket) and (socket.gettime() - S.lastOk) or nil,
    }
end
function CGOLY.result() return S.result end

local function parseHttp(buf)
    local code = tonumber(buf:match('^HTTP/%d%.%d (%d+)'))
    local hEnd = buf:find('\r\n\r\n', 1, true)
    if not code or not hEnd then return nil, nil end
    local headers = buf:sub(1, hEnd - 1):lower()
    local body = buf:sub(hEnd + 4)
    if headers:find('transfer%-encoding:%s*chunked') then
        -- defensive de-chunk (HTTP/1.0 request shouldn't get this, but proxies)
        local out, o = {}, 1
        while true do
            local nl = body:find('\r\n', o, true)
            if not nl then break end
            local sz = tonumber(body:sub(o, nl - 1):match('^%x+'), 16)
            if not sz or sz == 0 then break end
            out[#out + 1] = body:sub(nl + 2, nl + 1 + sz)
            o = nl + 2 + sz + 2
        end
        body = table.concat(out)
    end
    return code, body
end

-- Called every frame from the hook. Cheap when idle; spreads I/O across frames.
function CGOLY.tick()
    if not S.enabled or not socket or not S.host then return end
    local now = socket.gettime()

    if S.state == 'idle' then
        if now - S.lastPoll < S.POLL then return end
        S.lastPoll = now
        local sock = socket.tcp()
        if not sock then fail('socket create failed') return end
        sock:settimeout(0)
        -- non-blocking connect to the PRE-RESOLVED ip (no DNS on this thread);
        -- 'timeout' = in progress, anything else = immediate hard failure
        local okC, errC = sock:connect(S.hostIp or S.host, S.port)
        if not okC and errC and errC ~= 'timeout' then
            pcall(function() sock:close() end)
            fail('connect: ' .. tostring(errC))
            return
        end
        S.sock = sock
        S.state = 'connecting'
        S.started = now
        return
    end

    if S.state == 'connecting' then
        local _, writable = socket.select(nil, { S.sock }, 0)
        if writable and #writable > 0 then
            S.state = 'sending'
            S.reqSent = 0
        elseif now - S.started > S.CONNECT_TIMEOUT then
            fail('unreachable ' .. tostring(S.host) .. ':' .. tostring(S.port))
        end
        return
    end

    if S.state == 'sending' then
        local i, err, partial = S.sock:send(S.req, S.reqSent + 1)
        S.reqSent = i or partial or S.reqSent
        if S.reqSent >= #S.req then
            S.state = 'receiving'
            S.buf = ''
        elseif err and err ~= 'timeout' then
            fail('send failed: ' .. tostring(err))
        elseif now - S.started > S.CONNECT_TIMEOUT then
            fail('send timeout')
        end
        return
    end

    if S.state == 'receiving' then
        -- drain whatever is buffered this frame
        for _ = 1, 64 do
            local chunk, err, partial = S.sock:receive(16384)
            if chunk then S.buf = S.buf .. chunk
            elseif partial and #partial > 0 then S.buf = S.buf .. partial end
            if err == 'closed' then
                local code, body = parseHttp(S.buf)
                closeSock()
                if code == 200 and body then
                    local okD, res = pcall(function() return compute(decodeUnits(body)) end)
                    if okD and res then
                        S.result = res
                        S.everOk = true
                        S.lastOk = now
                        S.fails = 0
                        S.lastError = nil
                    elseif okD then
                        -- authed + decodable, just no carrier spawned yet: that
                        -- IS a successful connection (panel renders empty, like
                        -- local mode) — never fail the login over an empty sea.
                        S.everOk = true
                        S.lastOk = now
                        S.fails = 0
                        S.result = nil
                        S.lastError = 'connected - no carrier in the Olympus picture yet'
                    else
                        fail('decode error: ' .. tostring(res))
                    end
                elseif code == 401 or code == 403 then
                    S.enabled = false
                    S.everOk = false
                    S.lastError = 'auth rejected (check Game master password)'
                elseif code then
                    fail('HTTP ' .. tostring(code))
                else
                    fail('bad response')
                end
                return
            end
            if err and err ~= 'timeout' and err ~= 'closed' then
                fail('recv: ' .. tostring(err))
                return
            end
            if err == 'timeout' and not chunk then break end
            if #S.buf > S.MAX_BODY then fail('response too large') return end
        end
        if now - S.started > S.FETCH_TIMEOUT then fail('fetch timeout') end
        return
    end
end

-- ── self-test (ground truth generated with Python hashlib/struct) ───────────
do
    local ok = true
    local function chk(name, got, want)
        if got ~= want then
            ok = false
            L('SELF-TEST FAIL ' .. name .. ': got ' .. tostring(got) .. ' want ' .. tostring(want))
        end
    end
    chk('sha256-empty', sha256(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    chk('sha256-abc', sha256('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    chk('sha256-test123', sha256('test123'), 'ecd71870d1963316a97e3ac3408c9835ad8cf0f3c1bc703527c30265534f75ae')
    chk('b64', b64('Game master:'), 'R2FtZSBtYXN0ZXI6')
    local function fx(hex)
        local s = {}
        for byte in hex:gmatch('%x%x') do s[#s + 1] = string.char(tonumber(byte, 16)) end
        return table.concat(s)
    end
    chk('f64-1.0', f64(fx('000000000000f03f'), 1), 1.0)
    chk('f64--2.5', f64(fx('00000000000004c0'), 1), -2.5)
    chk('f64-100', f64(fx('0000000000005940'), 1), 100.0)
    chk('f64-36.5', f64(fx('0000000000404240'), 1), 36.5)
    chk('f64-0', f64(fx('0000000000000000'), 1), 0)
    chk('u16', u16(fx('3412'), 1), 0x1234)
    chk('u32', u32(fx('78563412'), 1), 305419896)
    L(ok and 'self-test PASS (sha256/b64/f64/u16/u32)' or 'SELF-TEST FAILED — Olympus login will misbehave')
    CGOLY.selfTestOk = ok
end

L('Olympus client loaded (socket=' .. tostring(socket ~= nil) .. ')')
return CGOLY
