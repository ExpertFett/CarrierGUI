-- CarrierGUI Hook  (rebuild v0.7 — round arc dial + mouse wheel spin)
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
    local MARSHALL_WIDGETS = {
        'lblMarCase','btnCase1','btnCase2','btnCase3','lblMarStack','lblFlightsCap',
        'btnFlightsDown','lblFlightsVal','btnFlightsUp','btnMarshalBroadcast',
        'lblMarCharlie','lblCharlieCap','btnCharlieDown','lblCharlieVal',
        'btnCharlieUp','btnCharlieBroadcast',
    }
    local LSO_WIDGETS = {
        'lblLsoNvg',
        'dotNvg0','dotNvg1','dotNvg2','dotNvg3','dotNvg4','dotNvg5',
        'dotNvg6','dotNvg7','dotNvg8','dotNvg9','dotNvg10',
        'lblNvgVal', 'lblNvgState', 'lblLsoHelp',
    }

    -- --------------------------------------------------------- show / hide ---
    -- Gotcha #4: setVisible(false) destroys the dialog. We toggle visibility
    -- via the SRS-style pattern: real setVisible(true), then either setSize(0,0)
    -- (= hidden) or restore to full size.
    local FULL_W, FULL_H = 380, 560

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
        local lsoVis      = (tab == 'lso')
        for _, n in base.ipairs(CARRIER_WIDGETS)  do setWidgetVisible(n, carrierVis)  end
        for _, n in base.ipairs(MARSHALL_WIDGETS) do setWidgetVisible(n, marshallVis) end
        for _, n in base.ipairs(LSO_WIDGETS)      do setWidgetVisible(n, lsoVis)      end
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

    -- "●" U+25CF filled circle, "○" U+25CB open circle. Lit dots = ≤ gain.
    local NVG_DOT_LIT   = '\xE2\x97\x8F'   -- ●
    local NVG_DOT_UNLIT = '\xE2\x97\x8B'   -- ○

    local function updateNvgDisplay()
        if not carrier.window then return end
        local g = carrier.nvgGain
        -- big percent in the center
        if carrier.window.lblNvgVal then
            base.pcall(function() carrier.window.lblNvgVal:setText(tostring(g) .. '%') end)
        end
        -- dot array: dot i lights up when its step (i*10%) <= current gain.
        -- Dot 0 always lit (it represents the "0%" position itself).
        for i = 0, 10 do
            local dot = carrier.window['dotNvg' .. i]
            if dot then
                local lit = (i * 10) <= g
                base.pcall(function()
                    dot:setText(lit and NVG_DOT_LIT or NVG_DOT_UNLIT)
                end)
            end
        end
        -- state line
        if carrier.window.lblNvgState then
            local label
            if g <= 0       then label = 'NVG: OFF (normal feed)'
            elseif g >= 100 then label = 'NVG: MAX (full amplification)'
            else                 label = 'NVG: ' .. g .. '% (partial amplification)' end
            base.pcall(function() carrier.window.lblNvgState:setText(label) end)
        end
    end

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

        -- tab buttons
        wireClick('btnTabCarrier',  function() showTab('carrier')  end)
        wireClick('btnTabMarshall', function() showTab('marshall') end)
        wireClick('btnTabLso',      function() showTab('lso')      end)

        -- LSO tab: NVG gain dial
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

        -- Mouse wheel on the big % readout: scroll up = +10%, down = -10%.
        -- The wheel callback's arg signature varies across DCS versions; we
        -- accept any non-zero numeric and use its sign.
        local function wheelDelta(...)
            local args = {...}
            for i = #args, 1, -1 do
                local v = args[i]
                if type(v) == 'number' and v ~= 0 then return v end
            end
            return 0
        end
        local valWidget = carrier.window.lblNvgVal
        if valWidget and valWidget.addMouseWheelCallback then
            base.pcall(function()
                valWidget:addMouseWheelCallback(function(self, ...)
                    local d = wheelDelta(...)
                    if d > 0 then setNvgGain(carrier.nvgGain + 10)
                    elseif d < 0 then setNvgGain(carrier.nvgGain - 10) end
                end)
            end)
            logInfo('NVG wheel handler attached')
        else
            logErr('lblNvgVal missing addMouseWheelCallback — wheel input disabled')
        end

        -- Click any dot to jump directly to that gain (fallback for inputs
        -- where the scroll wheel isn't mapped, e.g. controllers in VR).
        for i = 0, 10 do
            local pct = i * 10
            wireClick('dotNvg' .. i, function() setNvgGain(pct) end)
        end

        -- Sync the on-disk file with our initial state (0%) so a fresh DCS
        -- launch doesn't inherit a stale value from a previous session.
        writeNvgState()
        updateNvgDisplay()

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
    logInfo('hook loaded (v0.7)')
end

local ok, err = pcall(load)
if not ok then
    -- last-ditch logging — at this point even our log helper might not exist
    if base.log and base.log.write then
        base.log.write('CarrierGUI', base.log.ERROR, 'load failed: ' .. tostring(err))
    end
end
