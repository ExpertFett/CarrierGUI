-- carriergui-export.lua  (v1.3-beta50)
-- CLIENT-SIDE data source for the CarrierGUI panel — the "Tacview model".
-- Runs in the DCS Export environment (LoGetWorldObjects), so it sees the carrier
-- + recovering aircraft your client receives from the server.  Computes the
-- recovery picture and writes the same carriergui_*.txt files the panel reads.
-- No relay, no agent, no server-side install, no desanitize.
--
-- INSTALL: append to  Saved Games\DCS\Scripts\Export.lua :
--     local cg = lfs.writedir()..[[Scripts\Hooks\carriergui-export.lua]]
--     if lfs.attributes(cg) then dofile(cg) end
-- (Setup.bat does this for you.)  It CHAINS — it won't break Tacview/SRS exports.
--
-- LIMITATIONS (vs the mission-side bridge): no wind/altimeter/weather (not in the
-- export API); far traffic can be culled by MP networking on locked servers;
-- read-only (control is via the F10 radio menu / the mission bridge).

local CG = {}
CG.NM        = 1852.0
CG.POLL      = 1.0          -- seconds between writes
CG.RANGE_NM  = 60           -- consider aircraft within this of the boat
CG.last      = 0
CG.firstSeen = {}           -- id -> model-time first seen
CG.prev      = {}           -- id -> { lat, lon, t, nm }

CG.CV = { 'CVN', 'Stennis', 'VINSON', 'Forrestal', 'Roosevelt', 'Lincoln',
          'Washington', 'Truman', 'Eisenhower', 'LHA', 'Tarawa', 'Wasp', 'America' }
CG.SUPPORT = { 'KC130', 'KC-130', 'KC135', 'KC-135', 'S-3B', 'S_3B', 'E-2', 'E_2',
               'E-3', 'A-50', 'KC130J', 'A-6', 'A_6', 'Intruder' }
-- Helicopter type names (Export gives the type in o.Name) — shown for carrier
-- ops, but the on-station guard bird (close+low) is suppressed.
CG.HELO = { 'SH-60', 'UH-60', 'MH-60', 'CH-53', 'CH-47', 'Ka-27', 'Ka-50', 'Ka-52',
            'Mi-8', 'Mi-24', 'Mi-28', 'UH-1', 'AH-64', 'AH-1', 'SA342', 'Gazelle', 'OH-58' }
CG.GUARD_NM = 3
CG.GUARD_FT = 1000
-- AUTHORITATIVE DCS ATC callsigns (Scripts/Speech/common.lua, MARSHAL-NN).
CG.CSMAP = { CVN_71='Rough Rider', CVN_72='Union', CVN_73='Warfighter',
             CVN_74='Courage', CVN_75='Lone Warrior', Stennis='Courage',
             VINSON='Gold Eagle', Forrestal='Forrestal' }

