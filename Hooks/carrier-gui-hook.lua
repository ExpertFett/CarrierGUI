-- CarrierGUI Hook  (rebuild v1.3-beta9 — full 5-tab UX overhaul)
--   CARRIER  — F10 menu controls.  Unchanged.
--   MARSHALL — NEW. 60nm CCZ tracker + marshal radio readout.
--   TOWER    — was old MARSHALL.  Now has STACK / CHARLIE'D / COMMENCING
--              roster sections fed by the bridge enumeration.
--   LSO      — Rebuilt.  CASE I pattern roster + WAVE OFF / CUT lights +
--              NVG bar + RESET CAM.  Wire/Deck/Zoom/Bingo/RecovOK retired.
--   DECKBOSS — NEW.  Top-down deck silhouette + modex positions +
--              conga-line toggle (view-only).
-- Panel: 540 × 800.
-- ============================================================================
-- Loads the carrier-gui.dlg dialog and toggles it with Ctrl+Shift+c.
-- Each button fires a numbered user flag via net.dostring_in("server", ...).
-- The in-mission Bridge (carrier-gui-bridge.lua, embedded per-.miz) reacts.
--
-- INSTALL:
--   Copy this file AND carrier-gui.dlg to <DCS Saved Games>\Scripts\Hooks\
--
-- HOTKEY:  Ctrl+Shift+c   (lowercase 'c' — memory gotcha #3)
-- ============================================================================

local base = _G

-- Hook env mini-module so 'log' / 'require' globals don't shadow when we
-- reload via DCS.setUserCallbacks across reloads.
local function load()

    package.path  = package.path .. ';.\\LuaSocket\\?.lua;' .. '.\\Scripts\\?.lua;' .. '.\\Scripts\\UI\\?.lua;'

    local require        = base.require
    local lfs            = require('lfs')
    local DCS            = require('DCS')
    local DialogLoader   = require('DialogLoader')
    local Skin           = require('Skin')
    local Gui            = require('dxgui')
    local net            = base.net
    local log            = base.log
    local io             = base.io

    local function logInfo(msg)
        log.write('CarrierGUI', log.INFO, tostring(msg))
    end
    local function logErr(msg)
        log.write('CarrierGUI', log.ERROR, tostring(msg))
    end

    -- --------------------------------------------------------- flag dispatch --
    -- Gotcha #1: when embedding inner string.format inside the chunk, double '%'.
    -- This chunk has no inner format so plain quoting is fine.
    local function fireFlag(flagNum)
        local chunk = string.format('trigger.action.setUserFlag("%d", true)', flagNum)
        local ok, err = base.pcall(function() net.dostring_in('server', chunk) end)
        if not ok then logErr('fireFlag(' .. tostring(flagNum) .. ') failed: ' .. tostring(err))
        else            logInfo('fireFlag ' .. tostring(flagNum)) end
    end

    -- ---------------------------------------------------------- state ---------
    local carrier = {
        window           = nil,
        visible          = false,
        windowCreated    = false,
        showX            = 200,
        showY            = 100,
        bridgeProbeAt    = nil,   -- absolute time to probe bridge flag
        bridgeStatus     = '?',   -- 'ok' | 'missing' | '?'
        tab              = 'carrier',
        marshalFlights   = 1,     -- stepper: # of flights in the marshal stack
        charlieMin       = 15,    -- stepper: minutes to Charlie / push
        nvgGain          = 0,     -- LSO tab NVG gain, 0..100 (percent)
        -- v1.1 LSO additions:
        foulDeck         = false, -- DECK STATUS toggle
        desiredWire      = 3,     -- WIRE TARGET: 1..4 (3-wire is the standard)
        platZoom         = 0,     -- PLAT ZOOM index 0..3 → WIDE/MED/TIGHT/TELE
        shipHdg          = nil,   -- live, from bridge state file
        shipWindFrom     = nil,
        shipWindKts      = nil,
        shipHeadKts      = nil,
        shipCrossKts     = nil,
        shipStateReadAt  = nil,   -- last poll time
    }

    -- button child name -> flag number (simple fire-and-forget buttons)
    local BUTTON_FLAGS = {
        btnLightsOff      = 10,
        btnLightsAuto     = 11,
        btnLightsNav      = 12,
        btnLightsLaunch   = 13,
        btnLightsRecovery = 14,
        btnTacanOff       = 1,
        btnTacanOn        = 2,
        btnIclsOff        = 3,
        btnIclsOn         = 4,
        btnLink4Off       = 5,
        btnLink4On        = 6,
        btnAclsOff        = 7,
        btnAclsOn         = 8,
        btnWindStop       = 100,
        btnWind30m        = 101,
        btnWind60m        = 102,
        btnWind90m        = 103,
        btnWind2h         = 104,
        btnWind4h         = 105,
        btnWind8h         = 106,
        -- Marshall tab: recovery CASE broadcasts
        btnCase1          = 202,
        btnCase2          = 203,
        btnCase3          = 204,
        -- LSO calls (v1.3: WAVE OFF + CUT only; Bingo/RecovOK retired)
        btnWaveOff        = 210,
        btnCut            = 211,
    }

    -- Which dialog children belong to which tab (for show/hide). The two tab
    -- buttons and the status line stay visible on both tabs.
    local CARRIER_WIDGETS = {
        'lblLights','btnLightsOff','btnLightsAuto','btnLightsNav','btnLightsLaunch',
        'btnLightsRecovery','lblTacan','btnTacanOn','btnTacanOff','lblIcls',
        'btnIclsOn','btnIclsOff','lblLink4','btnLink4On','btnLink4Off','lblAcls',
        'btnAclsOn','btnAclsOff','lblWind','btnWindStop','btnWind30m','btnWind60m',
        'btnWind90m','btnWind2h','btnWind4h','btnWind8h',
    }
    -- TOWER: mini overhead + side view radars on top, three roster sections
    -- below, existing broadcast buttons at the bottom.
    local TOWER_WIDGETS = {
        -- Mini overhead radar
        'lblTwrOhHdr','lblTwrOhN','lblTwrOhE','lblTwrOhS','lblTwrOhW','lblTwrOhCv',
        'twrOh1','twrOh2','twrOh3','twrOh4','twrOh5','twrOh6','twrOh7','twrOh8','twrOh9','twrOh10',
        -- Mini side view
        'lblTwrSvHdr','lblTwrSvA15','lblTwrSvA12','lblTwrSvA9','lblTwrSvA6','lblTwrSvA3',
        'twrSv1','twrSv2','twrSv3','twrSv4','twrSv5','twrSv6','twrSv7','twrSv8','twrSv9','twrSv10',
        -- STACK roster
        'lblTwrStackHdr','lblTwrStackCols',
        'rowTwrStack1','rowTwrStack2','rowTwrStack3','rowTwrStack4',
        'rowTwrStack5','rowTwrStack6','rowTwrStack7','rowTwrStack8',
        -- CHARLIE'D roster
        'lblTwrCharlieHdr','lblTwrCharlieCols',
        'rowTwrCharlie1','rowTwrCharlie2','rowTwrCharlie3','rowTwrCharlie4','rowTwrCharlie5',
        -- COMMENCING roster
        'lblTwrCommHdr','lblTwrCommCols',
        'rowTwrComm1','rowTwrComm2','rowTwrComm3','rowTwrComm4','rowTwrComm5',
        -- Existing broadcast buttons (CASE / stack / Charlie)
        'lblMarCase','btnCase1','btnCase2','btnCase3','lblMarStack','lblFlightsCap',
        'btnFlightsDown','lblFlightsVal','btnFlightsUp','btnMarshalBroadcast',
        'lblMarCharlie','lblCharlieCap','btnCharlieDown','lblCharlieVal',
        'btnCharlieUp','btnCharlieBroadcast',
    }
    -- MARSHALL: 60nm CCZ scatter view + radio readout below.
    local MARSHALL_WIDGETS = {
        'lblMarshallHdr',
        'lblCczN60','lblCczN30','lblCczS30','lblCczS60','lblCczW60','lblCczE60','lblCczCv',
        'rowCcz1','rowCcz2','rowCcz3','rowCcz4','rowCcz5','rowCcz6',
        'rowCcz7','rowCcz8','rowCcz9','rowCcz10','rowCcz11','rowCcz12',
        'lblMarRadioHdr','lblMarRadioBase','lblMarRadioCols',
        'rowMarCall1','rowMarCall2','rowMarCall3','rowMarCall4','rowMarCall5','rowMarCall6',
        'rowMarCall7','rowMarCall8','rowMarCall9','rowMarCall10','rowMarCall11','rowMarCall12',
        'lblMarStatus',
    }
    -- DECKBOSS: rotated top-down view with box-drawn outline + zone labels +
    -- modex slot pool + ON DECK list + conga toggle.
    local DECKBOSS_WIDGETS = {
        'lblDbHdr',
        -- Outline (bow / port / stbd / stern edges)
        'lblDbBowH1','lblDbBowH2','lblDbBowH3','lblDbBowH4','lblDbBowH5',
        'lblDbBowH6','lblDbBowH7','lblDbBowH8','lblDbBowH9',
        'lblDbPortV1','lblDbPortV2','lblDbPortV3','lblDbPortV4','lblDbPortV5','lblDbPortV6',
        'lblDbPortV7','lblDbPortV8','lblDbPortV9','lblDbPortV10','lblDbPortV11','lblDbPortV12',
        'lblDbStbdV1','lblDbStbdV2','lblDbStbdV3','lblDbStbdV4','lblDbStbdV5','lblDbStbdV6',
        'lblDbStbdV7','lblDbStbdV8','lblDbStbdV9','lblDbStbdV10','lblDbStbdV11','lblDbStbdV12',
        'lblDbStnH1','lblDbStnH2','lblDbStnH3','lblDbStnH4','lblDbStnH5',
        'lblDbStnH6','lblDbStnH7','lblDbStnH8','lblDbStnH9',
        -- Zone landmarks
        'lblDbBow','lblDbCat1','lblDbCat2','lblDbCat3','lblDbCat4',
        'lblDbIsland','lblDb6pk','lblDbWaist',
        'lblDbElev1','lblDbElev2','lblDbElev3','lblDbElev4',
        'lblDbJunk','lblDbStern',
        -- Aircraft slot pool
        'spotDb1','spotDb2','spotDb3','spotDb4','spotDb5','spotDb6','spotDb7','spotDb8',
        'spotDb9','spotDb10','spotDb11','spotDb12','spotDb13','spotDb14','spotDb15','spotDb16',
        -- On-deck list
        'lblDbOnDeckHdr','lblDbOnDeckCols',
        'rowDbOnDeck1','rowDbOnDeck2','rowDbOnDeck3','rowDbOnDeck4','rowDbOnDeck5',
        'rowDbOnDeck6','rowDbOnDeck7','rowDbOnDeck8','rowDbOnDeck9','rowDbOnDeck10',
        -- Conga toggle
        'lblDbCongaState','btnDbConga','lblDbCongaHint',
    }
    -- LSO: racetrack visual (landmarks + outline + aircraft slot pool) +
    -- lights + PLAT cam (NVG / RESET CAM only) + ship + events.
    local LSO_WIDGETS = {
        'lblPatHdr',
        -- Racetrack landmarks
        'lblPatInitial','lblPatBreak','lblPatDwnwd','lblPatAbeam',
        'lblPat180','lblPat90','lblPatGroove','lblPatTrap','lblPatCv',
        -- Racetrack outline (V = vertical edge, H = horizontal edge)
        'lblPatV1','lblPatV2','lblPatV3','lblPatV4','lblPatV5','lblPatV6',
        'lblPatV7','lblPatV8','lblPatV9','lblPatV10','lblPatV11','lblPatV12',
        'lblPatH1','lblPatH2','lblPatH3','lblPatH4','lblPatH5',
        'lblPatH6','lblPatH7','lblPatH8','lblPatH9','lblPatH10',
        -- Aircraft slot pool
        'acftPat1','acftPat2','acftPat3','acftPat4','acftPat5','acftPat6','acftPat7','acftPat8',
        -- LSO lights
        'lblLightsHdr','btnWaveOff','btnCut',
        -- PLAT camera
        'lblLsoNvg', 'btnResetCam', 'lblNvgVal',
        'ledNvg1','ledNvg2','ledNvg3','ledNvg4','ledNvg5',
        'ledNvg6','ledNvg7','ledNvg8','ledNvg9','ledNvg10',
        'lblTick0','lblTick50','lblTick100',
        -- SHIP + EVENTS readout
        'lblShipHdr', 'lblShipHdg', 'lblShipWind',
        'lblEventsHdr', 'lblEvent1', 'lblEvent2', 'lblEvent3',
        'lblNvgState',
    }

    -- v1.3-beta9: register the drawn-scope widgets (solid fills, rings,
    -- lines, arcs) with their tabs so they hide on tab switch.  Stale beta8
    -- names still present in the literal lists above are harmless —
    -- setWidgetVisible no-ops on missing children.  c.bgPanel (the whole-
    -- panel dark backdrop) is deliberately in NO list: always visible.
    local function addAll(list, names)
        for _, n in base.ipairs(names) do table.insert(list, n) end
    end
    addAll(MARSHALL_WIDGETS, {
        'mScope','mBordT','mBordB','mBordL','mBordR','mAxisH','mAxisV','mShip'})
    for i = 1, 12 do table.insert(MARSHALL_WIDGETS, 'mRingA' .. i) end
    for i = 1, 16 do table.insert(MARSHALL_WIDGETS, 'mRingB' .. i) end
    for i = 1, 20 do table.insert(MARSHALL_WIDGETS, 'mRingC' .. i) end
    addAll(TOWER_WIDGETS, {
        'tScopeL','tBordLT','tBordLB','tBordLL','tBordLR','tAxH','tAxV','tShip',
        'tScopeR','tBordRT','tBordRB','tBordRL','tBordRR',
        'tGrid1','tGrid2','tGrid3','tGrid4','tGrid5'})
    for i = 1, 10 do table.insert(TOWER_WIDGETS, 'tRingA' .. i) end
    for i = 1, 14 do table.insert(TOWER_WIDGETS, 'tRingB' .. i) end
    addAll(LSO_WIDGETS, {
        'pScope','pBordT','pBordB','pBordL','pBordR',
        'pLegR','pLegT','pLegL','pLegB','pShip',
        'pArcTL1','pArcTL2','pArcTL3','pArcTL4',
        'pArcBL1','pArcBL2','pArcBL3','pArcBL4'})
    addAll(DECKBOSS_WIDGETS, {
        'dbDeck','dbStrip','dbEdgeT','dbEdgeB','dbEdgeL','dbEdgeR',
        'dbCat1','dbCat2','dbCat3','dbCat4','dbIslandF',
        'dbEl1','dbEl2','dbEl3','dbEl4'})

    -- Skins for the LED bar segments. setSkin(table) on a Static accepts a
    -- table in this shape. LIT = bright NVG green, DIM = near-black so the
    -- unlit cells fade into the panel background.
    local function makeLedSkin(color)
        return {
            params = { name = 'staticSkin', textWrapping = false },
            states = {
                released = {
                    [1] = {
                        text = {
                            color      = color,
                            font       = 'DejaVuLGCSansCondensed-Bold.ttf',
                            lineHeight = 32,
                        },
                    },
                },
            },
        }
    end
    local LED_SKIN_LIT = makeLedSkin('0x60ff80ff')
    local LED_SKIN_DIM = makeLedSkin('0x202020ff')

    -- --------------------------------------------------------- show / hide ---
    -- Gotcha #4: setVisible(false) destroys the dialog. We toggle visibility
    -- via the SRS-style pattern: real setVisible(true), then either setSize(0,0)
    -- (= hidden) or restore to full size.
    local FULL_W, FULL_H = 540, 900   -- v1.3-beta9: bumped for radar overlays

    -- Set a value-flag (used to pass numeric params like flight count / minutes
    -- to the bridge before firing the action flag).
    local function setFlagValue(name, val)
        local chunk = string.format('trigger.action.setUserFlag("%s", %d)', name, val)
        base.pcall(function() net.dostring_in('server', chunk) end)
    end

    local function show()
        if not carrier.window then return end
        carrier.window:setSize(FULL_W, FULL_H)
        carrier.window:setHasCursor(true)
        carrier.window:setVisible(true)
        carrier.visible = true
    end

    local function hide()
        if not carrier.window then return end
        carrier.window:setSize(0, 0)
        carrier.window:setHasCursor(false)
        carrier.window:setVisible(true)   -- IMPORTANT: keep true; size=0 hides it
        carrier.visible = false
    end

    local function toggle()
        if carrier.visible then hide() else show() end
        logInfo('toggle -> ' .. tostring(carrier.visible))
    end

    -- ------------------------------------------------------ tab switching ---
    local function setWidgetVisible(name, vis)
        local w = carrier.window and carrier.window[name]
        if w then base.pcall(function() w:setVisible(vis) end) end
    end

    local function showTab(tab)
        carrier.tab = tab
        local carrierVis  = (tab == 'carrier')
        local marshallVis = (tab == 'marshall')
        local towerVis    = (tab == 'tower')
        local lsoVis      = (tab == 'lso')
        local deckbossVis = (tab == 'deckboss')
        for _, n in base.ipairs(CARRIER_WIDGETS)  do setWidgetVisible(n, carrierVis)  end
        for _, n in base.ipairs(MARSHALL_WIDGETS) do setWidgetVisible(n, marshallVis) end
        for _, n in base.ipairs(TOWER_WIDGETS)    do setWidgetVisible(n, towerVis)    end
        for _, n in base.ipairs(LSO_WIDGETS)      do setWidgetVisible(n, lsoVis)      end
        for _, n in base.ipairs(DECKBOSS_WIDGETS) do setWidgetVisible(n, deckbossVis) end
        logInfo('tab -> ' .. tab)
    end

    -- ------------------------------------------------------ PLAT-cam NVG IPC ---
    -- We write the NVG gain as a percent ("0".."100") to Saved Games\DCS\
    -- carriergui_nvg.txt. The patched PLATCameraUI.lua reads it each frame
    -- and sets the PLAT widget color's ALPHA byte accordingly — the patched
    -- gui.fx then uses that alpha as a lerp mixer between the normal feed
    -- and the NVG-amplified output. 0% = normal feed, 100% = full NVG.
    -- File IPC because the SC dxgui dialog runs in a different Lua state.
    local NVG_FILE = 'carriergui_nvg.txt'

    local function writeNvgState()
        local path = lfs.writedir() .. NVG_FILE
        local ok, err = base.pcall(function()
            local f = io.open(path, 'w')
            if f then
                f:write(tostring(carrier.nvgGain))
                f:close()
            end
        end)
        if not ok then logErr('NVG file write failed: ' .. tostring(err)) end
    end

    local function updateNvgDisplay()
        if not carrier.window then return end
        local g = carrier.nvgGain
        -- Big centre readout: "OFF" at zero, "NN%" otherwise.
        if carrier.window.lblNvgVal then
            local txt = (g <= 0) and 'OFF' or (tostring(g) .. '%')
            base.pcall(function() carrier.window.lblNvgVal:setText(txt) end)
        end
        -- 10 LED bar segments. Segment N (1..10) lit IFF gain >= N*10.
        for i = 1, 10 do
            local led = carrier.window['ledNvg' .. i]
            if led then
                local skin = (g >= i * 10) and LED_SKIN_LIT or LED_SKIN_DIM
                base.pcall(function() led:setSkin(skin) end)
            end
        end
        -- lblNvgState is now the shared LSO-tab status line; the bridge-probe
        -- handler drives it. NVG status is conveyed by the big readout text.
    end

    -- =====================================================================
    -- v1.1 LSO additions: DECK / WIRE / ZOOM file IPC + ship status read
    -- =====================================================================

    -- File names under lfs.writedir(). The patched PLATCameraUI reads these
    -- each frame and calls the appropriate Supercarrier function (setFoulDeck,
    -- setDesiredRope, adjustGate). The hook also reads carriergui_shipstate.txt
    -- (written by the bridge) for the live HDG / wind readouts.
    local FOUL_FILE       = 'carriergui_foul.txt'
    local WIRE_FILE       = 'carriergui_wire.txt'
    local ZOOM_FILE       = 'carriergui_zoom.txt'
    local SHIPSTATE_FILE  = 'carriergui_shipstate.txt'

    -- PLAT FOV table for the zoom stepper. Index 0 = "DEFAULT" = let DCS's
    -- own dynamic zoom run (the patched lua skips adjustGate when fov=0).
    -- Indices 1..3 override with progressively narrower FOVs.
    local ZOOM_LEVELS = {
        [0] = {label = 'DEFAULT', fov =  0},  -- 0 = no override; DCS controls
        [1] = {label = 'MED',     fov = 30},
        [2] = {label = 'TIGHT',   fov = 18},
        [3] = {label = 'TELE',    fov = 10},
    }

    local function writeStateFile(name, body)
        local path = lfs.writedir() .. name
        local ok, err = base.pcall(function()
            local f = io.open(path, 'w')
            if f then f:write(body); f:close() end
        end)
        if not ok then logErr(name .. ' write failed: ' .. tostring(err)) end
    end

    local function writeFoulState()
        writeStateFile(FOUL_FILE, carrier.foulDeck and '1' or '0')
    end
    local function writeWireState()
        writeStateFile(WIRE_FILE, tostring(carrier.desiredWire))
    end
    local function writeZoomState()
        local lvl = ZOOM_LEVELS[carrier.platZoom] or ZOOM_LEVELS[0]
        writeStateFile(ZOOM_FILE, tostring(lvl.fov))
    end

    -- v1.3: WIRE / DECK / ZOOM buttons were retired (they didn't reliably
    -- drive in-game state).  This function is a no-op kept so the few
    -- legacy call sites (RESET CAM, initial setup) don't have to be
    -- surgically edited.
    local function updateLsoDisplay() end

    -- Ship state reader. The bridge writes carriergui_shipstate.txt with
    -- key=value lines every ~1s. The hook reads it on the same cadence and
    -- updates the SHIP readout labels.
    local function parseShipState(text)
        local s = {}
        for line in text:gmatch('[^\r\n]+') do
            local k, v = line:match('^(%w+)=(.+)$')
            if k then s[k] = v end
        end
        return s
    end

    local function readShipState()
        -- v1.3-beta9: primary source is the mission query (carrier.q.ship);
        -- the bridge file only exists on desanitized servers.
        local content = (carrier.q and carrier.q.ship) or ''
        if content == '' then
            local ok, c = base.pcall(function()
                local f = io.open(lfs.writedir() .. SHIPSTATE_FILE, 'r')
                if not f then return nil end
                local t = f:read('*a')
                f:close()
                return t
            end)
            if ok and c then content = c end
        end
        if content == '' then return end
        local s = parseShipState(content)
        carrier.shipHdg       = tonumber(s.hdg)
        carrier.shipWindFrom  = tonumber(s.wind_from)
        carrier.shipWindKts   = tonumber(s.wind_kts)
        carrier.shipHeadKts   = tonumber(s.head_kts)
        carrier.shipCrossKts  = tonumber(s.cross_kts)
        if not carrier.window then return end
        if carrier.window.lblShipHdg then
            local txt = carrier.shipHdg and ('HDG: ' .. carrier.shipHdg .. '°') or 'HDG: --'
            base.pcall(function() carrier.window.lblShipHdg:setText(txt) end)
        end
        if carrier.window.lblShipWind then
            local txt = 'Wind: --'
            if carrier.shipWindFrom and carrier.shipWindKts then
                txt = string.format('Wind %03d/%d  (%dH/%dX)',
                    carrier.shipWindFrom, carrier.shipWindKts,
                    carrier.shipHeadKts or 0, carrier.shipCrossKts or 0)
            end
            base.pcall(function() carrier.window.lblShipWind:setText(txt) end)
        end
    end

    -- Recovery events tailing: read carriergui_lso_events.txt (bridge appends
    -- when inbound aircraft cross CASE III milestones) and show last 3 lines.
    local LSO_EVENTS_FILE = 'carriergui_lso_events.txt'

    local function readLsoEvents()
        local path = lfs.writedir() .. LSO_EVENTS_FILE
        local ok, content = base.pcall(function()
            local f = io.open(path, 'r')
            if not f then return nil end
            local c = f:read('*a')
            f:close()
            return c
        end)
        if not ok or not content or content == '' then return end
        local lines = {}
        for line in content:gmatch('[^\r\n]+') do
            table.insert(lines, line)
        end
        if #lines == 0 then return end
        -- Take last 3 (most-recent at the bottom of the file).
        local last3 = { '', '', '' }
        local idx = 1
        for i = math.max(1, #lines - 2), #lines do
            last3[idx] = lines[i] or ''
            idx = idx + 1
        end
        if not carrier.window then return end
        for i = 1, 3 do
            local w = carrier.window['lblEvent' .. i]
            if w then base.pcall(function() w:setText(last3[i]) end) end
        end
    end

    -- =====================================================================
    -- v1.3-beta9: MISSION QUERY — the hook pulls all live data itself via
    -- net.dostring_in('server', chunk).  Field debugging found DCS's default
    -- MissionScripting.lua sanitizes io/lfs/os in the mission env, so the
    -- bridge can NEVER write IPC files on a stock install — every
    -- bridge→file→hook feature was silently dead.  dostring_in returns the
    -- data as a string instead: no file I/O in the sanitized env, and the
    -- radar/roster feeds no longer require a patched mission at all.
    -- The bridge file-writers remain for desanitized dedicated servers;
    -- readers below fall back to the files when the query returns nothing.
    --
    -- The chunk persists tracking state in the mission env via __CGQ
    -- (first-seen times, Charlie/commence marks, modex map from
    -- env.mission onboard_num — the ME "Tail #" field).
    -- Returns 5 sections joined by '\n@@\n': SHIP / STACK / CCZ / PATTERN / DECK.
    local CG_QUERY = [==[
local okQ, resQ = pcall(function()
    __CGQ = __CGQ or { fs = {}, ln = {}, ch = {}, co = {} }
    local Q = __CGQ
    local NM = 1852.0

    -- one-time modex map: unit name -> ME Tail# (onboard_num)
    if not Q.mx then
        Q.mx = {}
        pcall(function()
            for _, coa in pairs(env.mission.coalition) do
                if type(coa) == 'table' and coa.country then
                    for _, ctry in pairs(coa.country) do
                        for _, cat in pairs({'plane', 'helicopter'}) do
                            if ctry[cat] and ctry[cat].group then
                                for _, grp in pairs(ctry[cat].group) do
                                    for _, un in pairs(grp.units or {}) do
                                        if un.name and un.onboard_num then
                                            local nm = env.getValueDictByKey(un.name)
                                            Q.mx[nm] = tostring(un.onboard_num)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
    end

    local function norm(a) a = a % 360 if a < 0 then a = a + 360 end return a end
    local function angDelta(a, b) return (a - b + 540) % 360 - 180 end

    -- find first CVN
    local carrier = nil
    for _, side in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
        local groups = coalition.getGroups(side, Group.Category.SHIP)
        if groups then
            for _, g in pairs(groups) do
                if g:isExist() then
                    for _, u in pairs(g:getUnits() or {}) do
                        if u:isExist() then
                            local tn = u:getTypeName() or ''
                            if tn:find('CVN') or tn:find('Stennis') or tn:find('VINSON') or tn:find('Forrestal') then
                                carrier = u
                                break
                            end
                        end
                    end
                end
                if carrier then break end
            end
        end
        if carrier then break end
    end
    if not carrier then return '\n@@\n\n@@\n\n@@\n\n@@\n' end

    local cp  = carrier:getPoint()
    local cpx = carrier:getPosition().x
    -- DCS convention: +x = north, +z = east.  hdg = atan2(east, north).
    local hdg = norm(math.deg(math.atan2(cpx.z, cpx.x)))
    local fb  = norm(hdg - 9)   -- CVN angled deck

    -- wind at deck height
    local shipLines = {}
    pcall(function()
        local w = atmosphere.getWind({x = cp.x, y = cp.y + 20, z = cp.z})
        local wspd = math.sqrt(w.x * w.x + w.z * w.z)
        local wfrom = norm(math.deg(math.atan2(w.z, w.x)) + 180)
        local vel = carrier:getVelocity()
        local relx = w.x - vel.x
        local relz = w.z - vel.z
        -- decompose relative wind onto ship axes
        local fwd = relx * cpx.x + relz * cpx.z
        local crs = relx * (-cpx.z) + relz * cpx.x
        shipLines[1] = 'hdg=' .. math.floor(hdg + 0.5)
        shipLines[2] = 'wind_from=' .. math.floor(wfrom + 0.5)
        shipLines[3] = 'wind_kts=' .. math.floor(wspd * 1.94384 + 0.5)
        shipLines[4] = 'head_kts=' .. math.floor(-fwd * 1.94384 + 0.5)
        shipLines[5] = 'cross_kts=' .. math.floor(crs * 1.94384 + 0.5)
    end)
    if not shipLines[1] then shipLines[1] = 'hdg=' .. math.floor(hdg + 0.5) end

    local stack, ccz, pattern, deck = {}, {}, {}, {}
    local now = timer.getTime()
    local seen = {}

    for _, side in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
        local groups = coalition.getGroups(side, Group.Category.AIRPLANE)
        if groups then
            for _, g in pairs(groups) do
                if g:isExist() then
                    for _, u in pairs(g:getUnits() or {}) do
                        pcall(function()
                            if not u:isExist() then return end
                            local name = u:getName() or ''
                            local modex = Q.mx[name] or name:match('(%d+)%s*$') or name
                            if modex == '' then return end

                            local up = u:getPoint()
                            local dx, dz = up.x - cp.x, up.z - cp.z
                            local nm  = math.sqrt(dx * dx + dz * dz) / NM
                            local brg = norm(math.deg(math.atan2(dz, dx)))
                            local altM = up.y
                            local altFt = math.floor(altM * 3.28084)
                            local vel = u:getVelocity()
                            local ias = math.floor(math.sqrt(vel.x * vel.x + vel.z * vel.z) * 1.94384)
                            local inAir = u:inAir()

                            seen[modex] = true
                            if not Q.fs[modex] then Q.fs[modex] = now end
                            local inT = math.floor(now - Q.fs[modex])

                            local lastNm = Q.ln[modex] or nm
                            local closing = (nm < lastNm - 0.05)
                            Q.ln[modex] = nm

                            if (not inAir) and nm < 0.5 then
                                -- on deck: carrier-frame offset (along nose, across to stbd)
                                local along  = dx * cpx.x + dz * cpx.z
                                local across = dx * (-cpx.z) + dz * cpx.x
                                deck[#deck + 1] = modex .. '|' .. math.floor(along + 0.5) .. '|' .. math.floor(across + 0.5)
                                return
                            end
                            if not inAir then return end

                            -- CASE I pattern point classification
                            local point = 'enroute'
                            if nm <= 5 then
                                local initBrg = norm(fb + 180)
                                local portBrg = norm(fb + 270)
                                if nm < 0.8 then point = 'BREAK'
                                elseif math.abs(angDelta(brg, initBrg)) < 25 and nm > 1 and nm < 4 and altM < 400 then
                                    point = 'INITIAL'
                                elseif math.abs(angDelta(brg, portBrg)) < 35 and nm < 3 then
                                    if altM > 200 and not closing then point = 'DOWNWIND'
                                    elseif altM > 120 then point = 'ABEAM'
                                    else point = '180' end
                                elseif nm < 1.5 and altM < 180 and closing then
                                    point = 'GROOVE'
                                else
                                    point = 'pattern'
                                end
                            end

                            -- HOLD / CHARLIE / COMMENCING state machine
                            local state = 'HOLD'
                            if Q.co[modex] then state = 'COMMENCING'
                            elseif altM < 250 and nm < 3 and closing then
                                Q.co[modex] = true
                                state = 'COMMENCING'
                            elseif Q.ch[modex] then state = 'CHARLIE' end

                            if nm < 25 then
                                stack[#stack + 1] = modex .. '|' .. altFt .. '|' .. ias .. '|' .. inT .. '|' .. point .. '|' .. state
                            end
                            if nm < 60 and nm > 8 then
                                ccz[#ccz + 1] = string.format('%s|%d|%.1f|%d|%d|inbound', modex, math.floor(brg + 0.5), nm, altFt, ias)
                            end
                            if nm < 5 then
                                pattern[#pattern + 1] = modex .. '|' .. altFt .. '|' .. ias .. '|0|' .. point
                            end
                        end)
                    end
                end
            end
        end
    end

    -- GC stale modexes
    for m in pairs(Q.fs) do
        if not seen[m] then Q.fs[m] = nil Q.ln[m] = nil Q.ch[m] = nil Q.co[m] = nil end
    end

    return table.concat(shipLines, '\n') .. '\n@@\n' ..
           table.concat(stack, '\n')     .. '\n@@\n' ..
           table.concat(ccz, '\n')       .. '\n@@\n' ..
           table.concat(pattern, '\n')   .. '\n@@\n' ..
           table.concat(deck, '\n')
end)
if okQ then return resQ end
return 'ERR|' .. tostring(resQ)
]==]

    -- Query results cache, refreshed at 1 Hz by runMissionQuery().
    carrier.q = { ship = '', stack = '', ccz = '', pattern = '', deck = '' }

    local function runMissionQuery()
        local ok, res = base.pcall(function()
            return net.dostring_in('server', CG_QUERY)
        end)
        if not ok or type(res) ~= 'string' or res == '' then return end
        if res:sub(1, 4) == 'ERR|' then
            logErr('mission query failed: ' .. res:sub(5, 200))
            return
        end
        local parts = {}
        for s in (res .. '\n@@\n'):gmatch('(.-)\n@@\n') do
            table.insert(parts, s)
        end
        carrier.q.ship    = parts[1] or ''
        carrier.q.stack   = parts[2] or ''
        carrier.q.ccz     = parts[3] or ''
        carrier.q.pattern = parts[4] or ''
        carrier.q.deck    = parts[5] or ''
    end

    -- =====================================================================
    -- v1.3 data readers — feed TOWER / MARSHALL / LSO / DECKBOSS tabs.
    -- Primary source: the mission query above.  Fallback: bridge-written
    -- files (only exist on desanitized dedicated servers).
    -- =====================================================================
    local STACK_FILE_V13   = 'carriergui_stack.txt'
    local CCZ_FILE_V13     = 'carriergui_ccz.txt'
    local PATTERN_FILE_V13 = 'carriergui_pattern.txt'
    local DECK_FILE_V13    = 'carriergui_deck.txt'

    local function slurp(name)
        local path = lfs.writedir() .. name
        local ok, content = base.pcall(function()
            local f = io.open(path, 'r')
            if not f then return '' end
            local c = f:read('*a')
            f:close()
            return c or ''
        end)
        if not ok then return '' end
        return content
    end

    local function setText(name, text)
        local w = carrier.window and carrier.window[name]
        if w then base.pcall(function() w:setText(text) end) end
    end

    local function setBounds(name, x, y, w, h)
        local widg = carrier.window and carrier.window[name]
        if widg then base.pcall(function() widg:setBounds(x, y, w, h) end) end
    end

    local function fmtTime(sec)
        return string.format('%02d:%02d', math.floor(sec / 60), sec % 60)
    end

    -- ─── TOWER stack roster + mini overhead/side radars ──────────────────
    -- Stack file format includes ALT/IAS/POINT/STATE.  v1.3-beta9 also
    -- positions twrOh* (overhead scatter) and twrSv* (side-view scatter)
    -- using a separate parse that grabs BRG too — bridge writes BRG/NM in
    -- the carriergui_ccz.txt format inside 25 nm.  For now we approximate
    -- overhead position from the LAST PT (since stack.txt doesn't carry
    -- BRG/NM).  TODO: bridge could be extended to write BRG into stack.txt.
    local function readStackState()
        local content = (carrier.q and carrier.q.stack) or ''
        if content == '' then content = slurp(STACK_FILE_V13) end
        local hold, charlie, commence = {}, {}, {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, alt, ias, inT, pt, state =
                line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]+)|([^|]+)')
            if modex then
                local r = { modex = modex, alt = tonumber(alt) or 0,
                            ias = tonumber(ias) or 0, inT = tonumber(inT) or 0,
                            pt = pt, state = state }
                if state == 'CHARLIE' then        table.insert(charlie,  r)
                elseif state == 'COMMENCING' then table.insert(commence, r)
                else                              table.insert(hold,     r) end
            end
        end
        local byAlt = function(a, b) return a.alt > b.alt end
        table.sort(hold,     byAlt)
        table.sort(charlie,  byAlt)
        table.sort(commence, byAlt)

        local function rowStr(r, i)
            return string.format('  %d  %-3s   %5d ft  %3d kt  %s   %s',
                i, r.modex, r.alt, r.ias, fmtTime(r.inT), r.pt)
        end
        local function fillRows(rows, prefix, max)
            for i = 1, max do
                local r = rows[i]
                setText(prefix .. i, r and rowStr(r, i) or '')
            end
        end
        fillRows(hold,     'rowTwrStack',   8)
        fillRows(charlie,  'rowTwrCharlie', 5)
        fillRows(commence, 'rowTwrComm',    5)

        -- Side-view scatter: x slot by index, y by altitude.
        -- v1.3-beta9: mapped onto the drawn gridlines — 15k → y=56, 0 → y=152.
        local allAir = {}
        for _, r in base.ipairs(hold)     do table.insert(allAir, r) end
        for _, r in base.ipairs(charlie)  do table.insert(allAir, r) end
        for _, r in base.ipairs(commence) do table.insert(allAir, r) end
        for i = 1, 10 do
            local r = allAir[i]
            if r then
                local altClamped = r.alt
                if altClamped > 15000 then altClamped = 15000 end
                if altClamped < 0     then altClamped = 0 end
                local y = math.floor(56 + (15000 - altClamped) * (96 / 15000))
                local x = 330 + ((i - 1) % 6) * 30
                setText('twrSv' .. i, r.modex)
                setBounds('twrSv' .. i, x, y, 40, 14)
            else
                setText('twrSv' .. i, '')
                setBounds('twrSv' .. i, -200, -200, 40, 14)
            end
        end

        -- Overhead scatter — stack.txt has no BRG so we approximate from
        -- LAST PT: sketch x/y around the drawn scope centre (130, 103).
        local ohXYByPoint = {
            INITIAL  = { 160, 148 },
            BREAK    = { 130,  88 },
            DOWNWIND = {  80,  90 },
            ABEAM    = {  80, 112 },
            ['180']  = {  85, 140 },
            GROOVE   = { 112, 110 },
            TRAP     = { 132, 100 },
            enroute  = { 205, 150 },   -- off-pattern (corner)
            pattern  = { 100, 128 },
        }
        local placed = {}
        for i = 1, 10 do
            local r = allAir[i]
            if r then
                local xy = ohXYByPoint[r.pt] or ohXYByPoint.pattern
                -- Stagger labels that share the same point so they don't pile up
                local k = r.pt
                placed[k] = (placed[k] or 0) + 1
                local offY = (placed[k] - 1) * 14
                setText('twrOh' .. i, r.modex)
                setBounds('twrOh' .. i, xy[1], xy[2] + offY, 40, 14)
            else
                setText('twrOh' .. i, '')
                setBounds('twrOh' .. i, -200, -200, 40, 14)
            end
        end
    end

    -- ─── MARSHALL CCZ scatter + radio readout ────────────────────────────
    -- Scatter view: rowCcz1..12 are positioned by (BRG, NM) around a centre
    -- at (270, 190) with 60 nm = 110 px radius scale.  Beta6 replaced the
    -- text list with the scatter — radio readout still uses rowMarCall*.
    local function readCczState()
        local content = (carrier.q and carrier.q.ccz) or ''
        if content == '' then content = slurp(CCZ_FILE_V13) end
        local rows = {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, brg, nm, alt, ias =
                line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)')
            if modex then
                table.insert(rows, {
                    modex = modex, brg = tonumber(brg) or 0,
                    nm = tonumber(nm) or 0, alt = tonumber(alt) or 0,
                    ias = tonumber(ias) or 0
                })
            end
        end
        table.sort(rows, function(a, b) return a.nm < b.nm end)

        -- Position scatter slots: x = cx + nm * pxPerNm * sin(brg), y = cy - nm * pxPerNm * cos(brg)
        local cx, cy = 270, 190
        local pxPerNm = 110 / 60
        for i = 1, 12 do
            local r = rows[i]
            if r then
                local brgR = math.rad(r.brg)
                local nmClamp = r.nm
                if nmClamp > 60 then nmClamp = 60 end
                local x = math.floor(cx + nmClamp * pxPerNm * math.sin(brgR) - 20)
                local y = math.floor(cy - nmClamp * pxPerNm * math.cos(brgR) - 8)
                setText('rowCcz' .. i, r.modex)
                setBounds('rowCcz' .. i, x, y, 40, 16)
            else
                setText('rowCcz' .. i, '')
                setBounds('rowCcz' .. i, -200, -200, 40, 16)
            end
        end

        -- Marshal call template: each row pairs the aircraft's BRA with an
        -- assigned stack altitude (6k + slot×1k) and a placeholder EAT.
        for i = 1, 12 do
            local r = rows[i]
            if r then
                local angels = 6 + (i - 1)
                setText('rowMarCall' .. i, string.format(
                    '  %-3s    %3d°  %4.1f nm   %5d    ANGELS %2d    --',
                    r.modex, r.brg, r.nm, r.alt, angels))
            else
                setText('rowMarCall' .. i, '')
            end
        end

        if #rows > 0 then
            setText('lblMarStatus', tostring(#rows) .. ' aircraft in CCZ')
        else
            setText('lblMarStatus', '(waiting for inbound traffic...)')
        end

        local brc = carrier.shipHdg and (tostring(carrier.shipHdg) .. '°') or '---'
        setText('lblMarRadioBase', 'ALT 29.92   BRC ' .. brc .. '   CASE I')
    end

    -- ─── LSO CASE I pattern visual ───────────────────────────────────────
    -- v1.3-beta9: aircraft slots (acftPat1..8) get repositioned to the
    -- landmark coords for whichever pattern point the bridge classified
    -- them at.  Multiple aircraft at the same point stack vertically.
    -- v1.3-beta9: coordinates sit ON the drawn racetrack (legs at x=140/400,
    -- y=55/260; ship at the top of the right leg).
    local PATTERN_XY = {
        INITIAL  = { 355, 220 },
        BREAK    = { 355,  62 },
        DOWNWIND = { 148, 105 },
        ABEAM    = { 148, 158 },
        ['180']  = { 150, 222 },
        GROOVE   = { 305, 150 },
        TRAP     = { 358,  85 },
    }
    local function readPatternState()
        local content = (carrier.q and carrier.q.pattern) or ''
        if content == '' then content = slurp(PATTERN_FILE_V13) end
        local list = {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, alt, ias, _prog, point =
                line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?[%d%.]+)|([^|]+)')
            if modex then
                table.insert(list, {
                    modex = modex, alt = tonumber(alt) or 0,
                    ias = tonumber(ias) or 0, point = point
                })
            end
        end
        local placed = {}
        for i = 1, 8 do
            local r = list[i]
            if r then
                local xy = PATTERN_XY[r.point]
                if xy then
                    placed[r.point] = (placed[r.point] or 0) + 1
                    local offY = (placed[r.point] - 1) * 16
                    setText('acftPat' .. i, r.modex)
                    setBounds('acftPat' .. i, xy[1], xy[2] + offY, 40, 14)
                else
                    setText('acftPat' .. i, '')
                    setBounds('acftPat' .. i, -200, -200, 40, 14)
                end
            else
                setText('acftPat' .. i, '')
                setBounds('acftPat' .. i, -200, -200, 40, 14)
            end
        end
    end

    -- ─── DECKBOSS top-down deck view ─────────────────────────────────────
    local function readDeckState()
        local content = (carrier.q and carrier.q.deck) or ''
        if content == '' then content = slurp(DECK_FILE_V13) end
        local rows = {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, along, across = line:match('([^|]+)|(%-?%d+)|(%-?%d+)')
            if modex then
                table.insert(rows, {
                    modex = modex, along = tonumber(along) or 0,
                    across = tonumber(across) or 0
                })
            end
        end

        -- ON DECK summary list
        for i = 1, 10 do
            local r = rows[i]
            if r then
                local zone
                if r.along > 80      then zone = 'BOW'
                elseif r.along > -20 then zone = 'WAIST/ISLAND'
                elseif r.along > -90 then zone = '6-PACK'
                else                      zone = 'JUNKYARD' end
                setText('rowDbOnDeck' .. i, string.format(
                    '  %-3s    %+5d m    %+4d m    %s',
                    r.modex, r.along, r.across, zone))
            else
                setText('rowDbOnDeck' .. i, '')
            end
        end

        -- Modex slot positions on the deck silhouette (16 slots).
        -- v1.3-beta9: rotated so BOW is at the TOP of the silhouette.
        --   along  +200 (bow)   → y=70    along -200 (stern) → y=320
        --   across -50 (port)   → x=145   across +50 (stbd)  → x=395
        for i = 1, 16 do
            local r = rows[i]
            if r then
                local a = r.along
                if a >  200 then a =  200 end
                if a < -200 then a = -200 end
                local cc = r.across
                if cc >  50 then cc =  50 end
                if cc < -50 then cc = -50 end
                local y = math.floor(70  + (200 - a) * (250 / 400))
                local x = math.floor(145 + (cc + 50) * (250 / 100))
                setText('spotDb' .. i, r.modex)
                setBounds('spotDb' .. i, x, y, 50, 14)
            else
                setText('spotDb' .. i, '')
                setBounds('spotDb' .. i, -200, -200, 50, 14)
            end
        end
    end

    -- ─── LSO lights (WAVE OFF + CUT latch lit for ~5s after press) ───────
    local lightActiveUntil = { btnWaveOff = 0, btnCut = 0 }
    local function setLightLit(btnName, lit)
        local w = carrier.window and carrier.window[btnName]
        if not w then return end
        if lit then
            base.pcall(function() w:setSkin(LED_SKIN_LIT) end)
        else
            base.pcall(function() w:setSkin({ params = { name = 'buttonSkin' } }) end)
        end
    end
    local function pulseLight(btnName)
        lightActiveUntil[btnName] = (DCS.getRealTime() or 0) + 5
        setLightLit(btnName, true)
    end
    local function updateLights()
        local now = DCS.getRealTime() or 0
        for name, t in base.pairs(lightActiveUntil) do
            if t > 0 and now > t then
                lightActiveUntil[name] = 0
                setLightLit(name, false)
            end
        end
    end

    -- ─── DECKBOSS conga toggle state ─────────────────────────────────────
    local congaOn = false

    -- ------------------------------------------------------ stepper display ---
    local function updateSteppers()
        if not carrier.window then return end
        if carrier.window.lblFlightsVal then
            base.pcall(function()
                carrier.window.lblFlightsVal:setText(tostring(carrier.marshalFlights))
            end)
        end
        if carrier.window.lblCharlieVal then
            base.pcall(function()
                carrier.window.lblCharlieVal:setText(tostring(carrier.charlieMin))
            end)
        end
    end

    -- ------------------------------------------------ bridge-present probe ---
    local function setStatus(text)
        if carrier.window and carrier.window.lblStatus then
            base.pcall(function() carrier.window.lblStatus:setText(text) end)
        end
    end

    local function probeBridge()
        -- Bridge sets user flag 'carriergui_bridge_loaded' to 1 on its first
        -- run. Query it from the hook via net.dostring_in. If '1' -> patched.
        local code = 'return tostring(trigger.misc.getUserFlag("carriergui_bridge_loaded"))'
        local ok, result = base.pcall(function()
            return net.dostring_in('server', code)
        end)
        local function setNvgStateText(t)
            if carrier.window and carrier.window.lblNvgState then
                base.pcall(function() carrier.window.lblNvgState:setText(t) end)
            end
        end
        if ok and tostring(result) == '1' then
            carrier.bridgeStatus = 'ok'
            setStatus('Bridge: online')
            setNvgStateText('Bridge: online')
            logInfo('bridge probe: present')
        else
            carrier.bridgeStatus = 'missing'
            -- v1.3-beta9: radar/roster data comes from the mission query and
            -- works unpatched.  Only the BUTTONS (beacons/wind/lights/
            -- broadcasts) need the embedded bridge.
            setStatus('Mission NOT PATCHED — control buttons will not respond.\n' ..
                     'Displays still work. Patch the .miz to enable buttons.')
            setNvgStateText('Mission not patched (displays OK, buttons dead)')
            logInfo('bridge probe: missing (result=' .. tostring(result) .. ')')
        end
    end

    -- ------------------------------------------------ window construction ---
    -- Wire an arbitrary on-click handler to a button child.
    local function wireClick(name, fn)
        local btn = carrier.window[name]
        if not btn then
            logErr('button ' .. name .. ' not found in dialog')
            return
        end
        -- dxgui Button fires via addChangeCallback on press.
        btn:addChangeCallback(function(self) fn() end)
        -- Mouse-down fallback (some Button skins emit only mouse events).
        if btn.addMouseDownCallback then
            base.pcall(function()
                btn:addMouseDownCallback(function() fn() end)
            end)
        end
    end

    local function wireButton(name, flagNum)
        wireClick(name, function() fireFlag(flagNum) end)
    end

    local function createWindow()
        local dlgPath = lfs.writedir() .. 'Scripts/Hooks/carrier-gui.dlg'
        local ok, winOrErr = base.pcall(function()
            return DialogLoader.spawnDialogFromFile(dlgPath)
        end)
        if not ok or not winOrErr then
            logErr('spawnDialogFromFile failed: ' .. tostring(winOrErr) ..
                   ' (path: ' .. dlgPath .. ')')
            return false
        end
        carrier.window = winOrErr

        -- Gotcha #5: addHotKeyCallback only fully binds after setVisible(true)
        -- has been called at least once. Show, then immediately shrink to hide.
        carrier.window:setBounds(carrier.showX, carrier.showY, FULL_W, FULL_H)
        carrier.window:setVisible(true)

        -- register hotkey now that the window is visible
        local hkOk, hkErr = base.pcall(function()
            carrier.window:addHotKeyCallback('Ctrl+Shift+c', function()
                toggle()
            end)
        end)
        if not hkOk then
            logErr('addHotKeyCallback failed: ' .. tostring(hkErr))
        else
            logInfo('hotkey Ctrl+Shift+c registered')
        end

        -- wire every simple fire-flag button
        for name, flag in base.pairs(BUTTON_FLAGS) do
            wireButton(name, flag)
        end

        -- tab buttons (v1.3-beta9: 5 tabs)
        wireClick('btnTabCarrier',  function() showTab('carrier')  end)
        wireClick('btnTabMarshall', function() showTab('marshall') end)
        wireClick('btnTabTower',    function() showTab('tower')    end)
        wireClick('btnTabLso',      function() showTab('lso')      end)
        wireClick('btnTabDeckboss', function() showTab('deckboss') end)

        -- LSO tab: NVG gain bar gauge
        local function setNvgGain(pct)
            if pct < 0   then pct = 0   end
            if pct > 100 then pct = 100 end
            -- snap to 10% steps
            pct = math.floor(pct / 10 + 0.5) * 10
            if pct == carrier.nvgGain then return end
            carrier.nvgGain = pct
            writeNvgState()
            updateNvgDisplay()
            logInfo('NVG gain -> ' .. pct .. '%')
        end

        -- Mouse wheel: scroll up = +10%, scroll down = -10%. The wheel
        -- callback's arg signature varies across DCS versions; we accept any
        -- non-zero numeric and use its sign.
        local function wheelDelta(...)
            local args = {...}
            for i = #args, 1, -1 do
                local v = args[i]
                if type(v) == 'number' and v ~= 0 then return v end
            end
            return 0
        end
        local function onWheel(self, ...)
            local d = wheelDelta(...)
            if d > 0 then setNvgGain(carrier.nvgGain + 10)
            elseif d < 0 then setNvgGain(carrier.nvgGain - 10) end
        end
        -- Attach the wheel handler to EVERY visible widget in the bar cluster
        -- (readout + every LED + tick labels). Previously only the readout
        -- had it, which was confusing — the user's natural hover target is
        -- the bar itself, not the % text above it.
        local wheelTargets = {
            'lblNvgVal',
            'ledNvg1','ledNvg2','ledNvg3','ledNvg4','ledNvg5',
            'ledNvg6','ledNvg7','ledNvg8','ledNvg9','ledNvg10',
            'lblTick0','lblTick50','lblTick100',
        }
        local attached = 0
        for _, name in base.ipairs(wheelTargets) do
            local w = carrier.window[name]
            if w and w.addMouseWheelCallback then
                base.pcall(function() w:addMouseWheelCallback(onWheel) end)
                attached = attached + 1
            end
        end
        if attached > 0 then
            logInfo('NVG wheel handler attached to ' .. attached .. ' widgets')
        else
            logErr('no widgets accepted addMouseWheelCallback — wheel disabled')
        end

        -- Click any LED segment to jump to that gain. Segment N (1..10) sets
        -- gain to N*10%. To go all the way to 0 you scroll wheel down (or
        -- click LED 1 then scroll once more — easy enough).
        for i = 1, 10 do
            local pct = i * 10
            wireClick('ledNvg' .. i, function() setNvgGain(pct) end)
        end

        -- Sync the on-disk file with our initial state (0%) so a fresh DCS
        -- launch doesn't inherit a stale value from a previous session.
        writeNvgState()
        updateNvgDisplay()

        -- v1.3: WIRE / DECK / ZOOM button wiring removed — those widgets
        -- no longer exist in the dialog (the in-game effect was unreliable
        -- and the UI clutter wasn't worth it).  The IPC files are still
        -- written from RESET CAM (with default values) so the patched
        -- PLATCameraUI keeps reading consistent state, but no per-tab
        -- controls drive them.

        -- RESET CAM — one-click revert to vanilla DCS PLAT.
        --   NVG  -> 0% (alpha=0 -> shader lerps to raw texture)
        --   ZOOM -> DEFAULT (fov=0 -> patched lua skips adjustGate,
        --                    so DCS's own dynamic zoom resumes)
        -- Foul deck + desired wire are operational settings and DON'T
        -- get touched here — they're not "cam defaults".
        wireClick('btnResetCam', function()
            carrier.nvgGain  = 0
            carrier.platZoom = 0
            writeNvgState()
            writeZoomState()
            updateNvgDisplay()
            updateLsoDisplay()
            logInfo('RESET CAM (NVG 0%, zoom DEFAULT)')
        end)

        -- Sync all the new LSO state files with our initial state.
        writeFoulState()
        writeWireState()
        writeZoomState()
        updateLsoDisplay()

        -- v1.3: WAVE OFF + CUT light pulses (5s latched lit after press).
        -- These wireClick calls compose with the BUTTON_FLAGS auto-wiring
        -- (which fires user-flags 210/211) — both callbacks run on press.
        wireClick('btnWaveOff', function() pulseLight('btnWaveOff') end)
        wireClick('btnCut',     function() pulseLight('btnCut')     end)

        -- v1.3: DECKBOSS conga-line toggle (view-only — no game-state writes).
        wireClick('btnDbConga', function()
            congaOn = not congaOn
            if carrier.window.lblDbCongaState then
                base.pcall(function()
                    carrier.window.lblDbCongaState:setText(
                        'CONGA LINE:  ' .. (congaOn and 'ON' or 'OFF'))
                end)
            end
            logInfo('conga toggle -> ' .. tostring(congaOn))
        end)

        -- marshal stack steppers (1..8 flights)
        wireClick('btnFlightsDown', function()
            carrier.marshalFlights = math.max(1, carrier.marshalFlights - 1)
            updateSteppers()
        end)
        wireClick('btnFlightsUp', function()
            carrier.marshalFlights = math.min(8, carrier.marshalFlights + 1)
            updateSteppers()
        end)

        -- charlie timer steppers (0..120 min, step 5)
        wireClick('btnCharlieDown', function()
            carrier.charlieMin = math.max(0, carrier.charlieMin - 5)
            updateSteppers()
        end)
        wireClick('btnCharlieUp', function()
            carrier.charlieMin = math.min(120, carrier.charlieMin + 5)
            updateSteppers()
        end)

        -- broadcast buttons: stash the numeric value, then fire the action flag
        wireClick('btnMarshalBroadcast', function()
            setFlagValue('cg_marshal_flights', carrier.marshalFlights)
            fireFlag(200)
        end)
        wireClick('btnCharlieBroadcast', function()
            setFlagValue('cg_charlie_min', carrier.charlieMin)
            fireFlag(201)
            -- v1.3-beta9: flip every HOLDing aircraft to CHARLIE'D in the
            -- mission-query state (the query chunk owns the roster state now).
            base.pcall(function()
                net.dostring_in('server',
                    'if __CGQ then for k in pairs(__CGQ.fs) do ' ..
                    'if not __CGQ.co[k] then __CGQ.ch[k] = true end end end')
            end)
        end)

        -- initial stepper text + default to the carrier tab
        updateSteppers()
        showTab('carrier')

        -- start hidden
        hide()

        carrier.windowCreated = true
        logInfo('window created')
        return true
    end

    -- ------------------------------------------------ DCS hook callbacks ---
    local handler = {}

    function handler.onSimulationFrame()
        if not carrier.windowCreated then
            base.pcall(createWindow)
        end
        if carrier.bridgeProbeAt and DCS.getRealTime() >= carrier.bridgeProbeAt then
            carrier.bridgeProbeAt = nil
            base.pcall(probeBridge)
        end
        local now = DCS.getRealTime() or 0
        -- One-shot NVG bar re-apply ~2s after creation: the initial setSkin
        -- during createWindow can get stomped by DialogLoader finishing up,
        -- which left all 10 LEDs in their .dlg default (lit green) at OFF.
        if carrier.windowCreated and not carrier.nvgReapplied then
            if not carrier.nvgReapplyAt then
                carrier.nvgReapplyAt = now + 2
            elseif now > carrier.nvgReapplyAt then
                carrier.nvgReapplied = true
                base.pcall(updateNvgDisplay)
            end
        end
        -- 1 Hz: run the mission query, then refresh every data display.
        if (carrier.shipStateReadAt or 0) + 1.0 < now then
            carrier.shipStateReadAt = now
            base.pcall(runMissionQuery)
            base.pcall(readShipState)
            base.pcall(readLsoEvents)
            base.pcall(readStackState)
            base.pcall(readCczState)
            base.pcall(readPatternState)
            base.pcall(readDeckState)
        end
        -- Every frame: decay WAVE OFF / CUT light timers (short-lived state).
        base.pcall(updateLights)
    end

    function handler.onMissionLoadEnd()
        -- Schedule a bridge probe ~5s after mission load. Bridge runs at
        -- TIME MORE 1 so it should have set its flag by then.
        carrier.bridgeProbeAt = DCS.getRealTime() + 5
        carrier.bridgeStatus  = '?'
        if carrier.windowCreated then
            setStatus('Bridge: checking...')
        end
    end

    function handler.onSimulationStop()
        if carrier.window then
            base.pcall(function() carrier.window:setSize(0, 0) end)
        end
        carrier.visible = false
    end

    DCS.setUserCallbacks(handler)
    logInfo('hook loaded (v1.3-beta9)')
end

local ok, err = pcall(load)
if not ok then
    -- last-ditch logging — at this point even our log helper might not exist
    if base.log and base.log.write then
        base.log.write('CarrierGUI', base.log.ERROR, 'load failed: ' .. tostring(err))
    end
end
