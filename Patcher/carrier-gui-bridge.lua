-- CarrierGUI Mission Bridge  (rebuild v1.2-beta1 — recovery monitor (CASE III milestones))
-- ============================================================================
-- Embedded into every patched .miz by Tools/patch_miz.py.
-- Polls user flags set by the Hook (Ctrl+Shift+c GUI), then pushes the
-- appropriate task to each carrier in the mission.
--
-- DCS Lua env at load time (a_do_script_file context):
--   HAS: trigger.action, env.mission readable, timer, coalition, atmosphere,
--        Group/Unit/Controller objects, std libs
--   LACKS: a_*, mission.trig, MOOSE classes
--
-- INSTALL:
--   Loaded automatically by the patcher's embedded DO SCRIPT trigger
--   (ONCE + TIME MORE 1). Do not load manually.
--
-- FLAG MAPPING (must match hook + patcher):
--    1=TACAN Off       2=TACAN On         (WrappedAction)
--    3=ICLS Off        4=ICLS On          (WrappedAction)
--    5=LINK4 Off       6=LINK4 On         (WrappedAction)
--    7=ACLS Off        8=ACLS On          (WrappedAction)
--  100..106 = Wind Stop/30m/60m/90m/2h/4h/8h   (controller:setTask)
--   (10..14 are handled by patcher-written inline triggers, not by us.)
-- ============================================================================

-- Idempotency guard (gotcha — re-running the load trigger must not double up).
if _G.__CARRIER_GUI_BRIDGE_LOADED then
    return
end
_G.__CARRIER_GUI_BRIDGE_LOADED = true

-- Hook-side detection: set a named user flag so the hook can probe
-- whether THIS mission has the bridge embedded. The hook checks this
-- ~5s after mission start; if still 0, it shows "not patched" warning.
pcall(function()
    trigger.action.setUserFlag('carriergui_bridge_loaded', true)
end)

local POLL_INTERVAL = 1
local KTS_TO_MS     = 0.514444

-- Carrier classification. typeName from unit:getTypeName().
local CVN_PATTERNS = {'CVN', 'Stennis', 'VINSON', 'Forrestal'}
local LHA_PATTERNS = {'LHA', 'Tarawa', 'Wasp'}

local CLASS_PARAMS = {
    CVN = {targetApparentKts = 25, deckOffsetDeg = -9},
    LHA = {targetApparentKts = 10, deckOffsetDeg = 0},
}

local function matchesAny(s, patterns)
    for _, p in ipairs(patterns) do
        if string.find(s, p) then return true end
    end
    return false
end

local function classify(typeName)
    if matchesAny(typeName, CVN_PATTERNS) then return 'CVN' end
    if matchesAny(typeName, LHA_PATTERNS) then return 'LHA' end
    return nil
end

local function say(msg, dur)
    if trigger and trigger.action and trigger.action.outText then
        trigger.action.outText('[CarrierGUI] ' .. msg, dur or 8)
    end
    if env and env.info then env.info('[CarrierGUI Bridge] ' .. msg) end
end