local function norm(a) a = a % 360; if a < 0 then a = a + 360 end; return a end
local function angDelta(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end
local function matchAny(s, list)
    for _, p in ipairs(list) do if s:find(p, 1, true) then return true end end
    return false
end

-- relative north/east metres of (lat,lon) from the carrier (flat-earth, fine at
-- recovery ranges).
local function relNE(lat, lon, cvLat, cvLon)
    local north = (lat - cvLat) * 111320.0
    local east  = (lon - cvLon) * 111320.0 * math.cos(math.rad(cvLat))
    return north, east
end

local function write(name, text)
    local ok, f = pcall(io.open, lfs.writedir() .. name, 'w')
    if ok and f then f:write(text or ''); f:close() end
end

local function tick()
    local now = LoGetModelTime() or 0
    if (now - CG.last) < CG.POLL then return end
    local dt = now - CG.last
    CG.last = now

    local objs = LoGetWorldObjects()
    if not objs then return end

    -- find the carrier
    local cv
    for id, o in pairs(objs) do
        if o.Name and matchAny(o.Name, CG.CV) and o.LatLongAlt then
            cv = o; cv._id = id; break
        end
    end
    if not cv then return end

    local cvLat, cvLon = cv.LatLongAlt.Lat, cv.LatLongAlt.Long
    local cvAlt = cv.LatLongAlt.Alt or 0
    local brc = norm(math.deg(cv.Heading or 0))
    local fb  = norm(brc - 9)
    local brcR, fbR = math.rad(brc), math.rad(fb)
    local cof, cos_, sin_ = nil, math.cos(brcR), math.sin(brcR)  -- forward N/E
    local fcos, fsin = math.cos(fbR), math.sin(fbR)

    local ccz, stack, pattern, deck = {}, {}, {}, {}
    local seen = {}

    for id, o in pairs(objs) do
        if id ~= cv._id and o.LatLongAlt and o.CoalitionID == cv.CoalitionID and o.Name then
            local lat, lon = o.LatLongAlt.Lat, o.LatLongAlt.Long
            local altM = o.LatLongAlt.Alt or 0
            local north, east = relNE(lat, lon, cvLat, cvLon)
            local nm = math.sqrt(north * north + east * east) / CG.NM
            local airborne = (altM > cvAlt + 30)
            local onDeck   = (altM <= cvAlt + 30)
            if nm <= CG.RANGE_NM then
                local modex = o.UnitName or o.Name
                local isHelo = matchAny(o.Name, CG.HELO)
                local role = (matchAny(o.Name, CG.SUPPORT) and 'TKR')
                          or (isHelo and 'HELO') or 'FTR'
                local altFt = math.floor(altM * 3.28084)
                -- ignore tankers/AWACS entirely; suppress the on-station guard helo
                local skip = (role == 'TKR')
                          or (isHelo and airborne and nm < CG.GUARD_NM and altFt < CG.GUARD_FT)
                local achdg = norm(math.deg(o.Heading or 0))
                local brg   = norm(math.deg(math.atan2(east, north)))
                -- ground speed from the last sample
                local gs = 0
                local p = CG.prev[id]
                if p and dt > 0 then
                    local pn, pe = relNE(p.lat, p.lon, cvLat, cvLon)
                    gs = math.floor(math.sqrt((north-pn)^2 + (east-pe)^2) / dt * 1.94384)
                end
                local closing = p and (nm < (p.nm or nm) - 0.02) or false
                CG.prev[id] = { lat = lat, lon = lon, t = now, nm = nm }
                seen[id] = true
                if not CG.firstSeen[id] then CG.firstSeen[id] = now end
                local inT = math.floor(now - CG.firstSeen[id])

                -- deck-frame metres (acAhead +=bow, acStbd +=starboard)
                local acAhead = north * cos_ + east * sin_
                local acStbd  = north * (-sin_) + east * cos_

                if skip then
                    -- tanker/AWACS or the guard helo: contribute nothing
                elseif onDeck and gs < 50 and math.abs(acAhead) < 185 and acStbd > -65 and acStbd < 55 then
                    deck[#deck+1] = string.format('%s|%d|%d', modex, math.floor(acAhead+0.5), math.floor(acStbd+0.5))
                elseif airborne then
                    -- CASE I pattern point (nm<=4)
                    local point = 'enroute'
                    if nm <= 4 then
                        local dBRC = math.abs(angDelta(achdg, brc))
                        local dREC = math.abs(angDelta(achdg, norm(brc+180)))
                        if nm < 0.45 then point = 'TRAP'
                        elseif acAhead < 300 and math.abs(acStbd) < 650 and altM < 150 and closing and dBRC < 60 then point = 'GROOVE'
                        elseif acStbd < -650 and dREC < 55 then
                            if acAhead > 350 then point = 'DOWNWIND' elseif acAhead > -550 then point = 'ABEAM' else point = '180' end
                        elseif acStbd < -300 and acAhead < -250 and altM < 175 then point = '180'
                        elseif acStbd > -550 and dBRC < 45 and altM > 165 then point = 'INITIAL'
                        elseif altM > 150 and dBRC >= 45 and dBRC <= 130 and acAhead > -300 then point = 'BREAK'
                        else point = 'pattern' end
                    end
                    local jy = (north * fcos + east * fsin) / CG.NM
                    local jx = (-north * fsin + east * fcos) / CG.NM
                    if role ~= 'TKR' and nm < 25 then
                        stack[#stack+1] = string.format('%s|%d|%d|%d|%s|HOLD|%.2f|%.2f', modex, altFt, gs, inT, point, jx, jy)
                    end
                    if nm < 60 and nm > 8 then
                        ccz[#ccz+1] = string.format('%s|%d|%.1f|%d|%d|%s|%d', modex, math.floor(brg+0.5), nm, altFt, gs, role, math.floor(achdg+0.5))
                    end
                    if nm < 12 and role ~= 'TKR' then
                        pattern[#pattern+1] = string.format('%s|%d|%d|%s|%d|%d', modex, altFt, gs, point, math.floor(acAhead+0.5), math.floor(acStbd+0.5))
                    end
                end
            end
        end
    end

    -- GC departed
    for id in pairs(CG.prev) do if not seen[id] then CG.prev[id] = nil; CG.firstSeen[id] = nil end end

    -- ship state (no wind/altimeter from the export API)
    local cs = CG.CSMAP[cv.Name] or cv.Name or 'Mother'
    local tod = math.floor((LoGetMissionStartTime() or 43200) + now)
    -- 1-decimal headings (whole-degree pre-rounding caused ±1° vs the game)
    local ship = string.format('hdg=%.1f\nfb=%.1f\ncallsign=%s\ntod=%d\n', brc % 360, fb % 360, cs, tod)

    write('carriergui_shipstate.txt', ship)
    write('carriergui_stack.txt',   table.concat(stack, '\n'))
    write('carriergui_ccz.txt',     table.concat(ccz, '\n'))
    write('carriergui_pattern.txt', table.concat(pattern, '\n'))
    write('carriergui_deck.txt',    table.concat(deck, '\n'))
    write('carriergui_relay_active.txt', tostring(math.floor(now * 10)))  -- heartbeat -> panel uses files
end

-- chain with any existing Export.lua (Tacview/SRS/etc.)
do
    local _next = LuaExportAfterNextFrame
    function LuaExportAfterNextFrame()
        if _next then pcall(_next) end
        pcall(tick)
    end
end
