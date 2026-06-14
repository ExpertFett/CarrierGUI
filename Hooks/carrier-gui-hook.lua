-- CarrierGUI Hook  (rebuild v1.3-beta28 — full 5-tab UX overhaul)
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
    -- MARSHALL (beta14): dot-ring radar + scripted readout + stack + table.
    local MARSHALL_WIDGETS = {
        'lblMarshallHdr',
        'mScope','mBordT','mBordB','mBordL','mBordR','mCrossV','mCrossH',
        'mShip','lblBrcTip',
        'hdgDot1','hdgDot2','hdgDot3','hdgDot4','hdgDot5','hdgDot6','hdgDot7',
        'lblMRcv','lblMR20','lblMR40','lblMR60','lblMRN','lblMRS','lblMRE','lblMRW',
        'rowCcz1','rowCcz2','rowCcz3','rowCcz4','rowCcz5','rowCcz6',
        'rowCcz7','rowCcz8','rowCcz9','rowCcz10','rowCcz11','rowCcz12',
        'lblMarRadioHdr',
        'lblMotherHdr','lblBoat1','lblBoat2',
        'lblMarStackHdr','sPillL','sPillR','sPillT','sPillB','lblStkAng',
        'lblStkA2','lblStkA3','lblStkA4','lblStkA5','lblStkA6','lblStkA7',
        'sRung2','sRung3','sRung4','sRung5','sRung6','sRung7',
        'lblMTblHdr',
        'mTblBT','mTblBB','mTblBL','mTblBR','mTblHL',
        'mTblV1','mTblV2','mTblV3','mTblV4','mTblV5',
        'lblMTh1','lblMTh2','lblMTh3','lblMTh4','lblMTh5','lblMTh6',
        'lblMarStatus',
    }
    for i = 1,  5 do table.insert(MARSHALL_WIDGETS, 'rowMarCall' .. i) end
    for i = 1, 12 do table.insert(MARSHALL_WIDGETS, 'stkSlot' .. i) end
    for i = 1, 12 do table.insert(MARSHALL_WIDGETS, 'cczDot' .. i) end
    for r = 1, 13 do for ccol = 1, 6 do
        table.insert(MARSHALL_WIDGETS, 'mCell' .. r .. '_' .. ccol)
    end end
    for i = 1,  39 do table.insert(MARSHALL_WIDGETS, 'mDotA' .. i) end
    for i = 1,  97 do table.insert(MARSHALL_WIDGETS, 'mDotB' .. i) end
    for i = 1, 193 do table.insert(MARSHALL_WIDGETS, 'mDotC' .. i) end
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
        'dbDot1','dbDot2','dbDot3','dbDot4','dbDot5','dbDot6','dbDot7','dbDot8',
        'dbDot9','dbDot10','dbDot11','dbDot12','dbDot13','dbDot14','dbDot15','dbDot16',
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
        'acftDot1','acftDot2','acftDot3','acftDot4','acftDot5','acftDot6','acftDot7','acftDot8',
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

    -- v1.3-beta28: register the drawn-scope widgets (solid fills, rings,
    -- lines, arcs) with their tabs so they hide on tab switch.  Stale beta8
    -- names still present in the literal lists above are harmless —
    -- setWidgetVisible no-ops on missing children.  c.bgPanel (the whole-
    -- panel dark backdrop) is deliberately in NO list: always visible.
    local function addAll(list, names)
        for _, n in base.ipairs(names) do table.insert(list, n) end
    end
    addAll(TOWER_WIDGETS, {
        'tScopeL','tBordLT','tBordLB','tBordLL','tBordLR','tAxH','tAxV','tShip',
        'tScopeR','tBordRT','tBordRB','tBordRL','tBordRR',
        'tGrid1','tGrid2','tGrid3','tGrid4','tGrid5'})
    for i = 1, 28 do table.insert(TOWER_WIDGETS, 'tDotA' .. i) end
    for i = 1, 57 do table.insert(TOWER_WIDGETS, 'tDotB' .. i) end
    for i = 1, 85 do table.insert(TOWER_WIDGETS, 'tDotC' .. i) end
    for i = 1, 10 do table.insert(TOWER_WIDGETS, 'tOhDot' .. i) end
    addAll(LSO_WIDGETS, {
        'pScope','pBordT','pBordB','pBordL','pBordR',
        'pLegR','pLegT','pLegB','pShip',
        'pArcL1','pArcL2','pArcL3','pArcL4','pArcL5',
        'pArcL6','pArcL7','pArcL8','pArcL9','pArcL10'})
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
    local FULL_W, FULL_H = 540, 900   -- v1.3-beta28: bumped for radar overlays

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
            -- NOTE: [%w_] not %w — Lua %w excludes underscore, which silently
            -- broke every underscore key (wind_from/wind_kts/head_kts/...).
            local k, v = line:match('^([%w_]+)=(.+)$')
            if k then s[k] = v end
        end
        return s
    end

    local function readShipState()
        -- v1.3-beta28: primary source is the mission query (carrier.q.ship);
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
        carrier.callsign      = s.callsign or carrier.callsign
        carrier.altimeter     = s.altimeter or carrier.altimeter
        carrier.shipFB        = tonumber(s.fb) or carrier.shipFB
        carrier.shipTod       = tonumber(s.tod) or carrier.shipTod
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
    -- v1.3-beta28: MISSION QUERY — the hook pulls all live data itself via
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

    -- ship state — robust: hdg + fb always emitted; wind in its own pcall so a
    -- getWind failure can't wipe the rest; mission-weather fallback if the
    -- live wind query is unavailable.
    local shipLines = {}
    shipLines[#shipLines + 1] = 'hdg=' .. math.floor(hdg + 0.5)
    shipLines[#shipLines + 1] = 'fb='  .. math.floor(fb + 0.5)

    local gotWind = false
    pcall(function()
        local w = atmosphere.getWind({x = cp.x, y = cp.y + 18, z = cp.z})
        if not w then return end
        local wspd = math.sqrt(w.x * w.x + w.z * w.z)
        if wspd < 0.05 then
            shipLines[#shipLines + 1] = 'wind_from=0'
            shipLines[#shipLines + 1] = 'wind_kts=0'
            gotWind = true
            return
        end
        local wfrom = norm(math.deg(math.atan2(w.z, w.x)) + 180)
        shipLines[#shipLines + 1] = 'wind_from=' .. math.floor(wfrom + 0.5)
        shipLines[#shipLines + 1] = 'wind_kts='  .. math.floor(wspd * 1.94384 + 0.5)
        gotWind = true
        pcall(function()
            local vel = carrier:getVelocity()
            local relx, relz = w.x - vel.x, w.z - vel.z
            -- Decompose the relative (over-deck) wind onto the ANGLED DECK
            -- (FB), not the ship centerline (BRC).  Turned into wind, the
            -- centerline crosswind is ~0; what matters for landing is the
            -- component across the angled landing area (BRC-9 deg).
            local fbR = math.rad(fb)
            local fdx, fdz = math.cos(fbR), math.sin(fbR)
            local fwd = relx * fdx + relz * fdz
            local crs = relx * (-fdz) + relz * fdx
            shipLines[#shipLines + 1] = 'head_kts='  .. math.floor(-fwd * 1.94384 + 0.5)
            shipLines[#shipLines + 1] = 'cross_kts=' .. math.floor(crs * 1.94384 + 0.5)
        end)
    end)
    -- Fallback: mission-editor ground wind (speed m/s, dir = FROM degrees).
    if not gotWind then
        pcall(function()
            local g = env.mission.weather.wind.atGround
            if g then
                shipLines[#shipLines + 1] = 'wind_from=' .. math.floor((g.dir or 0) + 0.5)
                shipLines[#shipLines + 1] = 'wind_kts='  .. math.floor((g.speed or 0) * 1.94384 + 0.5)
            end
        end)
    end

    -- mission time-of-day (for EAT): start_time is seconds since midnight.
    pcall(function()
        local st = (env.mission and env.mission.start_time) or 43200
        shipLines[#shipLines + 1] = 'tod=' .. math.floor(st + timer.getTime())
    end)

    -- beta14: carrier RADIO CODENAME (not ship name) + altimeter for the
    -- scripted marshal readout.  Codenames are the controller callsigns
    -- pilots actually hear.
    pcall(function()
        local CS = {
            CVN_71 = 'Roughrider',       -- Theodore Roosevelt
            CVN_72 = 'Honest Abe',       -- Abraham Lincoln
            CVN_73 = 'Spirit of Freedom',-- George Washington
            CVN_75 = 'Lone Warrior',     -- Harry S. Truman
            CVN_74 = 'Champion',         -- John C. Stennis
            Stennis = 'Champion',
            Forrestal = 'Forrestal',
            VINSON = 'Gold Eagle',       -- Carl Vinson
        }
        local tn = carrier:getTypeName() or ''
        local cs = CS[tn]
        if not cs then for k, v in pairs(CS) do if tn:find(k) then cs = v break end end end
        shipLines[#shipLines + 1] = 'callsign=' .. (cs or (carrier:getName() or 'Mother'))
        local qnh = 760
        if env and env.mission and env.mission.weather and env.mission.weather.qnh then
            qnh = env.mission.weather.qnh
        end
        shipLines[#shipLines + 1] = string.format('altimeter=%.2f', qnh / 25.4)
    end)

    local stackRaw, ccz, pattern, deck = {}, {}, {}, {}
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
                            -- IDENTIFIER: prefer the ME Tail#/modex; else the
                            -- radio CALLSIGN (unique per flight: Shell11);
                            -- never the trailing digit of the unit name — that
                            -- collapses every AI flight to "1" and they collide.
                            local okc, cs = pcall(function() return u:getCallsign() end)
                            cs = (okc and cs) or ''
                            local modex = Q.mx[name]
                            if not modex or modex == '' then
                                modex = (cs ~= '' and cs) or name
                            end
                            if modex == '' then return end

                            -- Support aircraft (tankers / AWACS) are in the AO
                            -- but DON'T recover into the marshal stack — show
                            -- them on the radar with altitude, but no angels.
                            -- Detect by TYPE and by CALLSIGN (catches an A-6E
                            -- flying as "Shell", an E-2 as "Wizard", etc.).
                            local tn = u:getTypeName() or ''
                            local support =
                                   tn:find('KC%-?130') or tn:find('KC%-?135') or tn:find('KC135')
                                or tn:find('Tanker')  or tn:find('IL%-78')
                                or tn:find('E%-3')     or tn:find('E%-2')   or tn:find('A%-50')
                                or tn:find('KJ%-2000') or tn:find('AWACS')  or tn:find('Tu%-95')
                                or cs:find('Shell')  or cs:find('Texaco') or cs:find('Arco')
                                or cs:find('Mobil')  or cs:find('Roman')
                                or cs:find('Wizard') or cs:find('Magic')  or cs:find('Overlord')
                                or cs:find('Focus')  or cs:find('Darkstar') or cs:find('Sentry')
                            local role = support and 'TKR' or 'REC'

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
                                -- keep raw east/north (nm, relative to SHIP) so the
                                -- stack centroid + per-aircraft offsets can be
                                -- computed once the sweep is complete
                                stackRaw[#stackRaw + 1] = {
                                    modex = modex, altFt = altFt, ias = ias,
                                    inT = inT, point = point, state = state,
                                    e = dz / NM, n = dx / NM,
                                }
                            end
                            if nm < 60 and nm > 8 then
                                ccz[#ccz + 1] = string.format('%s|%d|%.1f|%d|%d|%s', modex, math.floor(brg + 0.5), nm, altFt, ias, role)
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

    -- Stack centroid: mean position of everything in the stack list, so the
    -- 6 nm TOWER scope centres on the STACK, not the ship.  Offsets emitted
    -- per aircraft in nm east/north of that centroid.
    local stack = {}
    do
        local ce, cn = 0, 0
        if #stackRaw > 0 then
            for _, r in pairs(stackRaw) do ce = ce + r.e cn = cn + r.n end
            ce = ce / #stackRaw
            cn = cn / #stackRaw
        end
        for _, r in pairs(stackRaw) do
            stack[#stack + 1] = string.format('%s|%d|%d|%d|%s|%s|%.2f|%.2f',
                r.modex, r.altFt, r.ias, r.inT, r.point, r.state,
                r.e - ce, r.n - cn)
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
    -- Stack file format includes ALT/IAS/POINT/STATE.  v1.3-beta28 also
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
            -- v1.3-beta28 format adds relE|relN (nm offsets from the stack
            -- centroid).  The two captures are optional so beta8/9 bridge
            -- file fallbacks still parse.
            local modex, alt, ias, inT, pt, state, relE, relN =
                line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]+)|([^|]+)|(%-?[%d%.]+)|(%-?[%d%.]+)')
            if not modex then
                modex, alt, ias, inT, pt, state =
                    line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]+)|([^|]+)')
            end
            if modex then
                local r = { modex = modex, alt = tonumber(alt) or 0,
                            ias = tonumber(ias) or 0, inT = tonumber(inT) or 0,
                            pt = pt, state = state,
                            relE = tonumber(relE), relN = tonumber(relN) }
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
        -- v1.3-beta28: mapped onto the drawn gridlines — 15k → y=56, 0 → y=152.
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
                setText('twrSv' .. i, r.modex:sub(1, 7))
                setBounds('twrSv' .. i, x, y, 40, 14)
            else
                setText('twrSv' .. i, '')
                setBounds('twrSv' .. i, -200, -200, 40, 14)
            end
        end

        -- Stack scope — LotATC-style (beta27, carrying the MARSHALL learnings):
        -- a blip DOT at the true (relE, relN) position + a datablock (id +
        -- altitude), decluttered.  Centre (130,103), 6 nm = 54 px (9 px/nm), N up.
        local tplaced = {}
        local function tfreeY(lx, ly)
            for _ = 1, 6 do
                local hit = false
                for _, p in base.ipairs(tplaced) do
                    if math.abs(p.x - lx) < 54 and math.abs(p.y - ly) < 12 then hit = true break end
                end
                if not hit then break end
                ly = ly + 12
            end
            return ly
        end
        for i = 1, 10 do
            local r = allAir[i]
            if r and r.relE then
                local e, n = r.relE, r.relN or 0
                if e >  6 then e =  6 elseif e < -6 then e = -6 end
                if n >  6 then n =  6 elseif n < -6 then n = -6 end
                local dxp = math.floor(130 + e * 9)
                local dyp = math.floor(103 - n * 9)
                setBounds('tOhDot' .. i, dxp - 2, dyp - 2, 5, 5)
                local lx = dxp + 6
                local ly = tfreeY(lx, dyp - 6)
                table.insert(tplaced, { x = lx, y = ly })
                local altk = math.floor((r.alt or 0) / 1000 + 0.5)
                setText('twrOh' .. i, string.format('%s %dk', r.modex:sub(1, 7), altk))
                setBounds('twrOh' .. i, lx, ly, 60, 13)
            else
                setBounds('tOhDot' .. i, -300, -300, 5, 5)
                setText('twrOh' .. i, '')
                setBounds('twrOh' .. i, -300, -300, 60, 13)
            end
        end
    end

    -- ─── MARSHALL: scope scatter + scripted readout + stack racetrack ─────
    -- Scope centre (270,212), 60 nm = 150 px (2.5 px/nm), N up.  Marshal
    -- angels assigned by range order: closest inbound = angels 2, stacking up.
    local function readCczState()
        local content = (carrier.q and carrier.q.ccz) or ''
        if content == '' then content = slurp(CCZ_FILE_V13) end
        local rows = {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, brg, nm, alt, ias, role =
                line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)|(%a+)')
            if not modex then
                -- back-compat parse (older bridge w/o role field)
                modex, brg, nm, alt, ias =
                    line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)')
            end
            if modex then
                table.insert(rows, {
                    modex = modex, brg = tonumber(brg) or 0,
                    nm = tonumber(nm) or 0, alt = tonumber(alt) or 0,
                    ias = tonumber(ias) or 0,
                    support = (role == 'TKR'),
                })
            end
        end
        table.sort(rows, function(a, b) return a.nm < b.nm end)
        -- Assign marshal angels ONLY to recovering aircraft (tankers/AWACS get
        -- none — they're shown for altitude awareness but aren't in the stack).
        local angIdx = 0
        for _, r in ipairs(rows) do
            if not r.support then
                angIdx = angIdx + 1
                r.angels = 2 + (angIdx - 1)
            end
        end

        -- Scope scatter (N up).  60 nm = 148 px.  LotATC-style: a blip DOT at
        -- the true position, plus a compact datablock (modex + altitude in
        -- thousands; trailing 'T' for tankers).  Datablocks declutter — if one
        -- would overlap an already-placed label, it's nudged down — so a
        -- group of jets reads as a tidy stack of blocks, not a pile of text.
        local cx, cy, pxPerNm = 270, 206, 148/60
        local placed = {}
        local function freeY(lx, ly)
            for _ = 1, 8 do
                local hit = false
                for _, p in base.ipairs(placed) do
                    if math.abs(p.x - lx) < 60 and math.abs(p.y - ly) < 13 then hit = true break end
                end
                if not hit then break end
                ly = ly + 13
            end
            return ly
        end
        for i = 1, 12 do
            local r = rows[i]
            if r then
                local brgR = math.rad(r.brg)
                local nmC = r.nm
                if nmC > 60 then nmC = 60 end
                local dxp = math.floor(cx + nmC * pxPerNm * math.sin(brgR))
                local dyp = math.floor(cy - nmC * pxPerNm * math.cos(brgR))
                -- blip dot at true position
                setBounds('cczDot' .. i, dxp - 2, dyp - 2, 5, 5)
                -- datablock to the upper-right of the dot, decluttered
                local lx = dxp + 6
                local ly = freeY(lx, dyp - 6)
                table.insert(placed, { x = lx, y = ly })
                local altk = math.floor((r.alt or 0) / 1000 + 0.5)
                setText('rowCcz' .. i, string.format('%s %dk%s',
                    r.modex:sub(1, 8), altk, r.support and ' T' or ''))
                setBounds('rowCcz' .. i, lx, ly, 66, 13)
            else
                setBounds('cczDot' .. i, -300, -300, 5, 5)
                setText('rowCcz' .. i, '')
                setBounds('rowCcz' .. i, -300, -300, 66, 13)
            end
        end

        -- BRC heading vector — dots from scope centre outward along the ship's
        -- heading (north-up scope), so the boat's heading is visible and
        -- rotates with it.  No widget rotation needed (just re-position dots).
        local hdg = carrier.shipHdg
        if hdg then
            local hr = math.rad(hdg)
            local sx, sy = math.sin(hr), -math.cos(hr)
            for i = 1, 7 do
                local rr = 12 + (i - 1) * 9
                setBounds('hdgDot' .. i,
                    math.floor(cx + rr * sx - 2), math.floor(cy + rr * sy - 2), 4, 4)
            end
            local tr = 12 + 7 * 9
            setText('lblBrcTip', 'BRC ' .. hdg)
            setBounds('lblBrcTip',
                math.floor(cx + tr * sx - 14), math.floor(cy + tr * sy - 7), 60, 14)
        else
            for i = 1, 7 do setBounds('hdgDot' .. i, -300, -300, 4, 4) end
            setText('lblBrcTip', '')
        end

        -- Live data only (demo/example rows removed in beta27).
        local tblRows = rows

        -- ONE scripted marshal call (nearest recovering aircraft).
        local cs  = carrier.callsign or 'Mother'
        local alt = carrier.altimeter or '29.92'
        local brc = carrier.shipHdg
        local lineIdx = 0
        local function put(txt)
            lineIdx = lineIdx + 1
            if lineIdx <= 5 then setText('rowMarCall' .. lineIdx, txt) end
        end
        -- nearest RECOVERING aircraft (skip tankers/AWACS) for the call
        local r1 = nil
        for _, r in ipairs(tblRows) do
            if not r.support then r1 = r break end
        end
        if r1 then
            local ang = r1.angels or 2
            local brcStr = brc and tostring(brc) or '---'
            put(string.format("%s, %s Marshall, Mother's weather is clear,", r1.modex, cs))
            put("   visibility 10 plus miles, CV-1 Approach, Case I recovery in effect.")
            put(string.format("   Altimeter reads %s, Ship's BRC %s,", alt, brcStr))
            put(string.format("   Marshal Mother's angels %d, report see me at ten.", ang))
        end
        for i = lineIdx + 1, 5 do setText('rowMarCall' .. i, '') end

        -- MOTHER boat-info block (replaces the old 2nd call).
        do
            local brcS = brc and string.format('%03d', brc) or '---'
            local fbS  = carrier.shipFB and string.format('%03d', carrier.shipFB) or '---'
            setText('lblBoat1', string.format('BRC %s   FB %s   ALT %s', brcS, fbS, alt))
            if carrier.shipWindFrom and carrier.shipWindKts then
                setText('lblBoat2', string.format(
                    'WIND %03d/%d kt   ACROSS DECK %dH %dX',
                    carrier.shipWindFrom, carrier.shipWindKts,
                    carrier.shipHeadKts or 0, carrier.shipCrossKts or 0))
            else
                setText('lblBoat2', 'WIND ---/-- kt   ACROSS DECK --')
            end
        end

        -- Marshal assignment table — per cell: MODEX/ALT/RNG/BRG/ANG/EAT.
        -- EAT auto-assigned: 1 min spacing from the carrier's time-of-day,
        -- earliest (nearest) aircraft first.  tod = secs since midnight.
        local function clockFromSecs(s)
            s = s % 86400
            return string.format('%02d:%02d', math.floor(s/3600), math.floor((s%3600)/60))
        end
        local tod = carrier.shipTod
        for i = 1, 13 do
            local r = tblRows[i]
            if r then
                setText('mCell'..i..'_1', ' ' .. r.modex:sub(1, 7))
                setText('mCell'..i..'_2', string.format('%5d', r.alt or 0))
                setText('mCell'..i..'_3', string.format('%4.1f', r.nm or 0))
                setText('mCell'..i..'_4', string.format('%3d', r.brg or 0))
                if r.support then
                    -- tanker/AWACS: altitude only, no marshal slot
                    setText('mCell'..i..'_5', 'TKR')
                    setText('mCell'..i..'_6', ' --')
                else
                    local eat = tod and clockFromSecs(tod + (r.angels or 1)*60) or '--:--'
                    setText('mCell'..i..'_5', string.format('%2d', r.angels or 0))
                    setText('mCell'..i..'_6', eat)
                end
            else
                for ccol = 1, 6 do setText('mCell'..i..'_'..ccol, '') end
            end
        end

        -- Marshal stack: modex sits to the RIGHT of the pill (PR=180) at its
        -- angels rung.  Rungs (beta16): angels 2 at y=786, step 40 up.
        for i = 1, 12 do
            local r = tblRows[i]
            if r and r.angels then
                local a = r.angels
                if a > 7 then a = 7 end
                if a < 2 then a = 2 end
                local y = 786 - (a - 2) * 40 - 6
                setText('stkSlot' .. i, r.modex:sub(1, 6))
                setBounds('stkSlot' .. i, 186, y, 44, 13)
            else
                setText('stkSlot' .. i, '')
                setBounds('stkSlot' .. i, -300, -300, 44, 13)
            end
        end

        if #rows > 0 then
            setText('lblMarStatus', tostring(#rows) .. ' aircraft in CCZ')
        else
            setText('lblMarStatus', '(no aircraft in CCZ)')
        end
    end

    -- ─── LSO CASE I pattern visual ───────────────────────────────────────
    -- v1.3-beta28: aircraft slots (acftPat1..8) get repositioned to the
    -- landmark coords for whichever pattern point the bridge classified
    -- them at.  Multiple aircraft at the same point stack vertically.
    -- v1.3-beta28: HORIZONTAL racetrack — bottom leg y=220 (upwind, ship at
    -- the right end), right leg x=468 (break climb), top leg y=90 (downwind,
    -- right→left), rounded 180 on the left.
    local PATTERN_XY = {
        INITIAL  = { 140, 200 },
        BREAK    = { 440,  98 },
        DOWNWIND = { 260,  96 },
        ABEAM    = { 410,  96 },
        ['180']  = {  72, 148 },
        GROOVE   = { 340, 200 },
        TRAP     = { 416, 200 },
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
        -- blip dot AT the pattern point + datablock (id + altitude) beside it;
        -- multiple aircraft at the same point stack downward.
        local placed = {}
        for i = 1, 8 do
            local r = list[i]
            local xy = r and PATTERN_XY[r.point]
            if xy then
                placed[r.point] = (placed[r.point] or 0) + 1
                local offY = (placed[r.point] - 1) * 14
                setBounds('acftDot' .. i, xy[1] - 2, xy[2] + offY - 2, 5, 5)
                local altk = math.floor((r.alt or 0) / 1000 + 0.5)
                setText('acftPat' .. i, string.format('%s %dk', r.modex:sub(1, 7), altk))
                setBounds('acftPat' .. i, xy[1] + 6, xy[2] + offY - 6, 64, 13)
            else
                setBounds('acftDot' .. i, -300, -300, 5, 5)
                setText('acftPat' .. i, '')
                setBounds('acftPat' .. i, -300, -300, 64, 13)
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
                    '  %-8s  %+5d m  %+4d m   %s',
                    r.modex:sub(1, 8), r.along, r.across, zone))
            else
                setText('rowDbOnDeck' .. i, '')
            end
        end

        -- Deck spots — blip dot at the true deck position + an id label,
        -- decluttered so parked jets don't overlap (HORIZONTAL deck:
        -- BOW = right, PORT = top; along +200=bow→x470, across +50=stbd→y228).
        local dplaced = {}
        local function dfreeY(lx, ly)
            for _ = 1, 6 do
                local hit = false
                for _, p in base.ipairs(dplaced) do
                    if math.abs(p.x - lx) < 50 and math.abs(p.y - ly) < 12 then hit = true break end
                end
                if not hit then break end
                ly = ly + 12
            end
            return ly
        end
        for i = 1, 16 do
            local r = rows[i]
            if r then
                local a = r.along
                if a >  200 then a =  200 elseif a < -200 then a = -200 end
                local cc = r.across
                if cc >  50 then cc =  50 elseif cc < -50 then cc = -50 end
                local dxp = math.floor( 66 + (a + 200) * (404 / 400))
                local dyp = math.floor(124 + (cc + 50) * (104 / 100))
                setBounds('dbDot' .. i, dxp - 2, dyp - 2, 5, 5)
                local lx = dxp + 6
                local ly = dfreeY(lx, dyp - 6)
                table.insert(dplaced, { x = lx, y = ly })
                setText('spotDb' .. i, r.modex:sub(1, 8))
                setBounds('spotDb' .. i, lx, ly, 56, 13)
            else
                setBounds('dbDot' .. i, -300, -300, 5, 5)
                setText('spotDb' .. i, '')
                setBounds('spotDb' .. i, -300, -300, 56, 13)
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
            -- v1.3-beta28: radar/roster data comes from the mission query and
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

        -- tab buttons (v1.3-beta28: 5 tabs)
        wireClick('btnTabCarrier',  function() showTab('carrier')  end)
        wireClick('btnTabMarshall', function() showTab('marshall') end)
        wireClick('btnTabTower',    function() showTab('tower')    end)
        wireClick('btnTabLso',      function() showTab('lso')      end)
        wireClick('btnTabDeckboss', function() showTab('deckboss') end)

        -- (v1.3-beta28's runtime image overlay removed in beta22: dxgui's
        -- picture loader does not load a bkg.file via runtime setSkin — the
        -- call succeeds but nothing renders.  Rings are now solid overlapping
        -- dots instead.)

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
            writeNvgState()
            updateNvgDisplay()
            logInfo('RESET CAM (NVG 0%)')
        end)

        -- v1.3-beta28: WIRE / DECK / ZOOM were retired in beta4, but the hook
        -- was still writing carriergui_wire/foul/zoom.txt — so the patched
        -- PLATCameraUI kept forcing the desired wire (=3) / foul deck / FOV
        -- every frame, overriding DCS's own PLAT readout.  Stop writing them;
        -- delete any stale files so the patch's readers see nothing and leave
        -- the PLAT cam alone.  (NVG is the only thing we still drive.)
        base.pcall(function() base.os.remove(lfs.writedir() .. WIRE_FILE) end)
        base.pcall(function() base.os.remove(lfs.writedir() .. FOUL_FILE) end)
        base.pcall(function() base.os.remove(lfs.writedir() .. ZOOM_FILE) end)

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
            -- v1.3-beta28: flip every HOLDing aircraft to CHARLIE'D in the
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
    logInfo('hook loaded (v1.3-beta28)')
end

local ok, err = pcall(load)
if not ok then
    -- last-ditch logging — at this point even our log helper might not exist
    if base.log and base.log.write then
        base.log.write('CarrierGUI', base.log.ERROR, 'load failed: ' .. tostring(err))
    end
end