-- ============================================================================
-- Beacon param cache (gotcha #7: key by UNIT name, not group name)
-- ============================================================================
-- At mission load env.mission contains every group's route.points[*].task.
-- For carriers, those tasks include ActivateBeacon / ActivateICLS / etc with
-- the channels and freqs the mission designer set. To re-activate after a
-- deactivate, we need those original params — so cache them now.
local BEACON_CACHE = {}   -- [unitName] = { ActivateBeacon = {...}, ActivateICLS = {...}, ... }

local BEACON_KINDS = {
    ActivateBeacon = true,
    ActivateICLS   = true,
    ActivateLink4  = true,
    ActivateACLS   = true,
}

local function cacheBeaconsForGroup(groupTable, unitName)
    BEACON_CACHE[unitName] = BEACON_CACHE[unitName] or {}
    local route = groupTable.route
    if not route or not route.points then return end
    for _, point in pairs(route.points) do
        local pTask = point.task
        if pTask and pTask.params and pTask.params.tasks then
            for _, sub in pairs(pTask.params.tasks) do
                if sub.id == 'WrappedAction' and sub.params and sub.params.action then
                    local act = sub.params.action
                    if BEACON_KINDS[act.id] then
                        -- Stash a deep-ish copy — the value table is what we
                        -- need to re-issue with the same channel/freq.
                        BEACON_CACHE[unitName][act.id] = act
                    end
                end
            end
        end
    end
end

local function buildBeaconCache()
    if not env or not env.mission or not env.mission.coalition then return end
    for _, side in pairs(env.mission.coalition) do
        if type(side) == 'table' and side.country then
            for _, country in pairs(side.country) do
                if country.ship and country.ship.group then
                    for _, group in pairs(country.ship.group) do
                        if group.units then
                            for _, unit in pairs(group.units) do
                                if unit.name then
                                    cacheBeaconsForGroup(group, unit.name)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- Carrier discovery (live)
-- ============================================================================
local function findCarriers()
    local carriers = {}
    for _, sideName in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
        local groups = coalition.getGroups(sideName, Group.Category.SHIP)
        if groups then
            for _, group in pairs(groups) do
                if group:isExist() then
                    for _, unit in pairs(group:getUnits() or {}) do
                        if unit:isExist() then
                            local tn = unit:getTypeName()
                            local class = classify(tn)
                            if class then
                                table.insert(carriers, {
                                    group    = group,
                                    unit     = unit,
                                    class    = class,
                                    unitName = unit:getName(),  -- gotcha #7
                                    typeName = tn,
                                })
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    return carriers
end

-- ============================================================================
-- WrappedAction push (beacons: TACAN / ICLS / LINK4 / ACLS)
-- ============================================================================
local function pushWrappedAction(group, actionId, actionParams)
    local task = {
        id = 'WrappedAction',
        params = {
            action = {
                id     = actionId,
                params = actionParams or {},
            },
        },
    }
    local ok, err = pcall(function() group:getController():pushTask(task) end)
    if not ok then say('pushTask(' .. actionId .. ') failed: ' .. tostring(err)) end
    return ok
end

local function deactivate(carrier, kind)
    -- kind: 'Beacon' | 'ICLS' | 'Link4' | 'ACLS'
    local actionId = 'Deactivate' .. kind
    return pushWrappedAction(carrier.group, actionId, {})
end

local function activate(carrier, kind)
    -- kind: 'Beacon' | 'ICLS' | 'Link4' | 'ACLS'
    local actionId = 'Activate' .. kind
    local cached = BEACON_CACHE[carrier.unitName] and BEACON_CACHE[carrier.unitName][actionId]
    if not cached then
        say(carrier.unitName .. ': no cached ' .. actionId
            .. ' params — set them in the mission editor first')
        return false
    end
    return pushWrappedAction(carrier.group, actionId, cached.params or {})
end

-- ============================================================================
-- Wind / Turn-Into-Wind  (controller:setTask, action='Off Road' — gotcha #6)
-- ============================================================================
local function windBearingTo(windVec)
    local a = math.deg(math.atan2(windVec.x, windVec.z))
    if a < 0 then a = a + 360 end
    return a
end

local function pushHeadingTask(group, unit, headingDeg, speedMs)
    local pos  = unit:getPoint()
    local dist = 92600                     -- ~50 nm
    local rad  = math.rad(headingDeg)
    local tx   = pos.x + math.sin(rad) * dist
    local tz   = pos.z + math.cos(rad) * dist

    local task = {
        id = 'Mission',
        params = {
            airborne = false,
            route = {
                points = {
                    [1] = {
                        type             = 'Turning Point',
                        action           = 'Off Road',        -- gotcha #6 (ships!)
                        x                = tx,
                        y                = tz,
                        speed            = speedMs,
                        speed_locked     = true,
                        ETA              = 0,
                        ETA_locked       = false,
                        formation_template = '',
                        task = { id = 'ComboTask', params = {tasks = {}} },
                    },
                },
            },
        },
    }
    local ok, err = pcall(function() group:getController():setTask(task) end)
    if not ok then say('setTask failed: ' .. tostring(err)) end
    return ok
end

local function applyWind(carrier, durationMin, label)
    local pos        = carrier.unit:getPoint()
    local wind       = atmosphere.getWind(pos)
    local toBearing  = windBearingTo(wind)
    local fromBearing= (toBearing + 180) % 360
    local windMs     = math.sqrt(wind.x * wind.x + wind.z * wind.z)
    local windKts    = windMs / KTS_TO_MS
    local params     = CLASS_PARAMS[carrier.class]

    if durationMin == nil then
        -- "Stop" — hold current heading at moderate cruise.
        local p = carrier.unit:getPosition()
        local heading = math.deg(math.atan2(p.x.x, p.x.z))
        if heading < 0 then heading = heading + 360 end
        pushHeadingTask(carrier.group, carrier.unit, heading, 12 * KTS_TO_MS)
        say(carrier.unitName .. ' (' .. carrier.class .. ') TIW stop — holding course at 12 kts')
        return
    end

    -- Point into the wind with deck offset.
    local hdg = (fromBearing + params.deckOffsetDeg) % 360
    if hdg < 0 then hdg = hdg + 360 end

    -- Ship speed so that wind-across-deck ≈ targetApparentKts.
    local shipKts = params.targetApparentKts - windKts
    if shipKts < 4  then shipKts = 4  end
    if shipKts > 30 then shipKts = 30 end

    pushHeadingTask(carrier.group, carrier.unit, hdg, shipKts * KTS_TO_MS)

    say(string.format('%s (%s) -> hdg %d, %d kts (wind %d/%d kts, %s)',
        carrier.unitName, carrier.class,
        math.floor(hdg + 0.5), math.floor(shipKts + 0.5),
        math.floor(fromBearing + 0.5), math.floor(windKts + 0.5),
        label))
end

-- ============================================================================
-- MARSHALL TAB — broadcast helpers (CASE recovery, marshal stack, Charlie)
-- ============================================================================
-- All marshall actions are broadcasts to all players via trigger.action.outText.
-- Nothing here changes a sim setting (DCS has no script API for that); these
-- relay the controller's intent to pilots on screen.

local ANGLED_DECK_OFFSET = 9   -- degrees; CASE III final bearing = heading - 9

-- Heading of the first CVN-class carrier (deg true). Returns nil if none.
local function firstCvn(carriers)
    for _, c in ipairs(carriers) do
        if c.class == 'CVN' then return c end
    end
    return carriers[1]   -- fall back to whatever carrier exists
end

local function carrierHeadingDeg(carrier)
    local p = carrier.unit:getPosition()
    local h = math.deg(math.atan2(p.x.x, p.x.z))
    if h < 0 then h = h + 360 end
    return h
end

-- Format seconds-since-midnight (mission time) as HH:MM.
local function clockHHMM(sec)
    sec = sec % 86400
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    return string.format('%02d:%02d', h, m)
end

-- Read an integer value flag, with a default.
local function flagInt(name, default)
    local v = trigger.misc.getUserFlag(name)
    if v == nil or v == 0 then return default end
    return v
end

-- Active recovery CASE. Set whenever the LSO broadcasts a case from the
-- MARSHALL tab. The recovery-monitor below uses this to decide which
-- milestone set to track. Defaults to III since that's the most common
-- night/instrument recovery and the only case with clear distance gates.
_G.__cgCurrentCase = _G.__cgCurrentCase or 'III'

local function broadcastCase(caseNum)
    _G.__cgCurrentCase = caseNum  -- stored globally so reloads preserve state
    local txt = string.format(
        '=== RECOVERY CASE %s ===\nCarrier recovery is now CASE %s.',
        caseNum, caseNum)
    trigger.action.outText(txt, 20)
    if env and env.info then env.info('[CarrierGUI] broadcast CASE ' .. caseNum) end
end

-- USN-standard CASE III marshal stack:
--   lowest flight angels 6 at 21 DME, each higher flight +1000ft and +1 DME.
--   hold on the final-bearing radial (heading - 9), 6-min left-hand pattern.
local function broadcastMarshalStack(carriers)
    local carrier = firstCvn(carriers)
    if not carrier then
        say('Marshal stack: no carrier found', 8)
        return
    end
    local flights = flagInt('cg_marshal_flights', 1)
    if flights < 1 then flights = 1 end
    if flights > 8 then flights = 8 end

    local hdg = carrierHeadingDeg(carrier)
    local fb  = (hdg - ANGLED_DECK_OFFSET) % 360
    if fb < 0 then fb = fb + 360 end

    local lines = {}
    table.insert(lines, '=== CASE III MARSHAL ===')
    table.insert(lines, string.format('%s  |  Final Bearing %03d  |  BRC %03d',
        carrier.unitName, math.floor(fb + 0.5), math.floor(hdg + 0.5)))
    table.insert(lines, 'Hold: left-hand, 6-min pattern, 30 AOB')
    for i = 1, flights do
        local angels = 6 + (i - 1)
        local dme    = 21 + (i - 1)
        table.insert(lines, string.format(
            'Flight %d:  %03d radial,  %d DME,  Angels %d',
            i, math.floor(fb + 0.5), dme, angels))
    end

    -- Append Charlie/push time if one is set.
    local charlieMin = flagInt('cg_charlie_min', 0)
    if charlieMin > 0 then
        local pushAt = timer.getAbsTime() + charlieMin * 60
        table.insert(lines, string.format('Expected push: %s (%d min)',
            clockHHMM(pushAt), charlieMin))
    end

    trigger.action.outText(table.concat(lines, '\n'), 30)
    if env and env.info then env.info('[CarrierGUI] broadcast marshal stack x' .. flights) end
end

local function broadcastCharlie(carriers)
    local charlieMin = flagInt('cg_charlie_min', 0)
    local pushAt = timer.getAbsTime() + charlieMin * 60
    local txt
    if charlieMin <= 0 then
        txt = '=== CHARLIE ===\nCharlie NOW — commence approach.'
    else
        txt = string.format('=== CHARLIE ===\nExpected push in %d min (Charlie time %s).',
            charlieMin, clockHHMM(pushAt))
    end
    trigger.action.outText(txt, 20)
    if env and env.info then env.info('[CarrierGUI] broadcast Charlie ' .. charlieMin .. 'm') end
end

-- ============================================================================
-- LSO CALLS — pure on-screen broadcasts (no Supercarrier state changes)
-- ============================================================================
local function broadcastWaveOff()
    trigger.action.outText(
        '!!! WAVE OFF  WAVE OFF  WAVE OFF !!!\nGo around — do not land.', 12)
    if env and env.info then env.info('[CarrierGUI] WAVE OFF') end
end

local function broadcastCut()
    trigger.action.outText('CUT — chop throttle, land NOW.', 10)
end

local function broadcastBingo()
    trigger.action.outText(
        'BINGO — refuel tanker on station. Marshal as fragged.', 12)
end

local function broadcastRecoveryComplete()
    trigger.action.outText(
        'Recovery complete. Carrier returning to base course.', 12)
end

local function broadcastFoulAnnounce(foul)
    if foul then
        trigger.action.outText('FOUL DECK — pattern delay, do not land.', 12)
    else
        trigger.action.outText('CLEAR DECK — resume recovery operations.', 10)
    end
end

-- ============================================================================
-- Live ship state — bridge writes a small status file every poll cycle so
-- the hook can show heading / wind-across-deck on the LSO tab. Plain text
-- key=value format so the hook can read without parsing.
-- ============================================================================
local SHIP_STATE_FILE_NAME = 'carriergui_shipstate.txt'

local function writeShipState(carriers)
    if #carriers == 0 then return end
    local c = nil
    for _, cc in ipairs(carriers) do
        if cc.class == 'CVN' then c = cc; break end
    end
    if not c then c = carriers[1] end

    local p   = c.unit:getPosition()
    local hdg = math.deg(math.atan2(p.x.x, p.x.z))
    if hdg < 0 then hdg = hdg + 360 end

    local pos     = c.unit:getPoint()
    local wind    = atmosphere.getWind(pos)
    local toBrg   = windBearingTo(wind)
    local fromBrg = (toBrg + 180) % 360
    local windMs  = math.sqrt(wind.x * wind.x + wind.z * wind.z)
    local windKts = windMs / KTS_TO_MS
    -- Decompose wind into along-deck (head) + cross-deck components,
    -- relative to ship's heading. + head = headwind (good for recovery).
    local relDeg  = (fromBrg - hdg + 540) % 360 - 180   -- -180..+180
    local relRad  = math.rad(relDeg)
    local headKts = windKts * math.cos(relRad)
    local crossKts = windKts * math.sin(relRad)

    pcall(function()
        local path = lfs.writedir() .. SHIP_STATE_FILE_NAME
        local f = io.open(path, 'w')
        if f then
            f:write(string.format(
                'hdg=%d\nwind_from=%d\nwind_kts=%d\nhead_kts=%d\ncross_kts=%d\nname=%s\nclass=%s\n',
                math.floor(hdg + 0.5),
                math.floor(fromBrg + 0.5),
                math.floor(windKts + 0.5),
                math.floor(headKts + 0.5),
                math.floor(crossKts + 0.5),
                c.unitName or '',
                c.class or ''))
            f:close()
        end
    end)
end

-- ============================================================================
-- RECOVERY MONITOR — watch inbound aircraft for CASE III milestone crossings
-- ============================================================================
-- For each carrier each poll, scan coalition aircraft and filter to those
-- on a CASE III final-bearing approach (behind the boat, within ~15° of the
-- FB radial, low, closing). When an aircraft crosses a milestone distance
-- (10/6/3/0.75 nm), append an LSO prompt line to carriergui_lso_events.txt.
-- The hook reads that file and shows the last few lines in the LSO tab.

local NM_TO_M = 1852.0

-- One row per milestone: distance (nm) → prompt text. Order matters: outer
-- first, so we check them in sequence as the aircraft closes the boat.
local CASE_III_MILESTONES = {
    { nm = 10.0, key = 'platform', prompt = 'PLATFORM — push, descend to 1200 ft, dirty up' },
    { nm =  6.0, key = '6nm',      prompt = '6 nm — comm check, ICLS/ACLS' },
    { nm =  3.0, key = '3nm',      prompt = '3 nm tipover — gear/flaps/hook, descend' },
    { nm =  0.75,key = 'ball',     prompt = 'AT BALL — request fuel state' },
}

-- Per-aircraft tracking. Key = unit name.
--   { lastDist, lastSeen, callsign, milestonesFired = {[key]=true} }
local APPROACH = {}

local function lsoEventsPath()
    return lfs.writedir() .. 'carriergui_lso_events.txt'
end

local function appendLsoEvent(line)
    pcall(function()
        local now = timer.getAbsTime()
        local stamp = clockHHMM(now)
        local f = io.open(lsoEventsPath(), 'a')
        if f then
            f:write('[' .. stamp .. '] ' .. line .. '\n')
            f:close()
        end
    end)
end

-- Rotate the events file when it gets big (keep ~last 30 lines so the hook
-- can still tail it cheaply). Called occasionally, not every poll.
local function trimLsoEventsIfBig()
    local path = lsoEventsPath()
    local f = io.open(path, 'r')
    if not f then return end
    local all = f:read('*a') or ''
    f:close()
    -- only trim if file > 4 KB (~80 lines)
    if #all < 4096 then return end
    local lines = {}
    for line in all:gmatch('[^\n]+') do
        table.insert(lines, line)
    end
    local keep = {}
    local startIdx = math.max(1, #lines - 30 + 1)
    for i = startIdx, #lines do
        table.insert(keep, lines[i])
    end
    f = io.open(path, 'w')
    if f then f:write(table.concat(keep, '\n') .. '\n'); f:close() end
end

-- Angular difference (a − b) normalised to -180..+180.
local function angDelta(a, b)
    return (a - b + 540) % 360 - 180
end

-- Distance (nm) and bearing (deg, 0=N, 90=E) from carrier to unit.
local function relativePos(carrier, unit)
    local cp = carrier.unit:getPoint()
    local up = unit:getPoint()
    local dx = up.x - cp.x
    local dz = up.z - cp.z
    local dy = up.y - cp.y
    local m  = math.sqrt(dx*dx + dy*dy + dz*dz)
    local nm = m / NM_TO_M
    local brg = math.deg(math.atan2(dx, dz))
    if brg < 0 then brg = brg + 360 end
    return nm, brg, up.y     -- altitude in m
end

local function carrierFinalBearing(carrier)
    local p = carrier.unit:getPosition()
    local h = math.deg(math.atan2(p.x.x, p.x.z))
    if h < 0 then h = h + 360 end
    local params = CLASS_PARAMS[carrier.class] or {deckOffsetDeg = 0}
    local fb = (h + params.deckOffsetDeg) % 360
    if fb < 0 then fb = fb + 360 end
    return fb
end

-- Determine if a unit is "on approach" behind the carrier.
local function onApproachCone(carrier, unitBrgFromCarrier, distNm, altM)
    if distNm > 15.0 or distNm < 0.1 then return false end
    if altM > 1500 then return false end                -- above ~5000 ft = not approaching
    local fb = carrierFinalBearing(carrier)
    -- Aircraft on inbound CASE III is at (FB + 180) from carrier.
    local approachBrg = (fb + 180) % 360
    if math.abs(angDelta(unitBrgFromCarrier, approachBrg)) > 18 then return false end
    return true
end

local function processApproach(carrier, group, unit)
    local name = unit:getName()
    if not name then return end
    local nm, brg, altM = relativePos(carrier, unit)
    if not onApproachCone(carrier, brg, nm, altM) then
        -- Out of cone: reset any prior state so a new approach can fire fresh.
        APPROACH[name] = nil
        return
    end
    local st = APPROACH[name]
    if not st then
        st = { lastDist = nm, milestonesFired = {} }
        APPROACH[name] = st
    end
    -- Only fire when crossing INWARD (closing). Avoids retriggers on jitter.
    if nm < st.lastDist then
        local callsign = group:getName() or name
        for _, m in ipairs(CASE_III_MILESTONES) do
            if st.lastDist > m.nm and nm <= m.nm and not st.milestonesFired[m.key] then
                st.milestonesFired[m.key] = true
                local line = callsign .. ' — ' .. m.prompt
                appendLsoEvent(line)
                if env and env.info then env.info('[CarrierGUI LSO] ' .. line) end
            end
        end
    end
    st.lastDist = nm
end

local function runRecoveryMonitor(carriers)
    if (_G.__cgCurrentCase or 'III') ~= 'III' then return end   -- TODO: CASE I/II
    for _, carrier in ipairs(carriers) do
        if carrier.class == 'CVN' then
            for _, side in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
                local groups = coalition.getGroups(side, Group.Category.AIRPLANE)
                if groups then
                    for _, group in pairs(groups) do
                        if group:isExist() then
                            local units = group:getUnits() or {}
                            for _, unit in pairs(units) do
                                if unit:isExist() and unit:inAir() then
                                    pcall(processApproach, carrier, group, unit)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Cheap counter so we trim the events file every ~30 polls (~30s).
local _trimCounter = 0

-- ============================================================================
-- v1.3: Aircraft enumeration (TOWER stack / MARSHALL CCZ / LSO pattern / DECK)
-- ============================================================================
-- Each poll we walk every friendly aircraft once and write up to four IPC
-- files the hook reads on its own ~1Hz tick.  Line format per file:
--
--   carriergui_stack.txt    modex|altFt|ias|inStackSec|lastPoint|state
--   carriergui_ccz.txt      modex|brg|nm|altFt|ias|inbound
--   carriergui_pattern.txt  modex|altFt|ias|patternProgress|point
--   carriergui_deck.txt     modex|alongM|acrossM
--
-- All four files are rewritten in full each poll — the hook never has to
-- diff or merge.  Empty file = no aircraft in that category.

local STACK_FILE_V13   = 'carriergui_stack.txt'
local CCZ_FILE_V13     = 'carriergui_ccz.txt'
local PATTERN_FILE_V13 = 'carriergui_pattern.txt'
local DECK_FILE_V13    = 'carriergui_deck.txt'

local _firstSeen = {}   -- modex -> timer.getTime() when first detected airborne
local _lastNm    = {}   -- modex -> prior-poll range, for closing detection
local _charlied  = {}   -- modex -> true if Tower has Charlie'd them
local _commenced = {}   -- modex -> true once they've crossed the commence threshold

local function getModex(unit)
    local n = unit:getName() or ''
    -- Try DCS Unit:getProperty('Tail#') (newer DCS feature; may fail silently)
    local ok, tail = pcall(function() return unit:getProperty('Tail#') end)
    if ok and tail and tail ~= '' then
        return tostring(tail)
    end
    -- Fallback: trailing digits of unit name (e.g. 'Hornet-203' -> '203')
    local m = n:match('(%d+)%s*$')
    if m then return m end
    return n
end

-- CASE I pattern point classifier — returns a short uppercase token.
local function classifyPoint(carrier, brg, nm, altM, isClosing)
    if nm > 5 then return 'enroute' end
    local fb = carrierFinalBearing(carrier)
    -- INITIAL: ~3 nm aft of ship on BRC, descending toward break
    local initBrg = (fb + 180) % 360
    if math.abs(angDelta(brg, initBrg)) < 25 and nm > 1 and nm < 4 and altM < 400 then
        return 'INITIAL'
    end
    -- BREAK: overhead the ship
    if nm < 0.8 then return 'BREAK' end
    -- Port side of ship, 90° left of BRC: downwind/abeam/180
    local portBrg = (fb + 270) % 360
    if math.abs(angDelta(brg, portBrg)) < 35 and nm < 3 then
        if altM > 200 and not isClosing then return 'DOWNWIND' end
        if altM > 120 then return 'ABEAM' end
        return '180'
    end
    -- GROOVE: lined up with angled deck on short final
    if nm < 1.5 and altM < 180 and isClosing then return 'GROOVE' end
    return 'pattern'
end

local function classifyState(modex, altM, nm, isClosing)
    if _commenced[modex] then return 'COMMENCING' end
    -- Auto-promote: very low + close + closing = past commence point
    if altM < 250 and nm < 3 and isClosing then
        _commenced[modex] = true
        return 'COMMENCING'
    end
    if _charlied[modex] then return 'CHARLIE' end
    return 'HOLD'
end

local function writeBuf(name, lines)
    local path = lfs.writedir() .. name
    pcall(function()
        local f = io.open(path, 'w')
        if f then
            f:write(table.concat(lines, '\n'))
            f:close()
        end
    end)
end

-- Carrier-relative offset (along the ship's nose, across to starboard) in m.
-- Used for the DECKBOSS top-down view.  Returns nil if the carrier has no
-- pose data (cpPos.x missing — shouldn't happen on a CVN).
local function carrierFrameOffset(carrier, unitPoint)
    local cp = carrier.unit:getPoint()
    local cpPos = carrier.unit:getPosition()
    if not (cp and cpPos and cpPos.x) then return nil, nil end
    local dx = unitPoint.x - cp.x
    local dz = unitPoint.z - cp.z
    local fwd_x, fwd_z = cpPos.x.x, cpPos.x.z
    -- Unit forward vector dot product → along axis (positive = ahead of nose)
    local along  = dx * fwd_x + dz * fwd_z
    -- Right-perpendicular dot product → across axis (positive = to starboard)
    local across = dx * (-fwd_z) + dz * fwd_x
    return along, across
end

local function processAircraft(carrier, unit, now, stack, ccz, pattern, deck, seen)
    if not unit:isExist() then return end
    local ok, nm, brg, altM = pcall(relativePos, carrier, unit)
    if not ok or not nm then return end

    local modex = getModex(unit)
    if modex == '' then return end
    seen[modex] = true
    if not _firstSeen[modex] then _firstSeen[modex] = now end
    local inTime = math.floor(now - _firstSeen[modex])

    local altFt = math.floor(altM * 3.28084)
    local vOk, vel = pcall(function() return unit:getVelocity() end)
    local ias = 0
    if vOk and vel then
        ias = math.floor(math.sqrt((vel.x or 0)^2 + (vel.z or 0)^2) * 1.94384)
    end

    local lastNm = _lastNm[modex] or nm
    local isClosing = (nm < lastNm - 0.05)
    _lastNm[modex] = nm

    -- Air vs deck: low + close + not airborne == on deck
    local airOk, inAir = pcall(function() return unit:inAir() end)
    inAir = (airOk and inAir)
    local onDeck = (not inAir) and (altM < 50) and (nm < 0.5)

    if onDeck then
        local along, across = carrierFrameOffset(carrier, unit:getPoint())
        if along then
            table.insert(deck, string.format('%s|%d|%d',
                modex, math.floor(along + 0.5), math.floor(across + 0.5)))
        end
        return
    end
    if not inAir then return end

    local point = classifyPoint(carrier, brg, nm, altM, isClosing)
    local state = classifyState(modex, altM, nm, isClosing)

    if nm < 25 then
        table.insert(stack, string.format('%s|%d|%d|%d|%s|%s',
            modex, altFt, ias, inTime, point, state))
    end
    if nm < 60 and nm > 8 then
        table.insert(ccz, string.format('%s|%d|%.1f|%d|%d|inbound',
            modex, math.floor(brg + 0.5), nm, altFt, ias))
    end
    if nm < 5 then
        local progByPoint = {
            INITIAL  = 0.10,
            BREAK    = 0.22,
            DOWNWIND = 0.45,
            ABEAM    = 0.60,
            ['180']  = 0.75,
            GROOVE   = 0.92,
        }
        local prog = progByPoint[point] or 0
        table.insert(pattern, string.format('%s|%d|%d|%.2f|%s',
            modex, altFt, ias, prog, point))
    end
end

local function enumerateAndWrite(carriers)
    if #carriers == 0 then
        writeBuf(STACK_FILE_V13, {})
        writeBuf(CCZ_FILE_V13, {})
        writeBuf(PATTERN_FILE_V13, {})
        writeBuf(DECK_FILE_V13, {})
        return
    end
    local carrier = firstCvn(carriers) or carriers[1]
    if not carrier then return end

    local stack, ccz, pattern, deck = {}, {}, {}, {}
    local now = timer.getTime()
    local seen = {}

    for _, side in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
        local groups = coalition.getGroups(side, Group.Category.AIRPLANE)
        if groups then
            for _, group in pairs(groups) do
                if group:isExist() then
                    for _, unit in pairs(group:getUnits() or {}) do
                        pcall(processAircraft, carrier, unit, now, stack, ccz, pattern, deck, seen)
                    end
                end
            end
        end
    end

    -- GC modexes we no longer see (despawned, despawned to deck, etc.)
    for modex in pairs(_firstSeen) do
        if not seen[modex] then
            _firstSeen[modex] = nil
            _lastNm[modex]    = nil
            _charlied[modex]  = nil
            _commenced[modex] = nil
        end
    end

    writeBuf(STACK_FILE_V13, stack)
    writeBuf(CCZ_FILE_V13, ccz)
    writeBuf(PATTERN_FILE_V13, pattern)
    writeBuf(DECK_FILE_V13, deck)
end

-- When Tower presses the Charlie broadcast button (flag 201), every aircraft
-- currently HOLDing transitions to CHARLIE — they stay CHARLIE'd until they
-- self-auto-promote to COMMENCING by crossing the low+close+closing threshold.
local function markAllCharlied()
    for modex, _ in pairs(_firstSeen) do
        if not _commenced[modex] then
            _charlied[modex] = true
        end
    end
end

-- ============================================================================
-- Flag dispatch table
-- ============================================================================
-- For wind: durationMin (nil = stop). For beacons: kind + on/off.
local FLAG_WIND = {
    [100] = nil, [101] = 30, [102] = 60, [103] = 90,
    [104] = 120, [105] = 240, [106] = 480,
}

local FLAG_BEACON = {
    [1] = {kind = 'Beacon', on = false},
    [2] = {kind = 'Beacon', on = true},
    [3] = {kind = 'ICLS',   on = false},
    [4] = {kind = 'ICLS',   on = true},
    [5] = {kind = 'Link4',  on = false},
    [6] = {kind = 'Link4',  on = true},
    [7] = {kind = 'ACLS',   on = false},
    [8] = {kind = 'ACLS',   on = true},
}

-- ============================================================================
-- Poll loop
-- ============================================================================
local lastCount = -1

local function poll()
    local carriers = findCarriers()
    if #carriers ~= lastCount then
        lastCount = #carriers
        if #carriers == 0 then
            say('No carrier groups detected — waiting.', 6)
        else
            local list = {}
            for _, c in ipairs(carriers) do
                table.insert(list, c.unitName .. ' (' .. c.class .. '/' .. c.typeName .. ')')
            end
            say('Detected: ' .. table.concat(list, ', '), 10)
        end
    end

    -- Wind flags
    for flag, durMin in pairs(FLAG_WIND) do
        local s = tostring(flag)
        if trigger.misc.getUserFlag(s) == 1 then
            trigger.action.setUserFlag(s, false)
            local label = (durMin == nil) and 'Stop' or (durMin .. 'm')
            local applied = 0
            for _, c in ipairs(carriers) do
                local ok, err = pcall(applyWind, c, durMin, label)
                if ok then applied = applied + 1
                else say('wind error: ' .. tostring(err)) end
            end
            if applied == 0 then
                say('flag ' .. s .. ' (wind ' .. label .. '): no carriers found')
            end
        end
    end

    -- Beacon flags
    for flag, def in pairs(FLAG_BEACON) do
        local s = tostring(flag)
        if trigger.misc.getUserFlag(s) == 1 then
            trigger.action.setUserFlag(s, false)
            local applied = 0
            for _, c in ipairs(carriers) do
                local ok
                if def.on then
                    ok = activate(c, def.kind)
                else
                    ok = deactivate(c, def.kind)
                end
                if ok then applied = applied + 1 end
            end
            if applied == 0 then
                say('flag ' .. s .. ' (' .. def.kind .. ' ' .. (def.on and 'on' or 'off') .. '): no carriers')
            end
        end
    end

    -- Marshall tab flags (all are broadcasts; do not require a carrier task)
    if trigger.misc.getUserFlag('200') == 1 then
        trigger.action.setUserFlag('200', false)
        pcall(broadcastMarshalStack, carriers)
    end
    if trigger.misc.getUserFlag('201') == 1 then
        trigger.action.setUserFlag('201', false)
        pcall(broadcastCharlie, carriers)
        pcall(markAllCharlied)   -- v1.3: also flip every HOLD aircraft to CHARLIE'd
    end
    if trigger.misc.getUserFlag('202') == 1 then
        trigger.action.setUserFlag('202', false)
        pcall(broadcastCase, 'I')
    end
    if trigger.misc.getUserFlag('203') == 1 then
        trigger.action.setUserFlag('203', false)
        pcall(broadcastCase, 'II')
    end
    if trigger.misc.getUserFlag('204') == 1 then
        trigger.action.setUserFlag('204', false)
        pcall(broadcastCase, 'III')
    end

    -- LSO calls tab flags (broadcasts only; PLAT/wire/zoom/foul state changes
    -- are handled hook-side via file IPC + patched PLATCameraUI, not here).
    if trigger.misc.getUserFlag('210') == 1 then
        trigger.action.setUserFlag('210', false)
        pcall(broadcastWaveOff)
    end
    if trigger.misc.getUserFlag('211') == 1 then
        trigger.action.setUserFlag('211', false)
        pcall(broadcastCut)
    end
    if trigger.misc.getUserFlag('212') == 1 then
        trigger.action.setUserFlag('212', false)
        pcall(broadcastBingo)
    end
    if trigger.misc.getUserFlag('213') == 1 then
        trigger.action.setUserFlag('213', false)
        pcall(broadcastRecoveryComplete)
    end
    if trigger.misc.getUserFlag('214') == 1 then
        trigger.action.setUserFlag('214', false)
        pcall(broadcastFoulAnnounce, true)
    end
    if trigger.misc.getUserFlag('215') == 1 then
        trigger.action.setUserFlag('215', false)
        pcall(broadcastFoulAnnounce, false)
    end

    -- Update ship state file every poll so the hook can show live readouts.
    pcall(writeShipState, carriers)

    -- Recovery monitor: watch inbound aircraft for CASE III milestones,
    -- write events to the LSO log file the hook tails.
    pcall(runRecoveryMonitor, carriers)

    -- v1.3: enumerate every friendly aircraft once and write the four IPC
    -- files the hook reads (stack / ccz / pattern / deck).
    pcall(enumerateAndWrite, carriers)
    _trimCounter = (_trimCounter or 0) + 1
    if _trimCounter >= 30 then
        _trimCounter = 0
        pcall(trimLsoEventsIfBig)
    end

    return timer.getTime() + POLL_INTERVAL
end

-- ============================================================================
-- Boot
-- ============================================================================
buildBeaconCache()
timer.scheduleFunction(poll, {}, timer.getTime() + POLL_INTERVAL)
say('Bridge online (v1.3-beta24) — auto-discovering carriers', 6)
