-- CarrierGUI Hook  (rebuild v1.3-beta5 — full 5-tab UX overhaul)
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
    -- TOWER tab (renamed from MARSHALL in beta1).  Now also owns three
    -- roster sections (STACK / CHARLIE'D / COMMENCING) above the existing
    -- broadcast buttons.
    local TOWER_WIDGETS = {
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
    -- MARSHALL tab: 60nm CCZ tracker + radio readout.
    local MARSHALL_WIDGETS = {
        'lblMarshallHdr','lblMarshallCols',
        'rowCcz1','rowCcz2','rowCcz3','rowCcz4','rowCcz5','rowCcz6',
        'rowCcz7','rowCcz8','rowCcz9','rowCcz10','rowCcz11','rowCcz12',
        'lblMarRadioHdr','lblMarRadioBase','lblMarRadioCols',
        'rowMarCall1','rowMarCall2','rowMarCall3','rowMarCall4','rowMarCall5','rowMarCall6',
        'rowMarCall7','rowMarCall8','rowMarCall9','rowMarCall10','rowMarCall11','rowMarCall12',
        'lblMarStatus',
    }
    -- DECKBOSS tab: top-down deck view (labels + modex slot pool).
    local DECKBOSS_WIDGETS = {
        'lblDbHdr',
        -- Deck zone landmarks
        'lblDbBow','lblDbCat1','lblDbCat2','lblDbCat3','lblDbCat4',
        'lblDbIsland','lblDb6pk','lblDbWaist',
        'lblDbElev1','lblDbElev2','lblDbElev3','lblDbElev4',
        'lblDbJunk','lblDbStern',
        -- Aircraft slot pool (hook moves visible ones around)
        'spotDb1','spotDb2','spotDb3','spotDb4','spotDb5','spotDb6','spotDb7','spotDb8',
        'spotDb9','spotDb10','spotDb11','spotDb12','spotDb13','spotDb14','spotDb15','spotDb16',
        -- On-deck list
        'lblDbOnDeckHdr','lblDbOnDeckCols',
        'rowDbOnDeck1','rowDbOnDeck2','rowDbOnDeck3','rowDbOnDeck4','rowDbOnDeck5',
        'rowDbOnDeck6','rowDbOnDeck7','rowDbOnDeck8','rowDbOnDeck9','rowDbOnDeck10',
        -- Conga toggle
        'lblDbCongaState','btnDbConga','lblDbCongaHint',
    }
    -- LSO tab: pattern roster + lights + PLAT cam (NVG / RESET CAM kept;
    -- Wire / Deck / Zoom / Bingo / RecovOK retired).
    local LSO_WIDGETS = {
        -- CASE I pattern roster
        'lblPatHdr','lblPatCols',
        'rowPatInit','rowPatBrk','rowPatDwn','rowPatAbm','rowPat180','rowPatGrv','rowPatTrap',
        -- LSO lights
        'lblLightsHdr','btnWaveOff','btnCut',
        -- PLAT camera (NVG bar + RESET CAM only)
        'lblLsoNvg', 'btnResetCam', 'lblNvgVal',
        'ledNvg1','ledNvg2','ledNvg3','ledNvg4','ledNvg5',
        'ledNvg6','ledNvg7','ledNvg8','ledNvg9','ledNvg10',
        'lblTick0','lblTick50','lblTick100',
        -- SHIP + EVENTS readout
        'lblShipHdr', 'lblShipHdg', 'lblShipWind',
        'lblEventsHdr', 'lblEvent1', 'lblEvent2', 'lblEvent3',
        'lblNvgState',
    }

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
    local FULL_W, FULL_H = 540, 800   -- v1.3: 540×800 to fit roster sections

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
        local path = lfs.writedir() .. SHIPSTATE_FILE
        local ok, content = base.pcall(function()
            local f = io.open(path, 'r')
            if not f then return nil end
            local c = f:read('*a')
            f:close()
            return c
        end)
        if not ok or not content then return end
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
    -- v1.3: bridge IPC readers — feed TOWER / MARSHALL / LSO / DECKBOSS tabs
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

    -- ─── TOWER stack roster ──────────────────────────────────────────────
    local function readStackState()
        local content = slurp(STACK_FILE_V13)
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
    end

    -- ─── MARSHALL CCZ tracker + radio readout ────────────────────────────
    local function readCczState()
        local content = slurp(CCZ_FILE_V13)
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

        for i = 1, 12 do
            local r = rows[i]
            if r then
                setText('rowCcz' .. i, string.format(
                    '  %-3s    %3d°  %4.1f nm  %5d ft  %3d kt',
                    r.modex, r.brg, r.nm, r.alt, r.ias))
            else
                setText('rowCcz' .. i, '')
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

    -- ─── LSO CASE I pattern roster ───────────────────────────────────────
    local function readPatternState()
        local content = slurp(PATTERN_FILE_V13)
        local byPoint = {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, alt, ias, _prog, point =
                line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?[%d%.]+)|([^|]+)')
            if modex then
                byPoint[point] = byPoint[point] or {}
                table.insert(byPoint[point], {
                    modex = modex, alt = tonumber(alt) or 0, ias = tonumber(ias) or 0
                })
            end
        end
        local function rowFor(rowName, label)
            local list = byPoint[label]
            if list and #list > 0 then
                local r = list[1]
                setText(rowName, string.format(
                    '  %-10s  %-3s    %5d ft   %3d kt',
                    label, r.modex, r.alt, r.ias))
            else
                setText(rowName, string.format('  %-10s  —', label))
            end
        end
        rowFor('rowPatInit', 'INITIAL')
        rowFor('rowPatBrk',  'BREAK')
        rowFor('rowPatDwn',  'DOWNWIND')
        rowFor('rowPatAbm',  'ABEAM')
        rowFor('rowPat180',  '180')
        rowFor('rowPatGrv',  'GROOVE')
        rowFor('rowPatTrap', 'TRAP')
    end

    -- ─── DECKBOSS top-down deck view ─────────────────────────────────────
    local function readDeckState()
        local content = slurp(DECK_FILE_V13)
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
        -- Carrier ≈ 330 m long, 75 m wide.  Map:
        --   along  +160 (bow)  → x=80      along -160 (stern) → x=470
        --   across -35 (port)  → y=60      across +35 (stbd)  → y=220
        for i = 1, 16 do
            local r = rows[i]
            if r then
                local a = r.along
                if a >  200 then a =  200 end
                if a < -200 then a = -200 end
                local cc = r.across
                if cc >  50 then cc =  50 end
                if cc < -50 then cc = -50 end
                local x = math.floor(80  + (200 - a)  * (390 / 400))
                local y = math.floor(60  + (cc + 50)  * (160 / 100))
                setText('spotDb' .. i, r.modex)
                setBounds('spotDb' .. i, x, y, 50, 16)
            else
                setText('spotDb' .. i, '')
                setBounds('spotDb' .. i, -200, -200, 50, 16)
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
        if ok and tostring(result) == '1' then
            carrier.bridgeStatus = 'ok'
            setStatus('Bridge: online')
            logInfo('bridge probe: present')
        else
            carrier.bridgeStatus = 'missing'
            setStatus('Mission NOT PATCHED — buttons will not respond.\n' ..
                     'Run "Patch Mission.bat" on your .miz first.')
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

        -- tab buttons (v1.3-beta5: 5 tabs)
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
        -- 1 Hz: ship state + LSO event log + v1.3 IPC files (stack/ccz/pattern/deck)
        if (carrier.shipStateReadAt or 0) + 1.0 < now then
            carrier.shipStateReadAt = now
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
    logInfo('hook loaded (v1.3-beta5)')
end

local ok, err = pcall(load)
if not ok then
    -- last-ditch logging — at this point even our log helper might not exist
    if base.log and base.log.write then
        base.log.write('CarrierGUI', base.log.ERROR, 'load failed: ' .. tostring(err))
    end
end
