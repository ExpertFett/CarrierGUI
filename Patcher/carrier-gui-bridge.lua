-- CarrierGUI Mission Bridge  (rebuild v0.7 — (no bridge changes))
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

local function broadcastCase(caseNum)
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

    return timer.getTime() + POLL_INTERVAL
end

-- ============================================================================
-- Boot
-- ============================================================================
buildBeaconCache()
timer.scheduleFunction(poll, {}, timer.getTime() + POLL_INTERVAL)
say('Bridge online (v0.9) — auto-discovering carriers', 6)
