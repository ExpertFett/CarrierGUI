-- CarrierGUI Hook  (rebuild v1.3-beta60 — DONE-day: drawn conga, audit fixes, hardened live resize)
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

    -- ── MULTIPLAYER RELAY MODE (auto-detected) ────────────────────────────
    -- When a controller runs the companion agent (connected to a remote server
    -- where net.dostring_in('server') can't reach the mission), the agent
    -- rewrites carriergui_relay_active.txt every second.  While that value keeps
    -- changing we're in RELAY MODE: the panel renders from the companion-written
    -- carriergui_*.txt files and routes button presses to carriergui_panel_cmd.txt
    -- for the agent to POST.  No agent running (SP / listen-host) -> direct mode.
    -- No hook editing required.
    local PANEL_CMD_FILE = 'carriergui_panel_cmd.txt'
    local HEARTBEAT_FILE = 'carriergui_relay_active.txt'
    local _relayHbLast, _relayStale, _relayMode = nil, 99, false
    -- Refresh once per poll (from runMissionQuery); a changing heartbeat = the
    -- companion agent is live = relay mode.  Unchanged for >4 polls = direct mode.
    local function updateRelayState()
        local v
        base.pcall(function()
            local f = io.open(lfs.writedir() .. HEARTBEAT_FILE, 'r')
            if f then v = f:read('*a'); f:close() end
        end)
        if v and v ~= '' and v ~= _relayHbLast then
            _relayHbLast = v; _relayStale = 0; _relayMode = true
        else
            _relayStale = _relayStale + 1
            if _relayStale > 4 then _relayMode = false end
        end
    end
    local function relayMode() return _relayMode end
    local function relayCmd(flagNum)
        base.pcall(function()
            local f = io.open(lfs.writedir() .. PANEL_CMD_FILE, 'a')
            if f then f:write(tostring(flagNum) .. '\n'); f:close() end
        end)
    end

    -- --------------------------------------------------------- flag dispatch --
    -- Gotcha #1: when embedding inner string.format inside the chunk, double '%'.
    -- This chunk has no inner format so plain quoting is fine.
    local function fireFlag(flagNum)
        if relayMode() then
            relayCmd(flagNum)
            logInfo('relay cmd ' .. tostring(flagNum))
            return
        end
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
        tab              = 'login',  -- beta50: LOGIN owns the window until connect
        loggedIn         = false, -- flips on Olympus connect / local-mode pick
        dataMode         = nil,   -- 'olympus' | 'local' (nil = still on login)
        olympusActive    = false, -- true while live Olympus data is flowing
        connecting       = false, -- CONNECT pressed, waiting for first fetch
        congaOn          = false, -- DECKBOSS conga-line (taxi flow) overlay
        recoveryCase     = 'I',   -- 'I' | 'II' | 'III' — set by the CASE buttons;
                                  -- switches the marshalling/approach procedures.
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

    -- ── OLYMPUS CLIENT (beta50 — the primary data path) ──────────────────
    -- In-hook Olympus login: luasocket + binary-feed decoder, no agents.
    -- dofile'd (not auto-relied-on) so we hold the returned API table.
    local CGOLY = nil
    do
        local ok, mod = base.pcall(dofile,
            lfs.writedir() .. 'Scripts\\Hooks\\carrier-gui-olympus-client.lua')
        if ok and type(mod) == 'table' then
            CGOLY = mod
            logInfo('Olympus client loaded (socket=' .. tostring(mod.socketAvailable()) .. ')')
        else
            logErr('Olympus client failed to load: ' .. tostring(mod))
        end
    end

    -- login persistence: host/port (NOT the password) survive restarts
    local LOGIN_FILE = 'carriergui_olympus_login.txt'
    local function saveLogin(host, port)
        base.pcall(function()
            local f = io.open(lfs.writedir() .. LOGIN_FILE, 'w')
            if f then f:write('host=' .. host .. '\nport=' .. tostring(port) .. '\n'); f:close() end
        end)
    end
    local function loadLogin()
        local host, port = '', '3000'
        base.pcall(function()
            local f = io.open(lfs.writedir() .. LOGIN_FILE, 'r')
            if not f then return end
            for line in f:lines() do
                local k, v = line:match('^(%w+)=(.*)$')
                if k == 'host' then host = v elseif k == 'port' then port = v end
            end
            f:close()
        end)
        return host, port
    end

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
        -- recovery CASE broadcasts — two button sets (MARSHALL + CARRIER tabs)
        btnCaseM1         = 202,
        btnCaseM2         = 203,
        btnCaseM3         = 204,
        -- LSO calls (v1.3: WAVE OFF + CUT only; Bingo/RecovOK retired)
        btnWaveOff        = 210,
        btnCut            = 211,
    }

    -- Which dialog children belong to which tab (for show/hide). The two tab
    -- buttons and the status line stay visible on both tabs.
    -- beta50: LOGIN tab — the front door.  Shown alone until the user connects
    -- to Olympus (or picks local/host mode); then hidden behind the tab bar.
    local LOGIN_WIDGETS = {
        'lblLoginHdr','lblLoginSub','lblLoginSub2',
        'lblHostCap','edHost','lblPortCap','edPort','lblPassCap','edPass',
        'btnConnect','btnLocalMode','lblLoginStatus',
        'lblLoginHelp1','lblLoginHelp2','lblLoginHelp3',
        'btnUiScale','lblUiScaleCap',
    }
    local TAB_BAR = { 'btnTabMarshall','btnTabTower','btnTabLso','btnTabDeckboss','btnLogout' }
    -- TOWER: mini overhead + side view radars on top, three roster sections
    -- below, existing broadcast buttons at the bottom.
    -- TOWER (beta31): CASE I overhead circle + angels ladder + three bordered
    -- tables (STACK / CHARLIE'D / COMMENCING).  Widget names match
    -- Tools/gen_tower_stack.py.
    local TOWER_WIDGETS = {
        'lblTwrOhHdr','lblTwrSvHdr',
        -- scope box + angels ladder (shared by both cases)
        'tcBg','tcBT','tcBB','tcBL','tcBR',
        'tcSvBg','tcSvBT','tcSvBB','tcSvBL','tcSvBR',
        -- table headers (STACK + middle table shared; bottom is CASE I-only)
        'tsHdr','tdHdr',
    }
    -- CASE I-only TOWER drawing (overhead circle); hidden in CASE III.
    local TOWER_C1 = { 'tcAxH','tcAxV','tcShip',
        'tcPt2','tcPt3','tcPt4','tcPtN1','tcPtN2','tcPtN3','tcPtN4' }
    for i = 1, 52 do table.insert(TOWER_C1, 'tcRing' .. i) end
    -- beta58: the bottom COMMENCING table (tm*) is RETIRED — replaced by the
    -- LEVEL-OFF radar (lvl*, 700-1600 ft side profile: commence→break + spin).
    -- tm* widgets stay in the dlg but are force-hidden every showTab.
    local HIDDEN_WIDGETS = { 'tmHdr', 't3Hdr' }   -- t3Hdr: duplicate of lblTwrOhHdr
    for _, s in base.ipairs({ 'BT','BB','BL','BR','Sep','V1','V2','V3','V4','H1','H2','H3','H4','H5' }) do
        table.insert(HIDDEN_WIDGETS, 'tm' .. s)
    end
    for r = 1, 5 do for ccol = 1, 5 do table.insert(HIDDEN_WIDGETS, 'tmCell'..r..'_'..ccol) end end
    for _, n in base.ipairs({ 'lvlHdr','lvlBg','lvlBT','lvlBB','lvlBL','lvlBR',
                              'lvlL15','lvlL12','lvlL08','lvlC15','lvlC12','lvlC08','lvlCR' }) do
        table.insert(TOWER_C1, n)
    end
    for i = 1, 8 do
        table.insert(TOWER_C1, 'lvlDot' .. i)
        table.insert(TOWER_C1, 'lvlLbl' .. i)
    end
    -- CASE III-only TOWER drawing (marshal-holding OVERHEAD racetrack, t3*).
    local TOWER_C3 = { 't3Boat','t3Rad','t3RtIn','t3RtOut',
        't3Comm','t3CommL','t3MarshL' }
    for i = 1, 4 do table.insert(TOWER_C3, 't3GR' .. i) end
    for i = 1, 4 do table.insert(TOWER_C3, 't3LR' .. i) end
    for i = 1, 7 do table.insert(TOWER_C3, 't3RtT' .. i) end
    for i = 1, 7 do table.insert(TOWER_C3, 't3RtB' .. i) end
    for i = 1, 9  do table.insert(TOWER_WIDGETS, 'tcSvG' .. i) end
    for i = 1, 9  do table.insert(TOWER_WIDGETS, 'tcSvA' .. i) end
    for i = 1, 12 do table.insert(TOWER_WIDGETS, 'tcDot' .. i) end
    for i = 1, 12 do table.insert(TOWER_WIDGETS, 'tcLbl' .. i) end
    for i = 1, 12 do
        table.insert(TOWER_WIDGETS, 'tvec' .. i .. 'a')
        table.insert(TOWER_WIDGETS, 'tvec' .. i .. 'b')
    end
    for i = 1, 10 do table.insert(TOWER_WIDGETS, 'tcSv'  .. i) end
    for i = 1, 8  do table.insert(TOWER_WIDGETS, 'tsBtn' .. i) end
    for i = 1, 5  do table.insert(TOWER_WIDGETS, 'tdBtn' .. i) end
    for _, p in base.ipairs({ 'ts', 'td' }) do
        for _, s in base.ipairs({ 'BT','BB','BL','BR','Sep',
                                  'V1','V2','V3','V4',
                                  'H1','H2','H3','H4','H5' }) do
            table.insert(TOWER_WIDGETS, p .. s)
        end
    end
    for r = 1, 8 do for ccol = 1, 5 do table.insert(TOWER_WIDGETS, 'tsCell'..r..'_'..ccol) end end
    for r = 1, 5 do for ccol = 1, 5 do table.insert(TOWER_WIDGETS, 'tdCell'..r..'_'..ccol) end end
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
        'lblMarCaseHdr','btnCaseM1','btnCaseM2','btnCaseM3','btnMarshalBroadcast',
        'lblMotherHdr','lblBoat1','lblBoat2',
        'mCardN','mCardE','mCardS','mCardW',
        'lblMarStackHdr','sBoxT','sBoxB','sBoxL','sBoxR','sBoxSep','sBoxV',
        'lblStkH1','lblStkH2',
        'lblStkA2','lblStkA3','lblStkA4','lblStkA5','lblStkA6','lblStkA7',
        'sRung2','sRung3','sRung4','sRung5','sRung6',
        'lblMTblHdr',
        'mTblBT','mTblBB','mTblBL','mTblBR','mTblHL',
        'mTblV1','mTblV2','mTblV3','mTblV4','mTblV5',
        'lblMTh1','lblMTh2','lblMTh3','lblMTh4','lblMTh5','lblMTh6',
        'lblMarStatus',
        -- beta43: weather blurb + TURN INTO WIND (moved from CARRIER)
        'lblMarWx','lblWind',
        'btnWindStop','btnWind30m','btnWind60m','btnWind90m',
        'btnWind2h','btnWind4h','btnWind8h',
    }
    for i = 1,  5 do table.insert(MARSHALL_WIDGETS, 'rowMarCall' .. i) end
    for i = 1, 12 do table.insert(MARSHALL_WIDGETS, 'stkSlot' .. i) end
    for i = 1, 12 do table.insert(MARSHALL_WIDGETS, 'cczDot' .. i) end
    for i = 1, 12 do
        table.insert(MARSHALL_WIDGETS, 'mvec' .. i .. 'a')
        table.insert(MARSHALL_WIDGETS, 'mvec' .. i .. 'b')
    end
    for r = 1, 13 do for ccol = 1, 6 do
        table.insert(MARSHALL_WIDGETS, 'mCell' .. r .. '_' .. ccol)
    end end
    for i = 1,  39 do table.insert(MARSHALL_WIDGETS, 'mDotA' .. i) end
    for i = 1,  97 do table.insert(MARSHALL_WIDGETS, 'mDotB' .. i) end
    for i = 1, 193 do table.insert(MARSHALL_WIDGETS, 'mDotC' .. i) end
    -- DECKBOSS (beta32): top-down deck IMAGE + live aircraft overlay + ON DECK
    -- list + conga toggle.  The deck image (dbImg) is gated separately by
    -- showTab (like the MARSHALL radar image), so it is NOT in this list.
    local DECKBOSS_WIDGETS = {
        'lblDbHdr',
        -- deck-area frame + no-image hint (under the image)
        'dbBg','dbBT','dbBB','dbBL','dbBR','lblDbImgHint',
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
        -- beta43: SHIP SYSTEMS relocated from CARRIER (lights + beacons)
        'lblDbSysHdr',
        'lblLights','btnLightsOff','btnLightsAuto','btnLightsNav','btnLightsLaunch','btnLightsRecovery',
        'lblTacan','btnTacanOn','btnTacanOff','lblIcls','btnIclsOn','btnIclsOff',
        'lblLink4','btnLink4On','btnLink4Off','lblAcls','btnAclsOn','btnAclsOff',
    }
    -- (ELEVATOR tab removed — experimental setElevatorCommand test bed dropped.)
    -- LSO: racetrack visual (landmarks + outline + aircraft slot pool) +
    -- lights + PLAT cam (NVG / RESET CAM only) + ship + events.
    local LSO_WIDGETS = {
        -- scope box (shared by both cases)
        'pScope','pBordT','pBordB','pBordL','pBordR',
        -- Aircraft slot pool + bearing leaders
        'acftPat1','acftPat2','acftPat3','acftPat4','acftPat5','acftPat6','acftPat7','acftPat8',
        'acftDot1','acftDot2','acftDot3','acftDot4','acftDot5','acftDot6','acftDot7','acftDot8',
        'lvec1a','lvec1b','lvec2a','lvec2b','lvec3a','lvec3b','lvec4a','lvec4b',
        'lvec5a','lvec5b','lvec6a','lvec6b','lvec7a','lvec7b','lvec8a','lvec8b',
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
        -- Groove timer
        'lblGrooveHdr', 'lblGrooveTimer', 'lblGrooveLast',
        -- beta43: ON APPROACH list (deadspot bridge)
        'lblLsoApproachHdr', 'lblLsoApproachCols',
        'rowLsoApp1', 'rowLsoApp2', 'rowLsoApp3', 'rowLsoApp4',
    }

    -- v1.3-beta29: register the drawn-scope widgets (solid fills, rings,
    -- lines, arcs) with their tabs so they hide on tab switch.  Stale beta8
    -- names still present in the literal lists above are harmless —
    -- setWidgetVisible no-ops on missing children.  c.bgPanel (the whole-
    -- panel dark backdrop) is deliberately in NO list: always visible.
    local function addAll(list, names)
        for _, n in base.ipairs(names) do table.insert(list, n) end
    end
    -- (beta31: the old TOWER scope/ring/oh-dot widgets are gone; the new TOWER
    -- widget set is fully enumerated in the TOWER_WIDGETS block above.)
    -- CASE I-only LSO drawing (rounded racetrack + landmarks); hidden in CASE III.
    local LSO_C1 = { 'lblPatHdr','pLegT','pLegB','pShip','pShipBow',
        'lblPatInitial','lblPatBreak','lblPatDwnwd','lblPatAbeam',
        'lblPat180','lblPat90','lblPatGroove','lblPatTrap','lblPatCv' }
    -- counts MUST match gen_lso_pattern.py output (beta54: 13 arc dots per
    -- side, 8 groove dots) — extra names silently no-op and mask real drift
    for i = 1, 13 do table.insert(LSO_C1, 'pArcL' .. i) end
    for i = 1, 13 do table.insert(LSO_C1, 'pArcR' .. i) end
    for i = 1, 8  do table.insert(LSO_C1, 'pGrv'  .. i) end
    -- CASE III-only LSO drawing (final-approach OVERHEAD + distance gates, l3*).
    local LSO_C3 = { 'l3Hdr','l3CL','l3Boat','l3Cv','l3LblD' }
    for i = 1, 5 do table.insert(LSO_C3, 'l3GD' .. i) end
    for i = 1, 5 do table.insert(LSO_C3, 'l3LD' .. i) end
    for i = 1, 5 do table.insert(LSO_C3, 'l3LN' .. i) end
    -- (beta32: the DECKBOSS box-drawn silhouette is gone — replaced by the
    -- deck image (dbImg, gated by showTab) + frame/hint enumerated above.)

    -- Skins for the LED bar segments. setSkin(table) on a Static accepts a
    -- table in this shape. LIT = bright NVG green, DIM = near-black so the
    -- unlit cells fade into the panel background.
    local function makeLedSkin(color, lh)
        return {
            params = { name = 'staticSkin', textWrapping = false },
            states = {
                released = {
                    [1] = {
                        text = {
                            color      = color,
                            font       = 'DejaVuLGCSansCondensed-Bold.ttf',
                            lineHeight = lh or 32,
                        },
                    },
                },
            },
        }
    end
    local LED_SKIN_LIT = makeLedSkin('0x60ff80ff')
    local LED_SKIN_DIM = makeLedSkin('0x202020ff')
    -- (rebuilt scale-aware by rebuildRowSkins each window spawn)

    -- --------------------------------------------------------- show / hide ---
    -- Gotcha #4: setVisible(false) destroys the dialog. We toggle visibility
    -- via the SRS-style pattern: real setVisible(true), then either setSize(0,0)
    -- (= hidden) or restore to full size.
    -- NOTE: window sizing sites multiply by carrier.uiScale (dlg scales itself)
    local FULL_W, FULL_H = 540, 940   -- MUST match the .dlg W/H (940 since beta43's
                                      -- +40 for the LSO list; 900 clipped lblStatus)

    -- Set a value-flag (used to pass numeric params like flight count / minutes
    -- to the bridge before firing the action flag).
    local function setFlagValue(name, val)
        local chunk = string.format('trigger.action.setUserFlag("%s", %d)', name, val)
        base.pcall(function() net.dostring_in('server', chunk) end)
    end

    local function show()
        if not carrier.window then return end
        carrier.window:setSize(math.floor(FULL_W * (carrier.uiScale or 1) + 0.5), math.floor(FULL_H * (carrier.uiScale or 1) + 0.5))
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
        -- DEBOUNCE: hotkeys are bound per-window, and live-rescale orphans old
        -- windows whose callbacks may still fire — without this, one keypress
        -- after a rescale toggles twice (panel flashes and stays hidden).
        local nowD = DCS.getRealTime() or 0
        if nowD - (carrier._lastToggle or -9) < 0.35 then return end
        carrier._lastToggle = nowD
        if carrier.visible then hide() else show() end
        logInfo('toggle -> ' .. tostring(carrier.visible))
    end

    -- ------------------------------------------------------ tab switching ---
    local function setWidgetVisible(name, vis)
        local w = carrier.window and carrier.window[name]
        if w then base.pcall(function() w:setVisible(vis) end) end
    end

    -- setText / setBounds live here (with setWidgetVisible) so applyConga() —
    -- defined just below — can call setBounds.  (A local's scope starts AFTER
    -- its declaration, so these must precede their first caller.)
    local function setText(name, text)
        local w = carrier.window and carrier.window[name]
        if w then base.pcall(function() w:setText(text) end) end
    end

    -- UI SCALE (beta55): the dlg has a pure-arithmetic `local SCALE = N.NN`
    -- baked into its constructors (the DialogLoader env has NO globals — a
    -- file-reading block there killed the whole dialog in beta53/54).  The
    -- HOOK owns all file I/O: it reads the dlg's CURRENT line (that is what
    -- this session's window is built at), and the UI SIZE button rewrites the
    -- line in place for the next spawn.  carriergui_scale.txt persists the
    -- user's intent across mod updates (reconciled into the dlg at load).
    local DLG_PATH = lfs.writedir() .. 'Scripts\\Hooks\\carrier-gui.dlg'
    local SCALE_MARK = '%-%- CARRIERGUI_UI_SCALE'
    local function readDlgScale()
        local v = nil
        base.pcall(function()
            local f = io.open(DLG_PATH, 'r')
            if not f then return end
            local src = f:read('*a')
            f:close()
            v = tonumber(src:match('local SCALE = ([%d%.]+) ' .. SCALE_MARK))
        end)
        return v
    end
    local function writeDlgScale(mult)
        local okW = false
        base.pcall(function()
            local f = io.open(DLG_PATH, 'r')
            if not f then return end
            local src = f:read('*a')
            f:close()
            local rep, n = src:gsub('local SCALE = [%d%.]+ ' .. SCALE_MARK,
                string.format('local SCALE = %.2f -- CARRIERGUI_UI_SCALE', mult), 1)
            if n == 1 then
                local w = io.open(DLG_PATH, 'w')
                if w then w:write(rep); w:close(); okW = true end
            end
        end)
        return okW
    end
    local UI_SCALE = readDlgScale() or 1.0     -- what THIS session renders at
    do  -- reconcile saved intent (survives mod updates overwriting the dlg)
        local want = nil
        base.pcall(function()
            local f = io.open(lfs.writedir() .. 'carriergui_scale.txt', 'r')
            if f then
                local v = tonumber(f:read('*a'))
                f:close()
                if v and v >= 50 and v <= 250 then want = v / 100 end
            end
        end)
        if want and math.abs(want - UI_SCALE) > 0.001 then
            if writeDlgScale(want) then
                logInfo(string.format('UI scale: dlg set to %d%% (applies next DCS start)', want * 100))
            end
        end
    end
    carrier.uiScale = UI_SCALE
    carrier.writeDlgScale = writeDlgScale
    if UI_SCALE ~= 1.0 then logInfo(string.format('UI scale %d%%', UI_SCALE * 100)) end

    local function setBounds(name, x, y, w, h)
        local widg = carrier.window and carrier.window[name]
        if widg then
            base.pcall(function()
                local s = UI_SCALE
                widg:setBounds(math.floor(x * s + 0.5), math.floor(y * s + 0.5),
                               math.floor(w * s + 0.5), math.floor(h * s + 0.5))
            end)
        end
    end

    -- ── off-altitude flagging (beta58) ───────────────────────────────────
    -- Table altitude cells show the nearest 50 ft; >100 ft off the ASSIGNED
    -- marshal altitude turns the cell RED (setSkin swap — proven on statics
    -- by the LED bar).  Skins are rebuilt each window spawn so lineHeight
    -- tracks the live UI scale.
    local function mkRowSkin(color)
        return { params = { name = 'staticSkin', textWrapping = false },
                 states = { released = { [1] = { text = {
                     color = color, font = 'DejaVuLGCSansCondensed.ttf',
                     lineHeight = math.floor(14 * (UI_SCALE or 1) + 0.5) } } } } }
    end
    local ROWSKIN_STD = mkRowSkin('0xe0e0e0ff')
    local ROWSKIN_RED = mkRowSkin('0xff4040ff')
    local function rebuildRowSkins()
        ROWSKIN_STD = mkRowSkin('0xe0e0e0ff')
        ROWSKIN_RED = mkRowSkin('0xff4040ff')
        carrier._altRed = {}
        local lh = math.floor(32 * (UI_SCALE or 1) + 0.5)
        LED_SKIN_LIT = makeLedSkin('0x60ff80ff', lh)
        LED_SKIN_DIM = makeLedSkin('0x202020ff', lh)
    end
    -- altFt: true altitude; assignedAng: angels (thousands) or nil = no check
    local function setAltCell(name, altFt, assignedAng)
        setText(name, string.format('%5d', math.floor(altFt / 50 + 0.5) * 50))
        local red = false
        if assignedAng then red = math.abs(altFt - assignedAng * 1000) > 100 end
        carrier._altRed = carrier._altRed or {}
        if carrier._altRed[name] ~= red then
            carrier._altRed[name] = red
            local w = carrier.window and carrier.window[name]
            if w then base.pcall(function() w:setSkin(red and ROWSKIN_RED or ROWSKIN_STD) end) end
        end
    end

    -- Conga line — the COUNTER-CLOCKWISE taxi/respot flow over the DECKBOSS deck
    -- image, traced from the deck-spotting diagram.  Coords are deck-image pixels
    -- (box x 10..530, y 54..193; BOW = left, island/starboard = top, port =
    -- bottom, stern = right).  Flow: clear the landing area (right) → forward up
    -- THE STREET on the starboard side → around the bow to CATS 1 & 2 → down
    -- through the crotch → back to the WAIST CATS 3 & 4.  Tunable schematic.
    -- TRACED FROM THE USER'S DRAWING (grid map, 2026-07-15): a closed LOOP —
    -- bow-cat JBDs → aft down THE STREET/SIXPACK lane past the island → around
    -- at the stern/fantail → forward along the landing-area edge → back up to
    -- the bow JBDs — plus a SPUR from the landing-edge down to the waist cats.
    -- {-1,-1} = pen-up break between the loop and the spur.
    local CONGA_ANCHORS = {
        { 186, 104 },   -- cat 1/2 JBD area
        { 238,  98 },   -- aft down THE STREET
        { 293,  97 },
        { 337, 100 },   -- inboard of the island
        { 381, 102 },
        { 425, 104 },
        { 465, 103 },   -- patio corner
        { 483, 112 },   -- around the stern
        { 480, 126 },
        { 440, 131 },   -- forward along the landing-area edge
        { 398, 129 },
        { 363, 133 },
        { 320, 131 },
        { 280, 131 },
        { 240, 129 },
        { 207, 130 },
        { 190, 118 },   -- up to close the loop at the bow JBDs
        { 186, 104 },
        {  -1,  -1 },   -- pen up
        { 363, 133 },   -- spur: branch off the landing edge
        { 385, 157 },   -- down to WAIST CATS 3 & 4
    }
    local CONGA_POOL = 56
    local function applyConga()
        local show = (carrier.tab == 'deckboss') and carrier.congaOn
        if not show then
            for i = 1, CONGA_POOL do setBounds('congaDot' .. i, -300, -300, 8, 8) end
            return
        end
        -- walk the anchor polyline, a dot every ~16 px; {-1,-1} anchors are
        -- pen-up breaks (loop vs spur are separate strokes).
        local dots, seg = {}, 0
        for a = 1, #CONGA_ANCHORS - 1 do
            local x1, y1 = CONGA_ANCHORS[a][1],   CONGA_ANCHORS[a][2]
            local x2, y2 = CONGA_ANCHORS[a+1][1], CONGA_ANCHORS[a+1][2]
            if x1 >= 0 and x2 >= 0 then
                local dx, dy = x2 - x1, y2 - y1
                local len = math.sqrt(dx*dx + dy*dy)
                local steps = math.max(1, math.floor(len / 16 + 0.5))
                for s = 0, steps - 1 do
                    seg = seg + 1
                    if seg <= CONGA_POOL then
                        dots[seg] = { math.floor(x1 + dx * s / steps),
                                      math.floor(y1 + dy * s / steps) }
                    end
                end
            end
        end
        local last = CONGA_ANCHORS[#CONGA_ANCHORS]
        if seg < CONGA_POOL and last[1] >= 0 then
            seg = seg + 1
            dots[seg] = { last[1], last[2] }
        end
        for i = 1, CONGA_POOL do
            local p = dots[i]
            if p then setBounds('congaDot' .. i, p[1] - 4, p[2] - 4, 8, 8)
            else      setBounds('congaDot' .. i, -300, -300, 8, 8) end
        end
    end

    local function showTab(tab)
        -- pre-login the LOGIN tab owns the window, no exceptions
        if tab ~= 'login' and not carrier.loggedIn then tab = 'login' end
        carrier.tab = tab
        local loginVis    = (tab == 'login')
        local marshallVis = (tab == 'marshall')
        local towerVis    = (tab == 'tower')
        local lsoVis      = (tab == 'lso')
        local deckbossVis = (tab == 'deckboss')
        -- login owns the window until connected; tab bar hides with it
        for _, n in base.ipairs(LOGIN_WIDGETS) do setWidgetVisible(n, loginVis) end
        for _, n in base.ipairs(TAB_BAR)       do setWidgetVisible(n, not loginVis) end
        for _, n in base.ipairs(MARSHALL_WIDGETS) do setWidgetVisible(n, marshallVis) end
        for _, n in base.ipairs(TOWER_WIDGETS)    do setWidgetVisible(n, towerVis)    end
        for _, n in base.ipairs(LSO_WIDGETS)      do setWidgetVisible(n, lsoVis)      end
        for _, n in base.ipairs(DECKBOSS_WIDGETS) do setWidgetVisible(n, deckbossVis) end
        -- Case-specific drawings.  CASE II is a HYBRID — instrument marshal like
        -- III, visual terminal like I:
        --   TOWER — marshal-holding racetrack (t3*) for II & III; the 5 nm
        --           overhead circle (tc*) for CASE I only.
        --   LSO   — instrument glideslope final (l3*) for CASE III only; the
        --           visual overhead racetrack (p*/acft*) for I & II (CASE II
        --           completes the recovery with a visual break at the ship).
        local case       = carrier.recoveryCase
        local towerInstr = (case == 'II' or case == 'III')
        local lsoInstr   = (case == 'III')
        for _, n in base.ipairs(TOWER_C1) do setWidgetVisible(n, towerVis and not towerInstr) end
        for _, n in base.ipairs(TOWER_C3) do setWidgetVisible(n, towerVis and towerInstr)     end
        for _, n in base.ipairs(LSO_C1)   do setWidgetVisible(n, lsoVis   and not lsoInstr)   end
        for _, n in base.ipairs(LSO_C3)   do setWidgetVisible(n, lsoVis   and lsoInstr)       end
        -- Radar scope image overlay: only on MARSHALL, and only if the bundled
        -- TGA is present in the DCS install (else the dot rings show through).
        setWidgetVisible('mScopeImg', marshallVis and carrier.radarImgOk == true)
        -- DECKBOSS deck image: show only when its TGA is installed; otherwise
        -- the dark frame + "run the LSO patch" hint show instead.
        setWidgetVisible('dbImg',        deckbossVis and carrier.deckImgOk == true)
        setWidgetVisible('lblDbImgHint', deckbossVis and carrier.deckImgOk ~= true)
        -- shared status bar: noise on the login screen (bridge warnings are
        -- irrelevant before a mode is chosen) — hide it there
        setWidgetVisible('lblStatus', not loginVis)
        -- retired widgets (dlg keeps them; never shown)
        for _, n in base.ipairs(HIDDEN_WIDGETS) do setWidgetVisible(n, false) end
        applyConga()   -- re-draw / hide the conga overlay for this tab
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

    -- ── Magnetic variation ───────────────────────────────────────────────
    -- DCS carrier ops — BRC, marshal radials, TACAN, ICLS — are all MAGNETIC,
    -- but every heading we read is TRUE (mission getPosition() and the Olympus
    -- feed).  We keep TRUE internally so ALL scope/racetrack geometry stays
    -- correct, and convert to magnetic ONLY at the text readouts via mag().
    -- Variation is a per-theatre estimate from the carrier's lat/lon (good to
    -- ~1-2°, within BRC rounding); unknown location -> 0 (= true, no change).
    local MAGVAR_ZONES = {
        -- latMin,latMax,  lonMin, lonMax,  magvarEast(+)
        {  39, 48,    36,   48,   8 },   -- Caucasus (Black Sea / Georgia, ~2026 WMM)
        {  23, 31,    47,   60,   2 },   -- Persian Gulf
        {  31, 38,    32,   43,   5 },   -- Syria
        {  26, 31,    32,   35,   5 },   -- Sinai
        {  33, 39,  -119, -113,  12 },   -- Nevada (NTTR)
        {  47, 52,    -6,    3,  -1 },   -- Normandy / Channel
        {  12, 16,   143,  147,   1 },   -- Marianas
        {  66, 72,    14,   42,  15 },   -- Kola
        {  28, 40,    59,   75,   3 },   -- Afghanistan
    }
    -- EXACT declination via DCS's own lua-magvar.dll — the same call the
    -- Mission Editor status bar uses (me_statusbar.lua):
    --   require('magvar'); magvar.init(month, year); get_mag_decl(lat, lon) → RADIANS
    -- Per-position AND per-mission-date, so it matches the jets' HSI exactly
    -- (the hand table was ~2° off vs the miz).  Zone table stays as fallback.
    local _mv = nil
    do
        local okMV, mv = base.pcall(require, 'magvar')
        if okMV and type(mv) == 'table' and mv.get_mag_decl then _mv = mv end
    end
    local _mvInited = false
    local function magvarFor(lat, lon)
        if not lat or not lon then return 0 end
        if _mv then
            if not _mvInited then
                base.pcall(function()
                    local d = DCS.getCurrentMission().mission.date
                    _mv.init(d.Month or 6, d.Year or 2016)
                end)
                _mvInited = true   -- init once per mission (reset on sim stop)
            end
            local okD, decl = base.pcall(_mv.get_mag_decl, lat, lon)
            if okD and type(decl) == 'number' then return math.deg(decl) end
        end
        for _, z in base.ipairs(MAGVAR_ZONES) do
            if lat >= z[1] and lat <= z[2] and lon >= z[3] and lon <= z[4] then
                return z[5]
            end
        end
        return 0
    end
    carrier.resetMagvarInit = function() _mvInited = false end
    -- TRUE degrees -> MAGNETIC for display (integer, 0..359).
    local function mag(h)
        if not h then return h end
        return math.floor((h - (carrier.magvar or 0)) % 360 + 0.5)
    end
    carrier.mag = mag   -- expose for readers defined earlier in the file

    local function readShipState()
        -- v1.3-beta29: primary source is the mission query (carrier.q.ship);
        -- the bridge file only exists on desanitized servers.
        local content = (carrier.q and carrier.q.ship) or ''
        if content == '' and not carrier.olympusActive then
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
        -- Magnetic variation for this carrier's location (drives mag() readouts).
        -- Only recompute when a location is present, so a lat/lon-less poll (e.g.
        -- a transient coord.LOtoLL failure) keeps the last-good value instead of
        -- snapping every heading by ~magvar for one frame.
        if s.lat and s.lon then
            carrier.magvar = magvarFor(tonumber(s.lat), tonumber(s.lon))
        end
        carrier.shipSpd       = tonumber(s.spd) or carrier.shipSpd
        carrier.shipHdg       = tonumber(s.hdg)
        carrier.shipWindFrom  = tonumber(s.wind_from)
        carrier.shipWindKts   = tonumber(s.wind_kts)
        carrier.shipHeadKts   = tonumber(s.head_kts)
        carrier.shipCrossKts  = tonumber(s.cross_kts)
        carrier.callsign      = s.callsign or carrier.callsign
        carrier.altimeter     = s.altimeter or carrier.altimeter
        carrier.shipFB        = tonumber(s.fb) or carrier.shipFB
        carrier.shipTod       = tonumber(s.tod) or carrier.shipTod
        carrier.shipId        = tonumber(s.id) or carrier.shipId
        -- (elevator args now come from pollElevatorArgs, which is independent of
        -- data mode so the instrument works even sitting on the login tab)
        -- Live weather → cloud/vis text used by the marshal call AND the blurb.
        carrier.wxCloudDens = tonumber(s.cloud_dens) or carrier.wxCloudDens
        carrier.wxCloudBase = tonumber(s.cloud_base) or carrier.wxCloudBase
        carrier.wxVisM      = tonumber(s.vis_m) or carrier.wxVisM
        carrier.wxPrecip    = tonumber(s.precip) or carrier.wxPrecip
        if not carrier.window then return end
        if carrier.window.lblShipHdg then
            local txt = carrier.shipHdg and ('HDG: ' .. string.format('%03d', mag(carrier.shipHdg)) .. '°M') or 'HDG: --'
            base.pcall(function() carrier.window.lblShipHdg:setText(txt) end)
        end
        if carrier.window.lblShipWind then
            local txt = 'Wind: --'
            if carrier.shipWindFrom and carrier.shipWindKts then
                txt = string.format('Wind %03d/%d  (%dH/%dX)',
                    carrier.shipWindFrom, carrier.shipWindKts,
                    carrier.shipHeadKts or 0, carrier.shipCrossKts or 0)
            elseif carrier.olympusActive and carrier.shipSpd then
                -- Olympus feed has no ambient wind; show the ship's own speed
                -- (the dominant WOD component when steaming into the wind).
                txt = string.format('Ship %d kt  (ambient wind: local mode)', carrier.shipSpd)
            end
            base.pcall(function() carrier.window.lblShipWind:setText(txt) end)
        end
    end

    -- ── Olympus-mode weather backfill ────────────────────────────────────
    -- The Olympus units feed carries NO QNH/weather/wind, but a CLIENT sitting
    -- in the mission holds the mission's static weather locally via
    -- DCS.getCurrentMission().  Fill the gaps from there (was: altimeter stuck
    -- on the 29.92 default while the miz said 29.45).  Same field conventions
    -- as CG_QUERY server-side: qnh mmHg/25.4 → inHg; atGround.dir = FROM.
    local function readClientMissionWx()
        local okM, wx = base.pcall(function()
            return DCS.getCurrentMission().mission.weather
        end)
        if not okM or type(wx) ~= 'table' then return end
        if wx.qnh then carrier.altimeter = string.format('%.2f', wx.qnh / 25.4) end
        base.pcall(function()
            local c = wx.clouds
            if c then
                carrier.wxCloudDens = c.density or carrier.wxCloudDens
                if c.base then carrier.wxCloudBase = math.floor(c.base * 3.28084) end
                carrier.wxPrecip = c.iprecptns or carrier.wxPrecip
            end
            if wx.visibility and wx.visibility.distance then
                carrier.wxVisM = wx.visibility.distance
            end
        end)
        base.pcall(function()
            local g = wx.wind and wx.wind.atGround
            if not g then return end
            local spdMs = g.speed or 0
            -- MIZ CONVENTION: weather.wind.*.dir is the direction the wind blows
            -- TOWARD (the ME UI converts to FROM for display; weather injectors
            -- add 180 when writing).  FROM = dir + 180.
            carrier.shipWindFrom = math.floor((g.dir or 0) + 180.5) % 360
            carrier.shipWindKts  = math.floor(spdMs * 1.94384 + 0.5)
            -- over-deck components on the angled deck (ambient + ship motion),
            -- mirroring CG_QUERY's decomposition signs
            if carrier.shipHdg and carrier.shipSpd then
                local toR  = math.rad((g.dir or 0) % 360)   -- stored dir IS "toward"
                local wN, wE = math.cos(toR) * spdMs, math.sin(toR) * spdMs
                local shR  = math.rad(carrier.shipHdg)
                local sMs  = (carrier.shipSpd or 0) / 1.94384
                local relN, relE = wN - math.cos(shR) * sMs, wE - math.sin(shR) * sMs
                local fbR = math.rad((carrier.shipHdg - 9) % 360)
                local fdx, fdz = math.cos(fbR), math.sin(fbR)
                local fwd = relN * fdx + relE * fdz
                local crs = relN * (-fdz) + relE * fdx
                carrier.shipHeadKts  = math.floor(-fwd * 1.94384 + 0.5)
                carrier.shipCrossKts = math.floor(crs * 1.94384 + 0.5)
            end
        end)
    end

    -- Recovery events tailing: read carriergui_lso_events.txt (bridge appends
    -- when inbound aircraft cross CASE III milestones) and show last 3 lines.
    local LSO_EVENTS_FILE = 'carriergui_lso_events.txt'

    local function readLsoEvents()
        -- The events file is written ONLY by the mission bridge (CASE III
        -- milestone crossings).  In Olympus mode there's no bridge, so the file
        -- on disk is stale from a previous local session — don't show it.
        if carrier.olympusActive then
            if carrier.window then
                base.pcall(function() carrier.window.lblEvent1:setText('(recovery events: local / bridge mode only)') end)
                base.pcall(function() carrier.window.lblEvent2:setText('') end)
                base.pcall(function() carrier.window.lblEvent3:setText('') end)
            end
            return
        end
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
    -- v1.3-beta29: MISSION QUERY — the hook pulls all live data itself via
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
                                        if un.name and un.onboard_num and tostring(un.onboard_num) ~= '' then
                                            -- Unit:getName() returns the RAW ME unit name, so key by
                                            -- that directly.  ALSO key by the dict-resolved name for
                                            -- localized missions (getValueDictByKey alone returns nil
                                            -- for plain names — the old bug that emptied this map).
                                            local board = tostring(un.onboard_num)
                                            Q.mx[un.name] = board
                                            local okr, resolved = pcall(env.getValueDictByKey, un.name)
                                            if okr and resolved and resolved ~= '' and resolved ~= un.name then
                                                Q.mx[resolved] = board
                                            end
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
    -- ONE decimal: rounding to whole degrees BEFORE the magvar subtraction caused
    -- +-1 deg display disagreements vs the game (double rounding)
    shipLines[#shipLines + 1] = string.format('hdg=%.1f', hdg)
    shipLines[#shipLines + 1] = string.format('fb=%.1f', fb)
    -- carrier lat/lon → the hook derives magnetic variation for BRC/radials.
    pcall(function()
        local lat, lon = coord.LOtoLL(cp)
        shipLines[#shipLines + 1] = 'lat=' .. string.format('%.4f', lat)
        shipLines[#shipLines + 1] = 'lon=' .. string.format('%.4f', lon)
    end)
    pcall(function()
        local v = carrier:getVelocity()
        shipLines[#shipLines + 1] = 'spd=' .. math.floor(math.sqrt(v.x*v.x + v.z*v.z) * 1.94384 + 0.5)
    end)
    -- carrier runtime object id — the ELEVATOR tab feeds this to the GUI-state
    -- setElevatorCommand(shipId, ...).  Unit:getID() is the sim object id the
    -- AirBoss screens key their room by.
    pcall(function() shipLines[#shipLines + 1] = 'id=' .. tostring(carrier:getID()) end)
    -- (elevator animation args are read by the standalone CG_ELEV_QUERY poller,
    -- which runs regardless of login/data mode — see pollElevatorArgs)

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
    -- Fallback: mission-editor ground wind.  MIZ stores dir as the direction
    -- the wind blows TOWARD (ME UI shows FROM) — convert: FROM = dir + 180.
    if not gotWind then
        pcall(function()
            local g = env.mission.weather.wind.atGround
            if g then
                shipLines[#shipLines + 1] = 'wind_from=' .. math.floor((g.dir or 0) + 180.5) % 360
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
        -- AUTHORITATIVE DCS ATC callsigns (Scripts/Speech/common.lua, MARSHAL-NN).
        local CS = {
            CVN_71 = 'Rough Rider',      -- Theodore Roosevelt (MARSHAL-71)
            CVN_72 = 'Union',            -- Abraham Lincoln     (MARSHAL-72)
            CVN_73 = 'Warfighter',       -- George Washington   (MARSHAL-73)
            CVN_74 = 'Courage',          -- John C. Stennis     (MARSHAL-74)
            CVN_75 = 'Lone Warrior',     -- Harry S. Truman     (MARSHAL-75)
            Stennis = 'Courage',         -- older Stennis asset
            Forrestal = 'Forrestal',
            VINSON = 'Gold Eagle',       -- Carl Vinson         (MARSHAL-70)
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

    -- Live weather so the marshal call + blurb MATCH the mission: cloud density
    -- (0-10), cloud base (ft), surface visibility (m, reduced by fog/dust), and
    -- precipitation (0 none / 1 rain / 2 thunderstorm).  All nil-guarded.
    pcall(function()
        local wx = env and env.mission and env.mission.weather
        if not wx then return end
        local dens = (wx.clouds and wx.clouds.density) or 0
        local base = (wx.clouds and wx.clouds.base) or 0
        shipLines[#shipLines + 1] = 'cloud_dens=' .. math.floor(dens + 0.5)
        shipLines[#shipLines + 1] = 'cloud_base=' .. math.floor(base * 3.28084 + 0.5)
        local vis = (wx.visibility and wx.visibility.distance) or 80000
        if wx.enable_fog and wx.fog and wx.fog.visibility and wx.fog.visibility < vis then
            vis = wx.fog.visibility
        end
        if wx.enable_dust and wx.dust_density and wx.dust_density > 0 and wx.dust_density < vis then
            vis = wx.dust_density
        end
        shipLines[#shipLines + 1] = 'vis_m=' .. math.floor(vis + 0.5)
        local precip = (wx.clouds and wx.clouds.iprecptns) or 0
        shipLines[#shipLines + 1] = 'precip=' .. math.floor(precip + 0.5)
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

                            -- Support aircraft (tankers / AWACS) are IGNORED —
                            -- they aren't part of a recovery.  Detect by TYPE and
                            -- by CALLSIGN (catches an A-6E flying as "Shell", an
                            -- E-2 as "Wizard", etc.) and skip them entirely.
                            local tn = u:getTypeName() or ''
                            local support =
                                   tn:find('KC%-?130') or tn:find('KC%-?135') or tn:find('KC135')
                                or tn:find('Tanker')  or tn:find('IL%-78')
                                or tn:find('E%-3')     or tn:find('E%-2')   or tn:find('A%-50')
                                or tn:find('KJ%-2000') or tn:find('AWACS')  or tn:find('Tu%-95')
                                -- A-6 = the F-14 community's recovery tanker (buddy stores)
                                or tn:find('A%-6')     or tn:find('A_6')    or tn:find('Intruder')
                                or cs:find('Shell')  or cs:find('Texaco') or cs:find('Arco')
                                or cs:find('Mobil')  or cs:find('Roman')
                                or cs:find('Wizard') or cs:find('Magic')  or cs:find('Overlord')
                                or cs:find('Focus')  or cs:find('Darkstar') or cs:find('Sentry')
                            if support then return end   -- tankers/AWACS: ignore entirely
                            -- helos are shown (carrier ops) but marked so the
                            -- on-station guard bird can be suppressed below.
                            local okH, isHelo = pcall(function() return u:hasAttribute('Helicopters') end)
                            isHelo = okH and isHelo
                            local role = isHelo and 'HELO' or 'REC'

                            local up = u:getPoint()
                            local dx, dz = up.x - cp.x, up.z - cp.z
                            local nm  = math.sqrt(dx * dx + dz * dz) / NM
                            local brg = norm(math.deg(math.atan2(dz, dx)))
                            local altM = up.y
                            local altFt = math.floor(altM * 3.28084)
                            local vel = u:getVelocity()
                            local ias = math.floor(math.sqrt(vel.x * vel.x + vel.z * vel.z) * 1.94384)
                            local achdg = norm(math.deg(math.atan2(vel.z, vel.x)))
                            local inAir = u:inAir()
                            -- suppress the airborne on-station plane-guard helo
                            -- (close + low); recovering helos still show.
                            if isHelo and inAir and nm < 3 and altFt < 1000 then return end

                            seen[modex] = true
                            if not Q.fs[modex] then Q.fs[modex] = now end
                            local inT = math.floor(now - Q.fs[modex])

                            local lastNm = Q.ln[modex] or nm
                            local closing = (nm < lastNm - 0.05)
                            Q.ln[modex] = nm

                            -- On deck ONLY if it's actually sitting/taxiing on the
                            -- deck: low ground speed AND inside the deck footprint
                            -- (~333 m long x ~77 m wide, plus the angled-deck
                            -- overhang to port).  This rejects (a) a unit well
                            -- astern (plane-guard / orbiting tanker) by footprint,
                            -- and (b) an aircraft flying low OVER the deck — which
                            -- can momentarily read not-inAir — by speed.  DCS
                            -- auto-callsigns mean a transiting tanker shows as
                            -- "Arco/Texaco/Shell", so this keeps fly-overs off.
                            -- Deck-frame position relative to the ship (metres):
                            -- acAhead(+) = toward the bow along the BRC, acStbd(+)
                            -- = to starboard.  Shared by the on-deck test, the
                            -- pattern classifier, AND the LSO live relative plot.
                            local acAhead = dx * cpx.x  + dz * cpx.z
                            local acStbd  = dx * (-cpx.z) + dz * cpx.x

                            if (not inAir) and ias < 50 then
                                if math.abs(acAhead) < 185 and acStbd > -65 and acStbd < 55 then
                                    deck[#deck + 1] = modex .. '|' .. math.floor(acAhead + 0.5) .. '|' .. math.floor(acStbd + 0.5)
                                end
                            end
                            if not inAir then return end

                            -- CASE I pattern classification — models the actual
                            -- left-hand overhead pattern using the jet's deck-
                            -- frame position AND its heading (not just bearing):
                            --   dBRC ~ 0  -> flying up the BRC (upwind),
                            --   dREC ~ 0  -> flying downwind (reciprocal).
                            -- Flow: INITIAL up the starboard side ~800' -> BREAK
                            -- over the bow -> DOWNWIND to port ~1.2 nm / 600' ->
                            -- ABEAM -> 180 (descending left turn ~300') -> GROOVE
                            -- (lined up on final, low, closing) -> TRAP.
                            -- Thresholds in metres/deg — TUNE vs live AI.
                            local point = 'enroute'
                            if nm <= 4 then
                                local dBRC  = math.abs(angDelta(achdg, hdg))
                                local dREC  = math.abs(angDelta(achdg, norm(hdg + 180)))
                                if nm < 0.45 then
                                    point = 'TRAP'
                                elseif acAhead < 300 and math.abs(acStbd) < 650 and altM < 150 and closing and dBRC < 60 then
                                    point = 'GROOVE'
                                elseif acStbd < -650 and dREC < 55 then
                                    if acAhead > 350 then point = 'DOWNWIND'
                                    elseif acAhead > -550 then point = 'ABEAM'
                                    else point = '180' end
                                elseif acStbd < -300 and acAhead < -250 and altM < 175 then
                                    point = '180'
                                elseif acStbd > -550 and dBRC < 45 and altM > 165 then
                                    point = 'INITIAL'
                                elseif altM > 150 and dBRC >= 45 and dBRC <= 130 and acAhead > -300 then
                                    point = 'BREAK'
                                else
                                    point = 'pattern'
                                end
                            end

                            -- Deck-frame position of the aircraft, relative to
                            -- the ship: jx = nm to STARBOARD (+) / port (-),
                            -- jy = nm AHEAD (+) along the final bearing.  This
                            -- is what the TOWER overhead circle plots, and what
                            -- drives the point-3 auto-commence.
                            local fbR = math.rad(fb)
                            local jy  = ( dx * math.cos(fbR) + dz * math.sin(fbR)) / NM
                            local jx  = (-dx * math.sin(fbR) + dz * math.cos(fbR)) / NM
                            -- Phase around the CASE I holding circle (centre 5 nm
                            -- to PORT of the ship, boat on the right edge):
                            -- pt1 = 0deg, pt2 = 90, pt3 = 180, pt4 = 270 (CCW).
                            local PR    = 5
                            local phase = norm(math.deg(math.atan2(jy, jx + PR)))

                            -- HOLD / CHARLIE / COMMENCING state machine.  A jet
                            -- only commences once it has been Charlie'd (from the
                            -- TOWER panel); it then auto-commences when it swings
                            -- through point 3 (far side of the circle from the
                            -- boat) or is clearly rolling into the groove.
                            local state = 'HOLD'
                            if Q.co[modex] then
                                state = 'COMMENCING'
                            elseif Q.ch[modex] then
                                local atPt3   = (nm < 12) and (math.abs(angDelta(phase, 180)) < 35)
                                local onFinal = (altM < 250) and (nm < 3) and closing
                                if atPt3 or onFinal then
                                    Q.co[modex] = true
                                    state = 'COMMENCING'
                                else
                                    state = 'CHARLIE'
                                end
                            end

                            if nm < 25 then
                                -- carry deck-frame jx/jy (nm, ship-relative) for
                                -- the overhead circle + tables.
                                stackRaw[#stackRaw + 1] = {
                                    modex = modex, altFt = altFt, ias = ias,
                                    inT = inT, point = point, state = state,
                                    jx = jx, jy = jy,
                                }
                            end
                            if nm < 60 and nm > 8 then
                                ccz[#ccz + 1] = string.format('%s|%d|%.1f|%d|%d|%s|%d', modex, math.floor(brg + 0.5), nm, altFt, ias, role, math.floor(achdg + 0.5))
                            end
                            if nm < 12 then
                                -- modex|alt|ias|point|acAhead|acStbd  (metres,
                                -- deck-frame).  Out to 12 nm so the CASE III LSO
                                -- approach profile sees the platform (10 nm);
                                -- CASE I only uses the <5 nm pattern points.
                                pattern[#pattern + 1] = string.format('%s|%d|%d|%s|%d|%d',
                                    modex, altFt, ias, point,
                                    math.floor(acAhead + 0.5), math.floor(acStbd + 0.5))
                            end
                        end)
                    end
                end
            end
        end
    end

    -- TOWER stack rows.  beta31: the overhead circle is ship-anchored (boat on
    -- the right edge), so we emit each aircraft's deck-frame jx/jy directly —
    -- no centroid.  Format: modex|alt|ias|inT|point|state|jx|jy
    local stack = {}
    for _, r in pairs(stackRaw) do
        stack[#stack + 1] = string.format('%s|%d|%d|%d|%s|%s|%.2f|%.2f',
            r.modex, r.altFt, r.ias, r.inT, r.point, r.state, r.jx, r.jy)
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

    -- ── ELEVATOR RESEARCH INSTRUMENT (v1.4) ──────────────────────────────
    -- Deliberately standalone: it does NOT go through runMissionQuery, so it
    -- keeps working while the panel is still on the login tab (dataMode nil)
    -- and in Olympus mode.  Runs in the MISSION (server) state, so the values
    -- are AUTHORITATIVE — if an arg moves here it moved for every client.
    -- Arg numbers are from the stock ship DB (USS_CVN_7X.lua):
    --   elevators = {57,58,59,60}   elevators_doors = {47,48,53,54}
    -- Stock DCS drives these from the AI deck cycle (GT.Elevators in
    -- USS_Nimitz_RunwaysAndRoutes.lua: 1/2/3 = DESPAWN, 4 = SPAWN).
    -- Pure getDrawArgumentValue reads: sanctioned API, IC-safe.
    local CG_ELEV_QUERY = [==[
local okE, resE = pcall(function()
    local cv = nil
    for _, side in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
        local gs = coalition.getGroups(side, Group.Category.SHIP)
        if gs then
            for _, g in pairs(gs) do
                if g:isExist() then
                    for _, u in pairs(g:getUnits() or {}) do
                        if u:isExist() then
                            local tn = u:getTypeName() or ''
                            if tn:find('CVN') or tn:find('Stennis') or tn:find('VINSON') or tn:find('Forrestal') then
                                cv = u
                                break
                            end
                        end
                    end
                end
                if cv then break end
            end
        end
        if cv then break end
    end
    if not cv then return 'NOCV' end
    local e, d = {}, {}
    for _, a in pairs({57, 58, 59, 60}) do
        e[#e + 1] = string.format('%.3f', cv:getDrawArgumentValue(a) or 0)
    end
    for _, a in pairs({47, 48, 53, 54}) do
        d[#d + 1] = string.format('%.3f', cv:getDrawArgumentValue(a) or 0)
    end
    return table.concat(e, ',') .. '|' .. table.concat(d, ',')
end)
if okE then return tostring(resE) end
return 'ERR|' .. tostring(resE)
]==]

    local function elevNums(s)
        local t = {}
        for v in tostring(s):gmatch('[^,]+') do t[#t + 1] = tonumber(v) or 0 end
        return t
    end

    local function pollElevatorArgs()
        local ok, res = base.pcall(function()
            return net.dostring_in('server', CG_ELEV_QUERY)
        end)
        if not ok or base.type(res) ~= 'string' or res == '' then return end
        if res == 'NOCV' then
            if not carrier.elevNoCvLogged then
                carrier.elevNoCvLogged = true
                logInfo('elevator poll: no carrier in mission yet')
            end
            return
        end
        if res:sub(1, 4) == 'ERR|' then
            if not carrier.elevErrLogged then
                carrier.elevErrLogged = true
                logErr('elevator poll failed: ' .. res:sub(5, 160))
            end
            return
        end
        local es, ds = res:match('^([^|]*)|(.*)$')
        if not es then return end
        local cur = elevNums(es)
        local prev = carrier.elevArgs
        if prev then
            for i = 1, #cur do
                local a, b = prev[i] or 0, cur[i] or 0
                if math.abs(a - b) > 0.01 then
                    logInfo(string.format(
                        'ELEVATOR %d MOVED %.3f -> %.3f  (doors=%s)', i, a, b, ds))
                end
            end
        else
            logInfo('elevator args (baseline): ' .. es .. '  doors: ' .. ds)
        end
        carrier.elevArgs  = cur
        carrier.elevDoors = elevNums(ds)
    end

    local function runMissionQuery()
        -- OLYMPUS mode (primary): the in-hook client owns the picture — copy
        -- its latest computed sections into carrier.q.  Readers consume them
        -- exactly like mission-query output.
        if carrier.dataMode == 'olympus' then
            carrier.olympusActive = (CGOLY ~= nil) and CGOLY.active() or false
            local res = CGOLY and CGOLY.result and CGOLY.result()
            local st  = CGOLY and CGOLY.status and CGOLY.status()
            local fresh = st and (st.ageSecs == nil or st.ageSecs <= 10)
            if res and fresh then
                carrier.q.ship    = res.ship or ''
                carrier.q.stack   = res.stack or ''
                carrier.q.ccz     = res.ccz or ''
                carrier.q.pattern = res.pattern or ''
                carrier.q.deck    = res.deck or ''
            elseif not fresh then
                -- stale feed: blank the picture (the frame watchdog shows the
                -- STALE banner) instead of freezing on old data
                carrier.q.ship, carrier.q.stack, carrier.q.ccz = '', '', ''
                carrier.q.pattern, carrier.q.deck = '', ''
            end
            return
        end
        carrier.olympusActive = false
        if carrier.dataMode ~= 'local' then return end   -- still on the login tab
        updateRelayState()   -- refresh auto relay-mode from the agent heartbeat
        -- Relay mode: skip the server query entirely (it can't reach a remote
        -- mission and may return junk).  Leaving carrier.q empty makes every
        -- reader fall back to slurp() of the companion-written files.
        if relayMode() then return end
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

    local function fmtTime(sec)
        return string.format('%02d:%02d', math.floor(sec / 60), sec % 60)
    end

    -- ─── TOWER: CASE I overhead circle + angels ladder + 3 bordered tables ──
    -- Stack rows: modex|alt|ias|inT|point|state|jx|jy  (jx = nm starboard,
    -- jy = nm ahead, both deck-frame relative to the ship).  The overhead
    -- circle is ship-anchored — boat on the far-right edge, the 5 nm holding
    -- ring to port.  Rows are split HOLD / CHARLIE'D / COMMENCING and filled
    -- into the three bordered tables; STACK rows are clickable (→ Charlie).
    -- CASE III TOWER: marshal-holding OVERHEAD (boat at top, FB radial astern) +
    -- the altitude ladder relabelled 5..13k.  Recovering aircraft (CCZ data) are
    -- projected onto the radial (along astern + lateral).  Matches gen_case3.py.
    -- shared between the TOWER (overhead) and MARSHALL readers so EAT push
    -- times are identical regardless of which tab is open.
    local function clockFromSecs(s)
        s = s % 86400
        return string.format('%02d:%02d', math.floor(s / 3600), math.floor((s % 3600) / 60))
    end
    -- Assign + persist push times (EAT) on carrier.marshalEAT.  SINGLE OWNER:
    -- only readCczState assigns/GCs (per flight LEAD); readMarshalOverhead just
    -- LOOKS UP (via carrier.flightLead for wingmen).  Two writers previously
    -- fought: leads-only GC deleted wingman entries every poll and the TOWER
    -- reader re-chained them at maxEat+60 — phantom/shifting push times.
    --   rows     = entries to ASSIGN (flight leads, nm-sorted)
    --   keepSet  = modex set that PROTECTS entries from GC (all jets in the
    --              feed, members + commenced included); nil → GC to rows only.
    local function assignMarshalEAT(rows, keepSet)
        carrier.marshalEAT = carrier.marshalEAT or {}
        local present, maxEat = {}, nil
        for _, r in base.ipairs(rows) do
            if not r.support then
                present[r.modex] = true
                local e = carrier.marshalEAT[r.modex]
                if e and (not maxEat or e > maxEat) then maxEat = e end
            end
        end
        local nowT = carrier.shipTod or 0
        for _, r in base.ipairs(rows) do
            if not r.support then
                if not carrier.marshalEAT[r.modex] then
                    local b = (maxEat and (maxEat + 60)) or (nowT + 90)
                    carrier.marshalEAT[r.modex] = b
                    maxEat = b
                end
                r.eat = carrier.marshalEAT[r.modex]
            end
        end
        for m in base.pairs(carrier.marshalEAT) do
            if not present[m] and not (keepSet and keepSet[m]) then
                carrier.marshalEAT[m] = nil
            end
        end
    end

    local function readMarshalOverhead()
        local content = (carrier.q and carrier.q.ccz) or ''
        if content == '' and not carrier.olympusActive then content = slurp(CCZ_FILE_V13) end
        -- HOLDING picture (>= ~5500 ft, still in the stack) vs jets that have
        -- COMMENCED (pushed below platform, descending/inbound).  The overhead +
        -- STACK table show holding; the middle table becomes COMMENCING.
        local rows, commencing = {}, {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, brg, nm, alt, ias, role, ahdg =
                line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)|(%a+)|(%-?%d+)')
            if not modex then  -- back-compat (older bridge w/o heading field)
                modex, brg, nm, alt, ias, role =
                    line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)|(%a+)')
            end
            if modex and role ~= 'TKR' then
                local rec = { modex = modex, brg = tonumber(brg) or 0,
                    nm = tonumber(nm) or 0, alt = tonumber(alt) or 0,
                    gs = tonumber(ias) or 0, hdg = tonumber(ahdg) }
                if rec.alt >= 5500 then table.insert(rows, rec)
                else table.insert(commencing, rec) end
            end
        end
        table.sort(rows, function(a, b) return a.nm < b.nm end)
        table.sort(commencing, function(a, b) return a.nm < b.nm end)
        -- EAT: LOOKUP ONLY (readCczState is the single assigner/GC owner);
        -- wingmen resolve through their flight lead's entry.
        do
            local M  = carrier.marshalEAT or {}
            local FL = carrier.flightLead or {}
            for _, r in base.ipairs(rows) do
                r.eat = M[r.modex] or (FL[r.modex] and M[FL[r.modex]]) or nil
            end
        end
        -- CASE III: no CHARLIE'D (it's all push times).  STACK columns become
        -- LEG + EAT; the middle table is repurposed as COMMENCING; the bottom
        -- COMMENCING table is hidden (TOWER_C1, CASE I-only).
        setText('tsH4', 'LEG')
        setText('tsH5', 'EAT')
        setText('tdHdr', "COMMENCING  ·  pushed from marshal")
        setText('tdH3', 'GS'); setText('tdH4', 'STATE'); setText('tdH5', 'RANGE')
        -- FB = BRC-9 (approach course); the marshal RADIAL is its reciprocal.
        local fb = carrier.shipFB
        local radBrg = fb and ((fb + 180) % 360) or nil
        -- Which leg of the left-hand holding racetrack a jet is on, from its
        -- heading vs the Final Bearing: UPWIND = toward the boat (hdg~FB),
        -- DOWNWIND = away (hdg~FB+180); the two 180 turns pass through FB+-90
        -- (left/CCW: upwind->downwind via FB-90, downwind->upwind via FB+90).
        local function holdLeg(h)
            if not h or not fb then return 'MARSHAL' end
            local cand = { { math.abs(angDelta(h, fb)), 'UPWIND' },
                           { math.abs(angDelta(h, (fb + 180) % 360)), 'DOWNWIND' },
                           { math.abs(angDelta(h, (fb + 90)  % 360)), 'UPWIND TURN' },
                           { math.abs(angDelta(h, (fb + 270) % 360)), 'DOWNWIND TURN' } }
            local best = cand[1]
            for k = 2, 4 do if cand[k][1] < best[1] then best = cand[k] end end
            return best[2]
        end
        setText('lblTwrOhHdr', fb
            and string.format('MARSHAL HOLDING  ·  FB %03d  ·  RADIAL %03d', mag(fb), mag(radBrg))
            or  ('MARSHAL HOLDING  ·  CASE ' .. (carrier.recoveryCase or 'III') .. '  ·  radial'))
        setText('lblTwrSvHdr', 'ANGELS  ·  5 -> 13 k ft')
        for i = 1, 9 do setText('tcSvA' .. i, string.format('%2dk', 14 - i)) end  -- top 13k .. bottom 5k

        -- overhead: boat (143,58), radial down (7.87 px/nm).  Project onto the
        -- astern radial using the FB; lateral spreads jets so they don't overlap.
        local placed = {}
        local function freeY(lx, ly)
            for _ = 1, 6 do
                local hit = false
                for _, p in base.ipairs(placed) do
                    if math.abs(p.x - lx) < 54 and math.abs(p.y - ly) < 12 then hit = true break end
                end
                if not hit then break end
                ly = ly + 12
            end
            return ly
        end
        local nextX, nextY = nil, nil   -- plotted pos of the next-to-commence jet
        for i = 1, 12 do
            local r = rows[i]
            if r then
                local along, cross = r.nm, 0
                if radBrg then
                    local d = math.rad(r.brg - radBrg)
                    along = r.nm * math.cos(d)
                    cross = r.nm * math.sin(d)
                end
                -- zoomed to the marshal band: 15 nm (top) .. 30 nm (bottom).
                if along < 15 then along = 15 elseif along > 30 then along = 30 end
                if cross < -7 then cross = -7 elseif cross > 7 then cross = 7 end
                local x = math.floor(143 + cross * 15.73)
                local y = math.floor(58 + (along - 15) * (294 - 58) / 15)
                setBounds('tcDot' .. i, x - 2, y - 2, 5, 5)
                -- bearing leader in this screen frame: +y = away down the
                -- radial, +x = right of the radial
                if r.hdg and radBrg then
                    local d = math.rad(r.hdg - radBrg)
                    local vx, vy = math.sin(d), math.cos(d)
                    setBounds('tvec' .. i .. 'a', x + math.floor(vx * 7 + 0.5) - 1,
                                                  y + math.floor(vy * 7 + 0.5) - 1, 3, 3)
                    setBounds('tvec' .. i .. 'b', x + math.floor(vx * 12 + 0.5) - 1,
                                                  y + math.floor(vy * 12 + 0.5) - 1, 3, 3)
                else
                    setBounds('tvec' .. i .. 'a', -300, -300, 3, 3)
                    setBounds('tvec' .. i .. 'b', -300, -300, 3, 3)
                end
                if i == 1 then nextX, nextY = x, y end   -- lowest = next to commence
                local lx = x + 6
                local ly = freeY(lx, y - 6)
                table.insert(placed, { x = lx, y = ly })
                setText('tcLbl' .. i, string.format('%s %dk', r.modex:sub(1, 6), math.floor(r.alt / 1000 + 0.5)))
                setBounds('tcLbl' .. i, lx, ly, 64, 13)
            else
                setBounds('tcDot' .. i, -300, -300, 5, 5)
                setText('tcLbl' .. i, '')
                setBounds('tcLbl' .. i, -300, -300, 64, 13)
                setBounds('tvec' .. i .. 'a', -300, -300, 3, 3)
                setBounds('tvec' .. i .. 'b', -300, -300, 3, 3)
            end
        end

        -- Commence highlight now TRACKS the next jet to push (the lowest in the
        -- stack), instead of a fixed point — since each higher jet sits +1000 ft
        -- and +1 DME up the radial, the bottom jet is always the one commencing.
        if nextX then
            setBounds('t3Comm', nextX - 6, nextY - 6, 13, 13)
            setText('t3CommL', string.format('%s  NEXT', rows[1].modex:sub(1, 6)))
            setBounds('t3CommL', nextX + 10, nextY - 7, 120, 13)
        else
            setBounds('t3Comm', -300, -300, 13, 13)
            setText('t3CommL', 'COMMENCE 21/6k')
            setBounds('t3CommL', 147, 148, 120, 13)
        end

        -- altitude ladder (right): 13k -> top(56), 5k -> bottom(290).
        for i = 1, 10 do
            local r = rows[i]
            if r then
                local a = r.alt
                if a > 13000 then a = 13000 elseif a < 5000 then a = 5000 end
                local y = math.floor(56 + (13000 - a) * (234 / 8000))
                local x = 316 + ((i - 1) % 5) * 40
                setText('tcSv' .. i, r.modex:sub(1, 6))
                setBounds('tcSv' .. i, x, y - 7, 44, 14)
            else
                setText('tcSv' .. i, '')
                setBounds('tcSv' .. i, -200, -200, 44, 14)
            end
        end

        for i = 1, 8 do
            local r = rows[i]
            if r then
                setText('tsCell'..i..'_1', ' ' .. r.modex:sub(1, 8))
                local AA = carrier.assignedAngels or {}
                local ang = AA[r.modex] or (carrier.flightLead and carrier.flightLead[r.modex]
                                            and AA[carrier.flightLead[r.modex]])
                setAltCell('tsCell'..i..'_2', r.alt, ang)
                setText('tsCell'..i..'_3', string.format('%4d', r.gs or 0))
                setText('tsCell'..i..'_4', holdLeg(r.hdg))
                setText('tsCell'..i..'_5', r.eat and clockFromSecs(r.eat) or '--:--')
            else
                for ccol = 1, 5 do setText('tsCell'..i..'_'..ccol, '') end
            end
            setWidgetVisible('tsBtn' .. i, false)
        end
        -- middle table = COMMENCING (jets pushed from marshal, sorted nearest).
        for i = 1, 5 do
            local r = commencing[i]
            if r then
                setText('tdCell'..i..'_1', ' ' .. r.modex:sub(1, 8))
                setText('tdCell'..i..'_2', string.format('%5d', r.alt))
                setText('tdCell'..i..'_3', string.format('%4d', r.gs or 0))
                setText('tdCell'..i..'_4', 'INBOUND')
                setText('tdCell'..i..'_5', string.format('%4.1f', r.nm))
            else
                for ccol = 1, 5 do setText('tdCell'..i..'_'..ccol, '') end
            end
            setWidgetVisible('tdBtn' .. i, false)
        end
    end

    local PR = 5                       -- holding-circle radius (nm)
    local function readStackState()
        -- CASE II & III both use the instrument marshal-holding overhead.
        if carrier.recoveryCase == 'III' or carrier.recoveryCase == 'II' then
            return readMarshalOverhead()
        end
        -- restore CASE I column captions / table headers (CASE III renamed them)
        setText('tsH4', 'POINT')
        setText('tsH5', 'IN-STK')
        setText('tdH3', 'GS'); setText('tdH4', 'POINT'); setText('tdH5', 'IN-STK')
        setText('tdHdr', "CHARLIE'D  ·  cleared   (U = undo)")
        local content = (carrier.q and carrier.q.stack) or ''
        if content == '' and not carrier.olympusActive then content = slurp(STACK_FILE_V13) end
        local hold, charlie, commence = {}, {}, {}
        for line in content:gmatch('[^\r\n]+') do
            local modex, alt, ias, inT, pt, state, jx, jy =
                line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]+)|([^|]+)|(%-?[%d%.]+)|(%-?[%d%.]+)')
            if not modex then
                modex, alt, ias, inT, pt, state =
                    line:match('([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]+)|([^|]+)')
            end
            -- TOWER shows only the CASE I recovery stack: angels 2–6 (the
            -- marshal stack STOPS at 6 — angels 7 is the tanker's).  Higher
            -- traffic shows on the MARSHALL radar instead.
            if modex and (tonumber(alt) or 0) <= 6400 then
                local r = { modex = modex, alt = tonumber(alt) or 0,
                            ias = tonumber(ias) or 0, inT = tonumber(inT) or 0,
                            pt = pt, state = state,
                            jx = tonumber(jx), jy = tonumber(jy) }
                if state == 'CHARLIE' then        table.insert(charlie,  r)
                elseif state == 'COMMENCING' then table.insert(commence, r)
                else                              table.insert(hold,     r) end
            end
        end

        setText('lblTwrOhHdr', 'MARSHAL STACK  ·  CASE I overhead  ·  5 nm')
        -- CASE I altitude ladder: angels 2..6 in 500 ft rungs (stack stops at
        -- 6; CASE III rewrites these to 5..13k)
        setText('lblTwrSvHdr', 'ANGELS  ·  2 -> 6 k ft')
        local A26 = { '6k', '5.5', '5k', '4.5', '4k', '3.5', '3k', '2.5', '2k' }
        for i = 1, 9 do setText('tcSvA' .. i, A26[i]) end

        -- Panel-side Charlie clicks (carrier.panelCh): instant visual feedback.
        -- The mission query is authoritative for real jets (it also auto-commences
        -- at point 3) but lags a poll; this promotes HOLD->CHARLIE / demotes
        -- CHARLIE->HOLD immediately so a click responds without waiting.
        local pc = carrier.panelCh or {}
        for i = #hold, 1, -1 do
            if pc[hold[i].modex] == true then
                local r = table.remove(hold, i); r.state = 'CHARLIE'
                table.insert(charlie, r)
            end
        end
        for i = #charlie, 1, -1 do
            if pc[charlie[i].modex] == false then
                local r = table.remove(charlie, i); r.state = 'HOLD'
                table.insert(hold, r)
            end
        end

        -- Lowest angels first (next to recover at the top of each table).
        local byAltAsc = function(a, b) return a.alt < b.alt end
        table.sort(hold,     byAltAsc)
        table.sort(charlie,  byAltAsc)
        table.sort(commence, byAltAsc)

        -- POINT column: descriptive pattern point if the jet is in the visual
        -- pattern, otherwise the nearest cardinal holding point (1..4).
        local function ptCol(r)
            local p = r.pt or ''
            if p == 'INITIAL' or p == 'BREAK' or p == 'DOWNWIND'
               or p == 'ABEAM' or p == '180' or p == 'GROOVE' then
                return p
            end
            if r.jx then
                local phase = math.deg(math.atan2(r.jy or 0, (r.jx or 0) + PR)) % 360
                local nearest = math.floor((phase + 45) / 90) % 4   -- 0→pt1 .. 3→pt4
                return 'PT ' .. (nearest + 1)
            end
            return '--'
        end

        -- Fill a bordered table (MODEX | ALT | IAS | POINT | IN-STK), record
        -- each row's modex for click handling, and show/hide the per-row action
        -- button (hasBtn tables only) so empty rows don't show a stray button.
        -- Only touch button visibility while the TOWER tab is showing, else we
        -- override showTab's tab gating and leak buttons onto other tabs.
        local onTower = (carrier.tab == 'tower')
        local function fillTable(rows, prefix, maxRows, rowModex, hasBtn, flagAlt)
            for i = 1, maxRows do
                local r = rows[i]
                if rowModex then rowModex[i] = r and r.modex or nil end
                if r then
                    setText(prefix..'Cell'..i..'_1', ' ' .. r.modex:sub(1, 8))
                    -- rounded to 50 ft; HOLDING rows flag >100 ft off the
                    -- assigned marshal altitude in red
                    local ang = nil
                    if flagAlt then
                        local AA = carrier.assignedAngels or {}
                        ang = AA[r.modex]
                            or (carrier.flightLead and carrier.flightLead[r.modex]
                                and AA[carrier.flightLead[r.modex]])
                    end
                    setAltCell(prefix..'Cell'..i..'_2', r.alt, ang)
                    setText(prefix..'Cell'..i..'_3', string.format('%3d kt', r.ias))
                    setText(prefix..'Cell'..i..'_4', ptCol(r))
                    setText(prefix..'Cell'..i..'_5', fmtTime(r.inT))
                else
                    for ccol = 1, 5 do setText(prefix..'Cell'..i..'_'..ccol, '') end
                end
                if hasBtn and onTower then
                    setWidgetVisible(prefix..'Btn'..i, r ~= nil)
                end
            end
        end
        carrier.stackRowModex   = carrier.stackRowModex   or {}
        carrier.charlieRowModex = carrier.charlieRowModex or {}
        fillTable(hold,     'ts', 8, carrier.stackRowModex,   true, true)
        fillTable(charlie,  'td', 5, carrier.charlieRowModex, true)
        -- (COMMENCING table retired — the LEVEL-OFF radar below shows the
        --  commence→break descent + spin band instead)

        local allAir = {}
        for _, r in base.ipairs(hold)     do table.insert(allAir, r) end
        for _, r in base.ipairs(charlie)  do table.insert(allAir, r) end
        for _, r in base.ipairs(commence) do table.insert(allAir, r) end

        -- Side-view angels ladder: 6k → y=56, 2k → y=290 (4000 ft / 234 px).
        for i = 1, 10 do
            local r = allAir[i]
            if r then
                local a = r.alt
                if a > 6000 then a = 6000 elseif a < 2000 then a = 2000 end
                local y = math.floor(56 + (6000 - a) * (234 / 4000))
                local x = 316 + ((i - 1) % 5) * 40
                setText('tcSv' .. i, r.modex:sub(1, 6))
                setBounds('tcSv' .. i, x, y - 7, 44, 14)
            else
                setText('tcSv' .. i, '')
                setBounds('tcSv' .. i, -200, -200, 44, 14)
            end
        end

        -- Overhead circle: plot each jet by deck-frame jx/jy.  Centre (143,173),
        -- 116 px = 5 nm; boat on the right edge.  px = CX + scale*(jx+PR),
        -- py = CY - scale*jy.  Datablocks decluttered downward.
        local CX, CY, SCALE = 143, 173, 116 / PR
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
        carrier.twrPrev = carrier.twrPrev or {}
        local twrSeen = {}
        for i = 1, 12 do
            local r = allAir[i]
            if r and r.jx then
                local px = math.floor(CX + SCALE * (r.jx + PR))
                local py = math.floor(CY - SCALE * (r.jy or 0))
                if px < 18  then px = 18  elseif px > 268 then px = 268 end
                if py < 48  then py = 48  elseif py > 298 then py = 298 end
                setBounds('tcDot' .. i, px - 2, py - 2, 5, 5)
                -- bearing leader from movement delta (stack feed has no heading)
                twrSeen[r.modex] = true
                local pv = carrier.twrPrev[r.modex]
                local vdx, vdy = pv and (px - pv.x) or 0, pv and (py - pv.y) or 0
                local vlen = math.sqrt(vdx * vdx + vdy * vdy)
                if vlen > 1.2 then
                    local ux, uy = vdx / vlen, vdy / vlen
                    setBounds('tvec' .. i .. 'a', px + math.floor(ux * 7 + 0.5) - 1,
                                                  py + math.floor(uy * 7 + 0.5) - 1, 3, 3)
                    setBounds('tvec' .. i .. 'b', px + math.floor(ux * 12 + 0.5) - 1,
                                                  py + math.floor(uy * 12 + 0.5) - 1, 3, 3)
                else
                    setBounds('tvec' .. i .. 'a', -300, -300, 3, 3)
                    setBounds('tvec' .. i .. 'b', -300, -300, 3, 3)
                end
                carrier.twrPrev[r.modex] = { x = px, y = py }
                local lx = px + 6
                local ly = tfreeY(lx, py - 6)
                table.insert(tplaced, { x = lx, y = ly })
                local altk = math.floor((r.alt or 0) / 1000 + 0.5)
                setText('tcLbl' .. i, string.format('%s %dk', r.modex:sub(1, 6), altk))
                setBounds('tcLbl' .. i, lx, ly, 64, 13)
            else
                setBounds('tcDot' .. i, -300, -300, 5, 5)
                setText('tcLbl' .. i, '')
                setBounds('tcLbl' .. i, -300, -300, 64, 13)
                setBounds('tvec' .. i .. 'a', -300, -300, 3, 3)
                setBounds('tvec' .. i .. 'b', -300, -300, 3, 3)
            end
        end
        for m in base.pairs(carrier.twrPrev) do
            if not twrSeen[m] then carrier.twrPrev[m] = nil end
        end

        -- ── LEVEL-OFF radar (700-1600 ft, ≤4 nm): the commence→break descent
        -- gap + the 1200 ft SPIN pattern, as a range/altitude side profile. ──
        local lvl = {}
        for _, r in base.ipairs(allAir) do
            local rng = r.jx and math.sqrt(r.jx * r.jx + (r.jy or 0) * (r.jy or 0)) or 99
            if r.alt >= 700 and r.alt <= 1600 and rng <= 4 then
                lvl[#lvl + 1] = { modex = r.modex, alt = r.alt, rng = rng }
            end
        end
        table.sort(lvl, function(a, b) return a.rng < b.rng end)
        for i = 1, 8 do
            local r = lvl[i]
            if r then
                local x = math.floor(14 + r.rng / 4 * 500)
                local y = math.floor(686 + (1600 - r.alt) * 98 / 1100)
                if y < 688 then y = 688 elseif y > 782 then y = 782 end
                if x < 18 then x = 18 elseif x > 508 then x = 508 end
                setBounds('lvlDot' .. i, x - 2, y - 2, 5, 5)
                setText('lvlLbl' .. i, string.format('%s %d',
                    r.modex:sub(1, 6), math.floor(r.alt / 50 + 0.5) * 50))
                -- keep the label inside the strip: flip it to the left of the
                -- dot near the right edge (would otherwise clip past x=540)
                local lx = (x > 450) and (x - 70) or (x + 6)
                setBounds('lvlLbl' .. i, lx, y - 6, 64, 13)
            else
                setBounds('lvlDot' .. i, -300, -300, 5, 5)
                setText('lvlLbl' .. i, '')
                setBounds('lvlLbl' .. i, -300, -300, 64, 13)
            end
        end
    end

    -- ─── MARSHALL: scope scatter + scripted readout + stack racetrack ─────
    -- Scope centre (270,212), 60 nm = 150 px (2.5 px/nm), N up.  Marshal
    -- angels assigned by range order: closest inbound = angels 2, stacking up.
    local function readCczState()
        local content = (carrier.q and carrier.q.ccz) or ''
        if content == '' and not carrier.olympusActive then content = slurp(CCZ_FILE_V13) end
        local rows = {}
        for line in content:gmatch('[^\r\n]+') do
            -- prefer the 7-field form (with aircraft heading — drives the
            -- bearing leader on the scope); fall back to 6 / 5 fields
            local modex, brg, nm, alt, ias, role, ahdg =
                line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)|(%a+)|(%-?%d+)')
            if not modex then
                modex, brg, nm, alt, ias, role =
                    line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)|(%a+)')
            end
            if not modex then
                -- back-compat parse (older bridge w/o role field)
                modex, brg, nm, alt, ias =
                    line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)')
            end
            if modex then
                table.insert(rows, {
                    modex = modex, brg = tonumber(brg) or 0,
                    nm = tonumber(nm) or 0, alt = tonumber(alt) or 0,
                    ias = tonumber(ias) or 0, hdg = tonumber(ahdg),
                    support = (role == 'TKR'),
                })
            end
        end
        table.sort(rows, function(a, b) return a.nm < b.nm end)
        -- Assign marshal slots ONLY to recovering aircraft (tankers/AWACS get
        -- none).  The base differs by recovery case:
        --   CASE I   — VISUAL overhead, lowest flight angels 2, +1000 ft each.
        --   CASE III — INSTRUMENT marshal radial, lowest flight angels 6 at
        --              21 DME, each higher flight +1000 ft and +1 DME, with EATs.
        local caseIII      = (carrier.recoveryCase == 'III')
        -- CASE II & III both marshal on instruments (radial, angels 6 at 21 DME,
        -- +1000 ft / +1 DME per flight, EAT push times).  Only the terminal
        -- approach differs, so all the marshal GEOMETRY keys off instrMarshal.
        local instrMarshal = caseIII or (carrier.recoveryCase == 'II')
        local baseAng = instrMarshal and 6 or 2

        -- FLIGHT CLUSTERING — jets "holding hands" (formation: within 1.5 nm
        -- and 600 ft of each other) are ONE flight and hold ONE marshal slot,
        -- instead of each wingman eating the next 1000-ft rung.  The nearest
        -- jet of each cluster is the lead; members inherit its angels/DME/EAT.
        local flights = {}
        for _, r in ipairs(rows) do
            if not r.support then
                r.px = r.nm * math.sin(math.rad(r.brg))
                r.py = r.nm * math.cos(math.rad(r.brg))
                local joined = nil
                for _, f in base.ipairs(flights) do
                    local lead = f[1]
                    local dx, dy = r.px - lead.px, r.py - lead.py
                    if (dx * dx + dy * dy) < 2.25 and math.abs(r.alt - lead.alt) < 600 then
                        joined = f
                        break
                    end
                end
                if joined then
                    joined[#joined + 1] = r
                    r.isLead = false
                else
                    flights[#flights + 1] = { r }
                    r.isLead = true
                end
            end
        end
        local angIdx = 0
        for _, f in base.ipairs(flights) do
            angIdx = angIdx + 1
            for _, m in base.ipairs(f) do
                m.angels = baseAng + (angIdx - 1)
                m.dme    = 21 + (angIdx - 1)
            end
        end

        -- Publish member→lead map (wingman EAT lookups on the TOWER tab) and
        -- the ASSIGNED marshal altitude per jet (off-altitude red flagging).
        carrier.flightLead = {}
        carrier.assignedAngels = {}
        for _, f in base.ipairs(flights) do
            for k = 2, #f do carrier.flightLead[f[k].modex] = f[1].modex end
            for _, m in base.ipairs(f) do carrier.assignedAngels[m.modex] = m.angels end
        end

        -- EAT push times: one per FLIGHT (leads only; members inherit).
        if instrMarshal then
            carrier.marshalEAT = carrier.marshalEAT or {}
            local M = carrier.marshalEAT
            -- lead re-election churn guard: if today's lead has no EAT but
            -- another member of the SAME flight does (they swapped ranges in
            -- the hold), the flight ADOPTS the earliest member entry instead
            -- of being chained to the back of the queue.
            for _, f in base.ipairs(flights) do
                if not M[f[1].modex] then
                    local best = nil
                    for k = 2, #f do
                        local e = M[f[k].modex]
                        if e and (not best or e < best) then best = e end
                    end
                    if best then M[f[1].modex] = best end
                end
                -- the lead's key is authoritative; member keys would go stale
                for k = 2, #f do M[f[k].modex] = nil end
            end
            local leads, keep = {}, {}
            for _, f in base.ipairs(flights) do leads[#leads + 1] = f[1] end
            for _, r in base.ipairs(rows) do keep[r.modex] = true end
            assignMarshalEAT(leads, keep)
            for _, f in base.ipairs(flights) do
                for k = 2, #f do f[k].eat = f[1].eat end
            end
        end

        -- Display rows: one line per FLIGHT ("203 +1" = lead + wingman count).
        local disp = {}
        for _, f in base.ipairs(flights) do
            local lead = f[1]
            local mx = (#f > 1) and (lead.modex:sub(1, 5) .. '+' .. (#f - 1)) or lead.modex
            disp[#disp + 1] = { modex = mx, alt = lead.alt, nm = lead.nm, brg = lead.brg,
                                angels = lead.angels, dme = lead.dme, eat = lead.eat,
                                support = false, count = #f }
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
        -- Dots for EVERY jet (a formation reads as a tight cluster), but a
        -- DATABLOCK only per flight LEAD ("203+1 5k") — with a big CQ stack the
        -- per-jet labels were unreadable soup.
        local labIdx = 0
        for i = 1, 12 do
            local r = rows[i]
            if r then
                local brgR = math.rad(r.brg)
                local nmC = r.nm
                if nmC > 60 then nmC = 60 end
                local dxp = math.floor(cx + nmC * pxPerNm * math.sin(brgR))
                local dyp = math.floor(cy - nmC * pxPerNm * math.cos(brgR))
                setBounds('cczDot' .. i, dxp - 2, dyp - 2, 5, 5)
                -- bearing leader: 2 dots off the blip along the jet's track
                if r.hdg then
                    local hr = math.rad(r.hdg)
                    local vx, vy = math.sin(hr), -math.cos(hr)
                    setBounds('mvec' .. i .. 'a', dxp + math.floor(vx * 7 + 0.5) - 1,
                                                  dyp + math.floor(vy * 7 + 0.5) - 1, 3, 3)
                    setBounds('mvec' .. i .. 'b', dxp + math.floor(vx * 12 + 0.5) - 1,
                                                  dyp + math.floor(vy * 12 + 0.5) - 1, 3, 3)
                else
                    setBounds('mvec' .. i .. 'a', -300, -300, 3, 3)
                    setBounds('mvec' .. i .. 'b', -300, -300, 3, 3)
                end
                if r.isLead or r.support then
                    labIdx = labIdx + 1
                    local lx = dxp + 6
                    local ly = freeY(lx, dyp - 6)
                    table.insert(placed, { x = lx, y = ly })
                    local altk = math.floor((r.alt or 0) / 1000 + 0.5)
                    local n = 0
                    for _, f in base.ipairs(flights) do
                        if f[1] == r then n = #f break end
                    end
                    local tag = (n > 1) and ('+' .. (n - 1)) or ''
                    setText('rowCcz' .. labIdx, string.format('%s%s %dk%s',
                        r.modex:sub(1, 6), tag, altk, r.support and ' T' or ''))
                    setBounds('rowCcz' .. labIdx, lx, ly, 66, 13)
                end
            else
                setBounds('cczDot' .. i, -300, -300, 5, 5)
                setBounds('mvec' .. i .. 'a', -300, -300, 3, 3)
                setBounds('mvec' .. i .. 'b', -300, -300, 3, 3)
            end
        end
        for i = labIdx + 1, 12 do
            setText('rowCcz' .. i, '')
            setBounds('rowCcz' .. i, -300, -300, 66, 13)
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
            setText('lblBrcTip', 'BRC ' .. string.format('%03d', mag(hdg)))
            setBounds('lblBrcTip',
                math.floor(cx + tr * sx - 14), math.floor(cy + tr * sy - 7), 60, 14)
        else
            for i = 1, 7 do setBounds('hdgDot' .. i, -300, -300, 4, 4) end
            setText('lblBrcTip', '')
        end

        -- Table/stack/readback consume the per-FLIGHT display rows.
        local tblRows = disp

        -- ONE scripted marshal call (nearest recovering aircraft) — phrased for
        -- the active recovery case.
        local cs  = carrier.callsign or 'Mother'
        local alt = carrier.altimeter or '29.92'
        local brc = carrier.shipHdg
        -- (clockFromSecs is shared at the reader scope above)
        -- Weather text derived from the LIVE mission weather, so the radio call
        -- and the blurb MATCH what's actually set.  cloudWord = sky condition,
        -- visPhrase = "limited" under 10 nm else "N miles", precipWord appended.
        local function weatherText()
            local d = carrier.wxCloudDens
            local cloud = 'clear'
            if d then
                if     d <= 2 then cloud = 'clear'
                elseif d <= 4 then cloud = 'few clouds'
                elseif d <= 6 then cloud = 'scattered clouds'
                elseif d <= 8 then cloud = 'broken clouds'
                else               cloud = 'overcast' end
            end
            local precip = carrier.wxPrecip or 0
            local pword = (precip >= 2) and 'thunderstorms' or (precip == 1) and 'rain' or nil
            if pword then cloud = cloud .. ' with ' .. pword end
            local visNm = carrier.wxVisM and (carrier.wxVisM / 1852) or nil
            local visStr, limited
            if not visNm or visNm >= 10 then visStr, limited = '10 plus miles', false
            elseif visNm >= 1 then visStr, limited = string.format('%d miles', math.floor(visNm + 0.5)), true
            else visStr, limited = string.format('%.1f miles', visNm), true end
            return cloud, visStr, limited, visNm
        end
        local wxCloud, wxVisStr, wxLimited = weatherText()
        local wxVisCall = wxLimited and 'limited' or wxVisStr

        local lineIdx = 0
        local function put(txt)
            lineIdx = lineIdx + 1
            if lineIdx <= 5 then setText('rowMarCall' .. lineIdx, txt) end
        end
        local r1 = nil
        for _, r in ipairs(tblRows) do
            if not r.support then r1 = r break end
        end
        if instrMarshal then
            -- CASE II & III share the INSTRUMENT marshal readback (radial/DME/
            -- angels); shown at all times since the boat info is constant.  The
            -- approach TYPE differs: III = CV-1 instrument approach to the ship;
            -- II = penetration, then a VISUAL overhead break at the ship.
            local fb     = carrier.shipFB and mag(carrier.shipFB) or nil   -- magnetic
            local fbStr  = fb and string.format('%03d', fb) or '---'
            local recip  = fb and ((fb + 180) % 360) or nil
            local recipS = recip and string.format('%03d', recip) or '---'
            local mx     = r1 and r1.modex or '----'
            local ang    = r1 and r1.angels or baseAng
            local dme    = r1 and r1.dme or 21
            local approach = caseIII
                and "   Case III recovery in effect, expect CV-1 approach."
                or  "   Case II recovery in effect, expect visual approach at the ship."
            put(string.format("%s, %s Marshall, Mother's weather is %s, visibility %s,", mx, cs, wxCloud, wxVisCall))
            put(approach)
            put(string.format("   Altimeter reads %s, FB %s,", alt, fbStr))
            put(string.format("   marshal on Mother's %s radial, angels %d, %d DME,", recipS, ang, dme))
            put("   report when established.")
        else
            -- CASE I readback — squadron SOP phrasing; shown AT ALL TIMES (boat
            -- info is constant), lead modex fills in as a jet checks in.
            local ang    = r1 and r1.angels or baseAng
            local mx     = r1 and r1.modex or '----'
            local brcStr = brc and string.format('%03d', mag(brc)) or '---'
            put(string.format("%s, %s Marshall, Case I recovery in effect, CV-1 approach,", mx, cs))
            put(string.format("   Mother's weather %s, visibility %s,", wxCloud, wxVisStr))
            put(string.format("   altimeter %s, expected BRC %s.", alt, brcStr))
            put(string.format("   Marshal overhead angels %d, report see me at ten.", ang))
        end
        for i = lineIdx + 1, 5 do setText('rowMarCall' .. i, '') end

        -- Weather blurb (bottom of MARSHALL) — WEATHER ONLY.  Wind/altimeter/
        -- BRC live in the MOTHER block (and the radio call) — they were shown
        -- in three places.
        do
            local parts = { 'WX ' .. wxCloud }
            parts[#parts + 1] = 'vis ' .. wxVisStr
            if carrier.wxCloudBase and carrier.wxCloudDens and carrier.wxCloudDens > 2 then
                parts[#parts + 1] = string.format('base %d ft', carrier.wxCloudBase)
            end
            setText('lblMarWx', table.concat(parts, '  ·  '))
        end

        -- MOTHER boat-info block (replaces the old 2nd call).  CASE III shows the
        -- Final Bearing (BRC-9, the approach course) + its reciprocal (the marshal
        -- radial pilots hold on) instead of the BRC.
        do
            local brcM = brc and mag(brc) or nil              -- magnetic BRC/FB/RECIP
            local fbM  = carrier.shipFB and mag(carrier.shipFB) or nil
            local brcS = brcM and string.format('%03d', brcM) or '---'
            local fb   = fbM
            local fbS  = fb and string.format('%03d', fb) or '---'
            if instrMarshal then
                local recip  = fb and ((fb + 180) % 360) or nil
                local recipS = recip and string.format('%03d', recip) or '---'
                setText('lblBoat1', string.format(
                    'FINAL BEARING %s (BRC-9)   RECIP %s   ALT %s', fbS, recipS, alt))
            else
                setText('lblBoat1', string.format('BRC %s   FB %s   ALT %s', brcS, fbS, alt))
            end
            if carrier.shipWindFrom and carrier.shipWindKts then
                setText('lblBoat2', string.format(
                    'WIND %03d/%d kt   ACROSS DECK %dH %dX',
                    carrier.shipWindFrom, carrier.shipWindKts,
                    carrier.shipHeadKts or 0, carrier.shipCrossKts or 0))
            elseif carrier.olympusActive and carrier.shipSpd then
                setText('lblBoat2', string.format(
                    'SHIP %d kt   (wind n/a on Olympus feed)', carrier.shipSpd))
            else
                setText('lblBoat2', 'WIND ---/-- kt   ACROSS DECK --')
            end
        end

        -- Marshal assignment table — per cell: MODEX/ALT/RNG/BRG/ANG/EAT.
        -- EAT (Expected Approach Time) is a CASE III concept — 1 min spacing
        -- from the carrier's time-of-day; CASE I overhead has none ("--").
        local tod = carrier.shipTod
        for i = 1, 13 do
            local r = tblRows[i]
            if r then
                setText('mCell'..i..'_1', ' ' .. r.modex:sub(1, 7))
                setAltCell('mCell'..i..'_2', r.alt or 0, (not r.support) and r.angels or nil)
                setText('mCell'..i..'_3', string.format('%4.1f', r.nm or 0))
                setText('mCell'..i..'_4', string.format('%3d', mag(r.brg or 0)))
                if r.support then
                    -- tanker/AWACS: altitude only, no marshal slot
                    setText('mCell'..i..'_5', 'TKR')
                    setText('mCell'..i..'_6', ' --')
                else
                    setText('mCell'..i..'_5', string.format('%2d', r.angels or 0))
                    if instrMarshal then
                        setText('mCell'..i..'_6', r.eat and clockFromSecs(r.eat) or '--:--')
                    else
                        setText('mCell'..i..'_6', '  --')
                    end
                end
            else
                for ccol = 1, 6 do setText('mCell'..i..'_'..ccol, '') end
            end
        end

        -- Marshal stack: bordered angels grid (6 rungs).  The rung labels +
        -- modex placement shift with the case — CASE I shows angels 2..7,
        -- CASE III shows the marshal-radial angels 6..11.
        local rungBase = instrMarshal and 6 or 2
        for k = 2, 7 do
            setText('lblStkA' .. k, tostring(rungBase + (k - 2)))   -- A2=bottom .. A7=top
        end
        setText('lblMarStackHdr', instrMarshal and 'STACK  ·  marshal radial' or 'STACK  ·  angels')
        for i = 1, 12 do
            local r = tblRows[i]
            if r and r.angels then
                local rel = r.angels - rungBase
                if rel < 0 then rel = 0 elseif rel > 5 then rel = 5 end
                local y = 578 + (5 - rel) * 38 + 6
                setText('stkSlot' .. i, r.modex:sub(1, 8))
                setBounds('stkSlot' .. i, 134, y, 92, 13)
            else
                setText('stkSlot' .. i, '')
                setBounds('stkSlot' .. i, -300, -300, 92, 13)
            end
        end

        setText('lblMTblHdr', instrMarshal
            and ('MARSHAL  ·  CASE ' .. (carrier.recoveryCase or 'III') .. ' radial (DME/EAT)')
            or  'MARSHAL  ·  CASE I overhead')
        setText('lblMarRadioHdr', 'RADIO READOUT  ·  CASE ' .. (carrier.recoveryCase or 'I'))
        if #rows > 0 then
            setText('lblMarStatus', string.format('CASE %s  ·  %d aircraft / %d flights in CCZ',
                carrier.recoveryCase or 'I', #rows, #flights))
        else
            setText('lblMarStatus', 'CASE ' .. (carrier.recoveryCase or 'I') .. '  ·  (no aircraft in CCZ)')
        end
    end

    -- ─── LSO CASE I pattern visual ───────────────────────────────────────
    -- v1.3-beta29: aircraft slots (acftPat1..8) get repositioned to the
    -- landmark coords for whichever pattern point the bridge classified
    -- them at.  Multiple aircraft at the same point stack vertically.
    -- v1.3-beta29: HORIZONTAL racetrack — bottom leg y=220 (upwind, ship at
    -- the right end), right leg x=468 (break climb), top leg y=90 (downwind,
    -- right→left), rounded 180 on the left.
    -- ─── Groove timer ────────────────────────────────────────────────────
    -- Nominal CASE I groove is ~15-18 s (see the pattern diagram's "17s").
    local function grooveGrade(s)
        if s < 13 then return 'fast'
        elseif s <= 18 then return 'on time'
        else return 'slow' end
    end
    local function updateGrooveTimer()
        if not carrier.window then return end
        local now = DCS.getRealTime() or 0
        local liveM, liveT
        if carrier.grooveStart then
            for m, t in base.pairs(carrier.grooveStart) do
                local e = now - t
                if (not liveT) or e > liveT then liveM, liveT = m, e end
            end
        end
        if liveM then
            setText('lblGrooveTimer', string.format('%d s', math.floor(liveT)))
            setText('lblGrooveLast',  'IN GROOVE:  ' .. liveM:sub(1, 8))
        elseif carrier.lastGroove then
            local g = carrier.lastGroove
            setText('lblGrooveTimer', string.format('%d s', math.floor(g.secs + 0.5)))
            setText('lblGrooveLast',
                string.format('LAST PASS:  %s   (%s)', g.modex:sub(1, 8), grooveGrade(g.secs)))
        else
            setText('lblGrooveTimer', '-- s')
            setText('lblGrooveLast',  '(waiting for a pass)')
        end
    end

    -- Pixel position each classified point SNAPS to on the rounded racetrack
    -- (must match Tools/gen_lso_pattern.py POINTS).
    -- Nominal station positions (doc only since the live plot — beta54 values
    -- from gen_lso_pattern.py, real-tacview-derived geometry).
    local PATTERN_XY = {
        INITIAL  = { 210, 216 },
        BREAK    = { 413, 116 },
        DOWNWIND = { 320,  91 },
        ABEAM    = { 262,  91 },
        ['180']  = { 127, 172 },
        GROOVE   = { 218, 186 },
        TRAP     = { 290, 193 },
    }
    -- Per-frame smoother for the CASE I/II live plot: eases each aircraft dot
    -- toward its latest target (set ~1 Hz by readPatternState in carrier.acftLerp)
    -- so a pass flies the pattern fluidly instead of snapping between stations.
    local function updateAcftLerp()
        local L = carrier.acftLerp
        if not L then return end
        for s = 1, 8 do
            local e = L[s]
            if e and e.active then
                e.x = e.x + (e.tx - e.x) * 0.18
                e.y = e.y + (e.ty - e.y) * 0.18
                local x, y = math.floor(e.x + 0.5), math.floor(e.y + 0.5)
                setBounds('acftDot' .. s, x - 2, y - 2, 5, 5)
                -- bearing leader along the jet's track
                if e.vx then
                    setBounds('lvec' .. s .. 'a', x + math.floor(e.vx * 7 + 0.5) - 1,
                                                  y + math.floor(e.vy * 7 + 0.5) - 1, 3, 3)
                    setBounds('lvec' .. s .. 'b', x + math.floor(e.vx * 12 + 0.5) - 1,
                                                  y + math.floor(e.vy * 12 + 0.5) - 1, 3, 3)
                end
                -- label only changes at 1 Hz — setText only when it actually does
                local lb = string.format('%s %dk', e.modex:sub(1, 7), e.altk or 0)
                if lb ~= e.lb then setText('acftPat' .. s, lb); e.lb = lb end
                setBounds('acftPat' .. s, x + 7, y - 6, 64, 13)
                e.parked = false
            elseif e and not e.parked then
                -- park ONCE (don't churn setBounds/setText every idle frame); the
                -- entry stays so a continuing jet keeps easing, while a NEW jet on
                -- this slot is force-snapped by readPatternState (fresh handling).
                setBounds('acftDot' .. s, -300, -300, 5, 5)
                setText('acftPat' .. s, '')
                setBounds('acftPat' .. s, -300, -300, 64, 13)
                setBounds('lvec' .. s .. 'a', -300, -300, 3, 3)
                setBounds('lvec' .. s .. 'b', -300, -300, 3, 3)
                e.parked = true
                e.lb = nil
                e.vx, e.vy = nil, nil
            end
        end
    end

    -- ═══ AUTO-PADDLES — native LSO pass grading (beta59) ═════════════════
    -- Emulates Tactical Paddles-style grading from our own pattern feed:
    -- ANGULAR deviations off the 3.5° glideslope + the angled-deck centreline
    -- (like the ball — no per-ship calibration), scored per zone X/IM/IC/AR,
    -- LSO shorthand, wire estimate, grade.  Logic mirror-validated in Python.
    local LSO_TDP_A, LSO_TDP_S = -85, -10        -- touchdown pt, deck metres
    local LSO_S9, LSO_C9 = math.sin(math.rad(9)), math.cos(math.rad(9))
    local LSO_DECK_FT = 65
    local LSO_ZONES = { {'X',1500,900}, {'IM',900,500}, {'IC',500,200}, {'AR',200,40} }

    local function lsoGradeCore(zacc, endState)
        local sh, worst, cut = {}, 0, false
        for _, zz in base.ipairs(LSO_ZONES) do
            local acc = zacc[zz[1]]
            if acc and acc.n > 0 then
                local gs, lu = acc.gs / acc.n, acc.lu / acc.n
                local tok = ''
                for _, c in base.ipairs({ { gs, 0.35, 0.8, 'H', 'LO' },
                                          { lu, 1.5, 3.5, 'LUR', 'LUL' } }) do
                    local v = c[1]
                    if math.abs(v) >= c[2] then
                        local sym = (v > 0) and c[4] or c[5]
                        if math.abs(v) >= c[3] then
                            worst = 2
                            tok = tok .. sym .. '!'
                            if (zz[1] == 'IC' or zz[1] == 'AR') and sym == 'LO' then cut = true end
                        else
                            if worst < 1 then worst = 1 end
                            tok = tok .. '(' .. sym .. ')'
                        end
                    end
                end
                if tok ~= '' then sh[#sh + 1] = tok .. zz[1] end
            end
        end
        local shs = table.concat(sh, ' ')
        if endState == 'WO' then return 'OWO', shs end
        if endState == 'B'  then return 'B', shs end
        if cut then return 'C', shs end
        if worst == 2 then return 'NG', shs end
        if worst == 1 then return 'FAIR', shs end
        return 'OK', shs
    end

    do  -- self-test (same cases the Python mirror validated)
        local function mk(gs, lu)
            local t = {}
            for _, zz in base.ipairs(LSO_ZONES) do t[zz[1]] = { gs = gs * 4, lu = lu * 4, n = 4 } end
            return t
        end
        local g1 = lsoGradeCore(mk(0, 0), 'TRAP')
        local g2 = lsoGradeCore(mk(0.5, 0), 'TRAP')
        local z3 = mk(0, 0); z3.AR = { gs = -1.0 * 4, lu = 0, n = 4 }
        local g3 = lsoGradeCore(z3, 'TRAP')
        if g1 == 'OK' and g2 == 'FAIR' and g3 == 'C' then
            logInfo('auto-paddles self-test PASS')
        else
            logErr('auto-paddles SELF-TEST FAILED: ' .. tostring(g1) .. '/' .. tostring(g2) .. '/' .. tostring(g3))
        end
    end

    local function finishLsoPass(modex, p, endState, wire)
        local grade, shs = lsoGradeCore(p.z or {}, endState)
        local secs = math.floor(((p.t1 or p.t0 or 0) - (p.t0 or 0)) + 0.5)
        carrier.lsoGrades = carrier.lsoGrades or {}
        table.insert(carrier.lsoGrades, 1, {
            modex = modex, grade = grade, sh = shs, wire = wire, secs = secs })
        while #carrier.lsoGrades > 5 do table.remove(carrier.lsoGrades) end
        carrier.lsoPass[modex] = nil
        logInfo(string.format('auto-paddles: %s %s %s %s %ds', modex, grade,
            shs ~= '' and shs or 'clean', wire and (wire .. '-wire') or '-', secs))
    end

    -- fed once per poll from readPatternState (works CASE I/II visual + III)
    local function feedLsoGrader(list)
        carrier.lsoPass = carrier.lsoPass or {}
        local P = carrier.lsoPass
        local nowT = DCS.getRealTime() or 0
        local deckStr = (carrier.q and carrier.q.deck) or ''
        local seen = {}
        for _, r in base.ipairs(list) do
            seen[r.modex] = true
            local ra, rs = (r.ahead or 0) - LSO_TDP_A, (r.stbd or 0) - LSO_TDP_S
            local dtg = -ra * LSO_C9 + rs * LSO_S9
            local lu  =  ra * LSO_S9 + rs * LSO_C9
            local altft = r.alt or 0
            local inG = dtg > 40 and dtg < 1500 and math.abs(lu) < 250 and altft < 800
            local p = P[r.modex]
            if inG then
                if not p then
                    p = { z = {}, t0 = nowT, minDtg = dtg }
                    P[r.modex] = p
                end
                p.t1 = nowT
                if dtg < (p.minDtg or 9e9) then p.minDtg = dtg end
                for _, zz in base.ipairs(LSO_ZONES) do
                    if dtg >= zz[3] and dtg < zz[2] then
                        local gsDeg = math.deg(math.atan2((altft - LSO_DECK_FT) / 3.28084, dtg)) - 3.5
                        local luDeg = math.deg(math.atan2(lu, dtg))
                        local a = p.z[zz[1]] or { gs = 0, lu = 0, n = 0 }
                        a.gs, a.lu, a.n = a.gs + gsDeg, a.lu + luDeg, a.n + 1
                        p.z[zz[1]] = a
                        break
                    end
                end
                if altft < LSO_DECK_FT + 15 and dtg < 200 then p.sawDeck = true end
                p.prev2 = p.prev1
                p.prev1 = { dtg = dtg, altft = altft }
            elseif p then
                -- still airborne in the pattern but left the groove: bolter
                -- only if it actually got down to the deck, else own waveoff
                local st = p.sawDeck and 'B' or 'WO'
                finishLsoPass(r.modex, p, st, nil)
            end
        end
        -- jets that vanished from the pattern feed mid-pass
        for modex, p in base.pairs(P) do
            if not seen[modex] then
                if deckStr:find(modex, 1, true) or (p.minDtg or 999) < 80 then
                    -- ON DECK: trapped.  Wire from the deck-plane crossing,
                    -- interpolated between the last two airborne samples.
                    local wire = 3
                    local s1, s2 = p.prev1, p.prev2
                    if s1 and s2 and s2.altft > s1.altft then
                        local f = (s2.altft - LSO_DECK_FT) / math.max(1, s2.altft - s1.altft)
                        local td = s2.dtg + (s1.dtg - s2.dtg) * f
                        wire = 3 - math.floor(td / 12 + 0.5)
                        if wire < 1 then wire = 1 elseif wire > 4 then wire = 4 end
                    end
                    finishLsoPass(modex, p, 'TRAP', wire)
                elseif nowT - (p.t1 or 0) > 5 then
                    local st = p.sawDeck and 'B' or 'WO'
                    finishLsoPass(modex, p, st, nil)
                end
            end
        end
    end

    local function renderLsoGrades()
        setText('lblEventsHdr', 'LSO GRADES  ·  auto-paddles')
        local G = carrier.lsoGrades or {}
        for i = 1, 3 do
            local g = G[i]
            if g then
                local w = g.wire and (g.wire .. '-wire') or (g.grade == 'B' and 'bolter' or '')
                setText('lblEvent' .. i, string.format('%-7s  %-4s  %s   %s   %ds',
                    g.modex:sub(1, 7), g.grade, g.sh ~= '' and g.sh or 'clean', w, g.secs or 0))
            elseif i == 1 then
                setText('lblEvent1', '(no graded passes yet)')
            else
                setText('lblEvent' .. i, '')
            end
        end
    end

    local function readPatternState()
        local content = (carrier.q and carrier.q.pattern) or ''
        if content == '' and not carrier.olympusActive then content = slurp(PATTERN_FILE_V13) end
        local list = {}
        for line in content:gmatch('[^\r\n]+') do
            -- modex|alt|ias|point|acAhead|acStbd
            local modex, alt, ias, point, ahead, stbd =
                line:match('([^|]+)|(%-?%d+)|(%-?%d+)|([^|]+)|(%-?%d+)|(%-?%d+)')
            if modex then
                table.insert(list, { modex = modex, alt = tonumber(alt) or 0,
                    ias = tonumber(ias) or 0, point = point,
                    ahead = tonumber(ahead) or 0, stbd = tonumber(stbd) or 0 })
            end
        end
        -- Busy CQ: more jets inside 12 nm than display slots (8) — sort
        -- nearest-the-boat first so the 8 that matter to the LSO get the dots.
        table.sort(list, function(a, b)
            return (a.ahead * a.ahead + a.stbd * a.stbd) < (b.ahead * b.ahead + b.stbd * b.stbd)
        end)
        -- AUTO-PADDLES: feed every pattern jet through the pass grader
        base.pcall(feedLsoGrader, list)
        if carrier.recoveryCase == 'III' then
            -- CASE III: final-approach OVERHEAD — boat at the right (trap),
            -- centreline running astern (left).  Plot each jet by distance-to-go
            -- along the centreline (x) + lineup (acStbd) as lateral offset (y);
            -- altitude rides in the datablock.  Matches gen_case3.py l3*.
            local fb = carrier.shipFB and mag(carrier.shipFB) or nil   -- magnetic
            setText('l3Hdr', fb and string.format('CASE III APPROACH  ·  FINAL BEARING %03d (BRC-9)', fb)
                                or  'CASE III APPROACH  ·  final bearing')
            -- glideslope view draws its own approach line — no bearing leaders
            for i = 1, 8 do
                setBounds('lvec' .. i .. 'a', -300, -300, 3, 3)
                setBounds('lvec' .. i .. 'b', -300, -300, 3, 3)
            end
            local function lnm(nm) local n=nm; if n>10 then n=10 elseif n<-0.3 then n=-0.3 end; return math.floor(498 - n*45.4) end
            local placed3 = {}
            local function pfree(lx, ly)
                for _ = 1, 6 do
                    local hit = false
                    for _, p in base.ipairs(placed3) do
                        if math.abs(p.x-lx) < 60 and math.abs(p.y-ly) < 12 then hit = true break end
                    end
                    if not hit then break end
                    ly = ly + 12
                end
                return ly
            end
            for i = 1, 8 do
                local r = list[i]
                local dtg = r and (-(r.ahead or 0) / 1852.0) or nil
                if r and dtg and dtg >= -0.3 and dtg <= 11 then
                    local lat = (r.stbd or 0) / 1852.0
                    if lat < -1.2 then lat = -1.2 elseif lat > 1.2 then lat = 1.2 end
                    local x = lnm(dtg)
                    local y = math.floor(150 + lat * 38)
                    setBounds('acftDot' .. i, x - 2, y - 2, 5, 5)
                    local lx = x + 6
                    local ly = pfree(lx, y - 6)
                    table.insert(placed3, { x = lx, y = ly })
                    setText('acftPat' .. i, string.format('%s %dk', r.modex:sub(1, 6), math.floor((r.alt or 0)/1000 + 0.5)))
                    setBounds('acftPat' .. i, lx, ly, 64, 13)
                else
                    setBounds('acftDot' .. i, -300, -300, 5, 5)
                    setText('acftPat' .. i, '')
                    setBounds('acftPat' .. i, -300, -300, 64, 13)
                end
            end
        else
            -- CASE I & II: LIVE plot.  Each jet is placed at its REAL deck-frame
            -- position (acAhead/acStbd, metres) on the racetrack scope: boat at
            -- (270,163), bow to the RIGHT (+ahead → +x), starboard DOWN (+stbd →
            -- +y) so the PORT downwind rides the top leg.  We only set the TARGET
            -- here (~1 Hz); updateAcftLerp() eases the dot toward it every frame,
            -- so a pass flies smoothly and the groove shows the jet actually
            -- flying up the final instead of snapping onto the boat.
            -- ISOTROPIC mapping sized from the squadron's own tacview data
            -- (beta54): the old 2:1 x/y squash is why real tracks looked
            -- warped against the drawing.  Same constants as gen_lso_pattern.
            local BX, BY, SX, SY = 290, 193, 0.06, 0.06
            carrier.acftLerp = carrier.acftLerp or {}
            carrier.acftSlot = carrier.acftSlot or {}
            local L, SLOT = carrier.acftLerp, carrier.acftSlot
            for s = 1, 8 do if L[s] then L[s].active = false end end
            local liveMx = {}
            for _, r in base.ipairs(list) do liveMx[r.modex] = true end
            for mx, s in base.pairs(SLOT) do if not liveMx[mx] then SLOT[mx] = nil end end
            local taken = {}
            for _, s in base.pairs(SLOT) do taken[s] = true end
            local usedThisPoll = {}
            for _, r in base.ipairs(list) do
                local s = SLOT[r.modex]
                local fresh = false
                if s and usedThisPoll[s] then s = nil end   -- duplicate modex this poll
                if not s then
                    fresh = true                            -- new (or dup) → SNAP, don't swim
                    for k = 1, 8 do
                        if not taken[k] and not usedThisPoll[k] then s = k; break end
                    end
                    -- persist the mapping only for a genuinely new (non-dup) modex;
                    -- a duplicate gets a transient slot so BOTH jets still show.
                    if s and SLOT[r.modex] == nil then taken[s] = true; SLOT[r.modex] = s end
                end
                if s then
                    usedThisPoll[s] = true
                    local tx = BX + (r.ahead or 0) * SX
                    local ty = BY + (r.stbd or 0) * SY
                    if tx < 22 then tx = 22 elseif tx > 518 then tx = 518 end
                    if ty < 52 then ty = 52 elseif ty > 274 then ty = 274 end
                    if fresh or not L[s] then
                        L[s] = { x = tx, y = ty, tx = tx, ty = ty }   -- appear AT position
                    else
                        -- track direction (bearing leader) from target movement
                        local mvx, mvy = tx - L[s].tx, ty - L[s].ty
                        local mlen = math.sqrt(mvx * mvx + mvy * mvy)
                        if mlen > 0.8 then L[s].vx, L[s].vy = mvx / mlen, mvy / mlen end
                        L[s].tx = tx; L[s].ty = ty                    -- ease continuing jet
                    end
                    L[s].active = true
                    L[s].modex  = r.modex
                    L[s].altk   = math.floor((r.alt or 0) / 1000 + 0.5)
                    L[s].parked = false
                end
            end
        end

        -- GROOVE TIMER: clock starts when an aircraft is classified GROOVE and
        -- stops when it leaves (trap or bolter), saved as lastGroove.  Entry/
        -- exit is detected here at 1 Hz; updateGrooveTimer() refreshes the
        -- elapsed read-out every frame.
        carrier.grooveStart = carrier.grooveStart or {}
        local gnow = DCS.getRealTime() or 0
        local inGroove = {}
        for _, r in base.ipairs(list) do
            if r.point == 'GROOVE' then inGroove[r.modex] = true end
        end
        for m in base.pairs(inGroove) do
            if not carrier.grooveStart[m] then carrier.grooveStart[m] = gnow end
        end
        for m, t in base.pairs(carrier.grooveStart) do
            if not inGroove[m] then
                carrier.lastGroove = { modex = m, secs = gnow - t }
                carrier.grooveStart[m] = nil
            end
        end
        updateGrooveTimer()

        -- NEXT / UPCOMING — the recovery SEQUENCE the LSO works, nearest-to-land
        -- first.  Bridges the deadspot too (TOWER marshal reaches in to 15 nm,
        -- the LSO final scope out to 10 nm).  Built for BOTH cases:
        --   CASE III — pattern jets (on final, range = distance-to-go) merged
        --              with commenced CCZ jets (below ~5500 ft), sorted by range.
        --   CASE I   — pattern jets ordered by pattern point (GROOVE -> INITIAL).
        local caseIII = (carrier.recoveryCase == 'III')
        local caseII  = (carrier.recoveryCase == 'II')
        local seq, seen = {}, {}
        local PT_ORDER = { TRAP=0, GROOVE=1, ['90']=2, ['180']=3, ABEAM=4,
                           DOWNWIND=5, BREAK=6, INITIAL=7 }
        for _, r in base.ipairs(list) do
            local dtg = (-r.ahead) / 1852                       -- nm to go (astern +)
            local rng = (dtg >= 0) and dtg or (math.abs(r.ahead) / 1852)
            -- CASE III straight-in orders purely by range; CASE I & II visual
            -- pattern orders by pattern point (GROOVE first).
            seq[#seq + 1] = {
                modex = r.modex, alt = r.alt, gs = r.ias,
                rng = rng, key = caseIII and rng or (PT_ORDER[r.point] or 8),
                pos = caseIII and string.format('%4.1f nm', rng) or (r.point or '--'),
            }
            seen[r.modex] = true
        end
        -- Deadspot bridge: penetrating jets (below the marshal, not yet in the
        -- pattern) merged from the CCZ.  CASE III interleaves them by range;
        -- CASE II keys them 100+nm so they list AFTER the visual-pattern jets
        -- (a jet already in the overhead break recovers before one still
        -- penetrating at the same range).
        if caseIII or caseII then
            local cczC = (carrier.q and carrier.q.ccz) or ''
            for line in cczC:gmatch('[^\r\n]+') do
                local mx, _b, nm, alt, ias, role =
                    line:match('([^|]+)|(%-?%d+)|(%-?[%d%.]+)|(%-?%d+)|(%-?%d+)|(%a+)')
                if mx and role ~= 'TKR' and not seen[mx] then
                    local nmv, altv = tonumber(nm) or 0, tonumber(alt) or 0
                    if altv < 5500 and nmv < 25 then
                        seq[#seq + 1] = { modex = mx, alt = altv, gs = tonumber(ias) or 0,
                            rng = nmv, key = caseIII and nmv or (100 + nmv),
                            pos = string.format('%4.1f nm', nmv) }
                        seen[mx] = true
                    end
                end
            end
        end
        table.sort(seq, function(a, b) return a.key < b.key end)
        setText('lblLsoApproachHdr', caseIII
            and 'NEXT / UPCOMING  ·  recovery sequence (nearest first)'
            or  (caseII and 'NEXT / UPCOMING  ·  pattern + inbound'
                        or  'NEXT / UPCOMING  ·  in the pattern'))
        setText('lblLsoApproachCols', caseIII
            and 'MODEX         RANGE        ALT          GS'
            or  'MODEX         POINT        ALT          GS')
        for i = 1, 4 do
            local r = seq[i]
            if r then
                local tag = (i == 1) and '>' or ' '
                setText('rowLsoApp' .. i, string.format('%s%-7s  %-9s  %5d ft  %3d kt',
                    tag, r.modex:sub(1, 7), r.pos, r.alt, r.gs))
            else
                setText('rowLsoApp' .. i, '')
            end
        end
    end

    -- ─── DECKBOSS top-down deck view ─────────────────────────────────────
    local function readDeckState()
        local content = (carrier.q and carrier.q.deck) or ''
        if content == '' and not carrier.olympusActive then content = slurp(DECK_FILE_V13) end
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

        -- Deck spots — red blip + id label over the deck IMAGE, decluttered so
        -- parked jets don't overlap.  Image frame (x10,y54,520x139): bow = LEFT,
        -- starboard = TOP.  along +160=bow→x40, -190=stern→x500;
        -- across +45=stbd→y78, -45=port→y170.  (Linear fit — refine the four
        -- constants if jets sit off their real spots.)
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
        -- Calibration: jets were sitting too far FORWARD (toward the bow/left),
        -- so shift the whole plot aft.  Tunable in metres — raise to push further
        -- aft (right), lower toward 0 to move forward (left).
        local DECK_AFT_OFFSET = 35
        for i = 1, 16 do
            local r = rows[i]
            if r then
                local a = r.along - DECK_AFT_OFFSET
                if a >  160 then a =  160 elseif a < -190 then a = -190 end
                local cc = r.across
                if cc >  45 then cc =  45 elseif cc < -45 then cc = -45 end
                local dxp = math.floor(40 + (160 - a) / 350 * 460)
                local dyp = math.floor(68 + (45 - cc) / 90  * 92)
                setBounds('dbDot' .. i, dxp - 3, dyp - 3, 6, 6)
                local lx = dxp + 7
                local ly = dfreeY(lx, dyp - 6)
                table.insert(dplaced, { x = lx, y = ly })
                setText('spotDb' .. i, r.modex:sub(1, 8))
                setBounds('spotDb' .. i, lx, ly, 56, 13)
            else
                setBounds('dbDot' .. i, -300, -300, 6, 6)
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

    -- (conga toggle state lives on carrier.congaOn; overlay drawn by applyConga)

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
            -- v1.3-beta29: radar/roster data comes from the mission query and
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
        -- Attach BOTH callbacks, each guarded: Buttons fire addChangeCallback
        -- on press; Statics (e.g. table cells) only ever emit mouse events, and
        -- some widgets lack one method entirely.  pcall so a missing/!throwing
        -- method on one widget can't abort the rest of createWindow.
        if btn.addChangeCallback then
            base.pcall(function() btn:addChangeCallback(function(self) fn() end) end)
        end
        if btn.addMouseDownCallback then
            base.pcall(function() btn:addMouseDownCallback(function() fn() end) end)
        end
    end

    local function wireButton(name, flagNum)
        wireClick(name, function() fireFlag(flagNum) end)
    end

    local respawnWindow   -- forward-declared: button callbacks inside
                          -- createWindow close over it (assigned below)

    -- UI-scale stepping, shared by the login button (cycle) and the
    -- Ctrl+Shift+I / Ctrl+Shift+K hotkeys (up / down, any tab).  Debounced —
    -- hotkeys are window-bound and rescale orphans old windows.
    local SCALE_STEPS = { 75, 100, 125, 150 }
    local function applyScaleStep(dir, wrap)
        local nowD = DCS.getRealTime() or 0
        if nowD - (carrier._lastScaleKey or -9) < 0.6 then return end
        carrier._lastScaleKey = nowD
        local cur = math.floor((carrier._pendingScale or carrier.uiScale or 1) * 100 + 0.5)
        local idx = 2
        for i, v in base.ipairs(SCALE_STEPS) do if v == cur then idx = i end end
        idx = idx + dir
        if wrap then
            if idx > #SCALE_STEPS then idx = 1 elseif idx < 1 then idx = #SCALE_STEPS end
        else
            if idx > #SCALE_STEPS then idx = #SCALE_STEPS elseif idx < 1 then idx = 1 end
        end
        local nxt = SCALE_STEPS[idx]
        if nxt == cur then return end
        carrier._pendingScale = nxt / 100
        base.pcall(function()
            local f = io.open(lfs.writedir() .. 'carriergui_scale.txt', 'w')
            if f then f:write(tostring(nxt)); f:close() end
        end)
        local patched = carrier.writeDlgScale and carrier.writeDlgScale(nxt / 100)
        logInfo('ui scale -> ' .. tostring(nxt) .. ' (dlg patched=' .. tostring(patched) .. ')')
        if patched and respawnWindow then respawnWindow() end
    end

    local function createWindow()
        -- re-read the dlg's baked scale each spawn — a LIVE RESCALE patches the
        -- line then re-spawns, so this is where the new size takes effect
        UI_SCALE = readDlgScale() or 1.0
        carrier.uiScale = UI_SCALE
        rebuildRowSkins()   -- row-skin fonts track the scale; red-cache reset
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
        carrier.window:setBounds(carrier.showX, carrier.showY,
            math.floor(FULL_W * (carrier.uiScale or 1) + 0.5), math.floor(FULL_H * (carrier.uiScale or 1) + 0.5))
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
        -- UI-scale hotkeys — work from ANY tab (I = bigger, K = smaller)
        base.pcall(function()
            carrier.window:addHotKeyCallback('Ctrl+Shift+i', function() applyScaleStep(1) end)
            carrier.window:addHotKeyCallback('Ctrl+Shift+k', function() applyScaleStep(-1) end)
        end)

        -- wire every simple fire-flag button
        for name, flag in base.pairs(BUTTON_FLAGS) do
            wireButton(name, flag)
        end

        -- tab buttons (4 tabs; CARRIER removed in beta44)
        wireClick('btnTabMarshall', function() showTab('marshall') end)
        wireClick('btnTabTower',    function() showTab('tower')    end)
        wireClick('btnTabLso',      function() showTab('lso')      end)
        wireClick('btnTabDeckboss', function() showTab('deckboss') end)

        -- ── LOGIN (beta50): Olympus is the front door ─────────────────────
        local function loginField(name, fallback)
            local v = nil
            base.pcall(function()
                local w = carrier.window and carrier.window[name]
                if w and w.getText then v = w:getText() end
            end)
            if v ~= nil and tostring(v) ~= '' then return tostring(v) end
            return fallback
        end
        local function setLoginStatus(txt)
            base.pcall(function() setText('lblLoginStatus', txt or '') end)
        end
        -- clear all live/session picture state so a mode change never renders
        -- a frozen copy of the previous source (and never blocks the file
        -- fallback, which is gated on empty carrier.q strings)
        local function clearPicture()
            carrier.q = { ship = '', stack = '', ccz = '', pattern = '', deck = '' }
            carrier.panelCh = {}
            carrier.marshalEAT = {}
            carrier.shipHdg, carrier.shipFB, carrier.shipTod = nil, nil, nil
            carrier.shipWindFrom, carrier.shipWindKts = nil, nil
            carrier.shipHeadKts, carrier.shipCrossKts = nil, nil
            carrier.callsign, carrier.altimeter = nil, nil
            carrier.olympusActive = false
        end
        wireClick('btnConnect', function()
            if not CGOLY then setLoginStatus('Olympus client failed to load - see dcs.log') return end
            if not CGOLY.socketAvailable() then setLoginStatus('luasocket unavailable in this DCS install') return end
            local savedHost, savedPort = loadLogin()
            local host = loginField('edHost', savedHost)
            local port = loginField('edPort', savedPort)
            local pass = loginField('edPass', '')
            if host == '' then setLoginStatus('Enter the Olympus host / IP.') return end
            local okCfg, cfgErr = CGOLY.configure(host, port, pass)
            if not okCfg then setLoginStatus(cfgErr or 'bad host') return end
            CGOLY.start()
            carrier.connecting = true
            carrier._loginHost, carrier._loginPort = host, port
            setLoginStatus('CONNECTING to ' .. host .. ':' .. tostring(port) .. ' ...')
            logInfo('Olympus connect -> ' .. host .. ':' .. tostring(port))
        end)
        wireClick('btnLocalMode', function()
            if CGOLY then CGOLY.stop() end
            clearPicture()
            carrier.connecting = false
            carrier.loggedIn = true
            carrier.dataMode = 'local'
            showTab('marshall')
            logInfo('local/host mode selected')
        end)
        -- UI SIZE: applies INSTANTLY via live respawn.  Button cycles the
        -- steps; Ctrl+Shift+I / Ctrl+Shift+K step up/down from ANY tab; the
        -- window corner-drag also rescales on release.
        base.pcall(function()
            setText('btnUiScale', string.format('UI SIZE: %d%%',
                math.floor((carrier.uiScale or 1) * 100 + 0.5)))
        end)
        wireClick('btnUiScale', function() applyScaleStep(1, true) end)

        wireClick('btnLogout', function()
            if CGOLY then CGOLY.stop() end
            clearPicture()
            carrier.connecting = false
            carrier.loggedIn = false
            carrier.dataMode = nil
            setLoginStatus('')
            -- wipe the GM password field (shared/streamed machines)
            base.pcall(function()
                if carrier.window.edPass and carrier.window.edPass.setText then
                    carrier.window.edPass:setText('')
                end
            end)
            showTab('login')
            logInfo('logged out')
        end)

        -- Recovery CASE buttons (MARSHALL): set the active case, which switches
        -- the marshalling/approach procedures across the panel.
        -- (They ALSO fire flags 202/203/204 via BUTTON_FLAGS to broadcast it.)
        local function setRecoveryCase(c)
            carrier.recoveryCase = c
            base.pcall(function() net.dostring_in('server', '__cgCase = "' .. c .. '"') end)
            base.pcall(function() showTab(carrier.tab) end)   -- re-gate CASE I/III drawings
            logInfo('recovery case -> CASE ' .. c)
        end
        wireClick('btnCaseM1', function() setRecoveryCase('I')   end)
        wireClick('btnCaseM2', function() setRecoveryCase('II')  end)
        wireClick('btnCaseM3', function() setRecoveryCase('III') end)

        -- (v1.3-beta29's runtime image overlay removed in beta22: dxgui's
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

        -- v1.3-beta29: WIRE / DECK / ZOOM were retired in beta4, but the hook
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

        -- v1.3: DECKBOSS conga-line toggle — draws the preferred taxi/respot
        -- flow over the deck image (view-only; no game-state writes).
        wireClick('btnDbConga', function()
            carrier.congaOn = not carrier.congaOn
            if carrier.window.lblDbCongaState then
                base.pcall(function()
                    carrier.window.lblDbCongaState:setText(
                        'CONGA LINE:  ' .. (carrier.congaOn and 'ON' or 'OFF'))
                end)
            end
            base.pcall(applyConga)
            logInfo('conga toggle -> ' .. tostring(carrier.congaOn))
        end)

        -- BROADCAST MARSHAL STACK — lives on the CARRIER tab as of beta30.
        -- Count is taken live from the CCZ rather than a manual flight stepper.
        wireClick('btnMarshalBroadcast', function()
            local n = 0
            for _ in tostring(carrier.q and carrier.q.stack or ''):gmatch('[^\r\n]+') do n = n + 1 end
            setFlagValue('cg_marshal_flights', math.max(1, n))
            fireFlag(200)
        end)
        -- beta31: TOWER click-to-Charlie.  Clicking any cell in a STACK row
        -- gives that jet a Charlie (panel-only — it hops to the CHARLIE'D
        -- table); clicking a CHARLIE'D row undoes it.  The row→modex maps are
        -- refreshed every poll by readStackState.  __CGQ.ch lives in the
        -- mission state; the query reads it to drive the state machine, and
        -- auto-commences the jet when it swings through point 3.
        local function setCharlie(modex, on)
            if not modex or modex == '' then return end
            -- panel-side flag for instant feedback; readStackState applies it each poll.
            carrier.panelCh = carrier.panelCh or {}
            carrier.panelCh[modex] = on and true or false
            -- authoritative flag in the mission state (query reads it, and
            -- auto-commences the jet when it swings through point 3).
            base.pcall(function()
                net.dostring_in('server', string.format(
                    'if __CGQ then __CGQ.ch[%q] = %s end',
                    modex, on and 'true' or 'nil'))
            end)
        end
        -- Per-row action buttons (reliable click target).  STACK 'C' → Charlie;
        -- CHARLIE'D 'U' → undo.
        for r = 1, 8 do
            wireClick('tsBtn' .. r, function()
                setCharlie(carrier.stackRowModex and carrier.stackRowModex[r], true)
            end)
        end
        for r = 1, 5 do
            wireClick('tdBtn' .. r, function()
                setCharlie(carrier.charlieRowModex and carrier.charlieRowModex[r], false)
            end)
        end
        -- Also make the whole row clickable, in case Static cells DO emit mouse
        -- events on this build (harmless duplicate of the button handler).
        for r = 1, 8 do
            for ccol = 1, 5 do
                wireClick('tsCell' .. r .. '_' .. ccol, function()
                    setCharlie(carrier.stackRowModex and carrier.stackRowModex[r], true)
                end)
            end
        end
        for r = 1, 5 do
            for ccol = 1, 5 do
                wireClick('tdCell' .. r .. '_' .. ccol, function()
                    setCharlie(carrier.charlieRowModex and carrier.charlieRowModex[r], false)
                end)
            end
        end

        -- Probe for an image TGA in the DCS install (placed by Enable-LsoTools).
        -- If found, the matching image overlay is allowed to show; otherwise it
        -- stays hidden and the drawn fallback remains.
        local function probeTga(fileName)
            local rel = 'Mods\\tech\\Supercarrier\\PLATCameraUI\\' .. fileName
            local cands = {
                rel, '..\\' .. rel, '.\\' .. rel,
                'C:\\Program Files\\Eagle Dynamics\\DCS World\\' .. rel,
                'C:\\Program Files\\Eagle Dynamics\\DCS World OpenBeta\\' .. rel,
                'D:\\Eagle Dynamics\\DCS World\\' .. rel,
                'D:\\DCS World\\' .. rel,
                'E:\\Eagle Dynamics\\DCS World\\' .. rel,
            }
            for _, p in base.ipairs(cands) do
                local ok, f = base.pcall(function() return base.io.open(p, 'rb') end)
                if ok and f then f:close() return true end
            end
            return false
        end
        carrier.radarImgOk = probeTga('carriergui_radar.tga')
        carrier.deckImgOk  = probeTga('carriergui_deck.tga')
        logInfo('radar image TGA ' .. (carrier.radarImgOk and 'found — overlay enabled' or 'not found — using dot rings'))
        logInfo('deck image TGA '  .. (carrier.deckImgOk  and 'found — overlay enabled' or 'not found — using hint'))

        -- beta50: LOGIN is the front door; prefill host/port from the last
        -- successful connect (password is never persisted to disk).  A live
        -- rescale keeps whatever was TYPED (incl. password) via _loginKeep.
        base.pcall(function()
            local keep = carrier._loginKeep
            carrier._loginKeep = nil
            local h, po = loadLogin()
            local pw = ''
            if keep then
                if keep.host ~= '' then h = keep.host end
                if keep.port ~= '' then po = keep.port end
                pw = keep.pass or ''
            end
            if h ~= '' and carrier.window.edHost and carrier.window.edHost.setText then
                carrier.window.edHost:setText(h)
            end
            if po ~= '' and carrier.window.edPort and carrier.window.edPort.setText then
                carrier.window.edPort:setText(po)
            end
            if pw ~= '' and carrier.window.edPass and carrier.window.edPass.setText then
                carrier.window.edPass:setText(pw)
            end
        end)
        -- restore the working tab on a live-rescale respawn; fresh start = login
        showTab(carrier.tab or 'login')
        -- re-drive state the dlg defaults would otherwise contradict:
        base.pcall(function()
            setText('lblDbCongaState', 'CONGA LINE:  ' .. (carrier.congaOn and 'ON' or 'OFF'))
        end)
        do  -- WAVE OFF / CUT still inside their 5 s latch: re-light on the new window
            local nowL = DCS.getRealTime() or 0
            for name, tUntil in base.pairs(lightActiveUntil) do
                if tUntil > nowL then base.pcall(setLightLit, name, true) end
            end
        end

        carrier.windowCreated = true
        if carrier._respawnShow then
            carrier._respawnShow = nil
            show()                      -- live rescale: stay on screen
        else
            hide()                      -- fresh start: hidden until hotkey
        end
        logInfo(string.format('window created (scale %d%%)', (carrier.uiScale or 1) * 100))
        return true
    end

    -- LIVE RESCALE: hide + abandon the current window, patch already done by
    -- the caller, then let the next frame's createWindow() rebuild everything
    -- at the new baked scale.  All state (login/Olympus/EATs/tabs) lives in
    -- `carrier`/CGOLY, not the window, so nothing disconnects.  The old window
    -- is orphaned (dxgui has no reliable destroy) — shrunk to 0x0, harmless.
    respawnWindow = function()
        carrier._respawnShow = carrier.visible
        -- keep whatever the user typed on the login form across the respawn
        base.pcall(function()
            carrier._loginKeep = {
                host = carrier.window.edHost and carrier.window.edHost:getText() or '',
                port = carrier.window.edPort and carrier.window.edPort:getText() or '',
                pass = carrier.window.edPass and carrier.window.edPass:getText() or '',
            }
        end)
        -- keep the panel where the user dragged it (API-guarded)
        base.pcall(function()
            local x, y = carrier.window:getPosition()
            if type(x) == 'number' and type(y) == 'number' then
                carrier.showX, carrier.showY = x, y
            end
        end)
        base.pcall(function()
            carrier.window:setVisible(false)
            carrier.window:setSize(0, 0)
        end)
        carrier.window = nil
        carrier.windowCreated = false
        carrier.createAttempts = 0
        carrier._baseW, carrier._dragW = nil, nil   -- fresh drag baseline
        carrier._pendingScale = nil                 -- dlg line is authoritative now
        carrier.nvgReapplied, carrier.nvgReapplyAt = nil, nil  -- re-arm LED stomp guard
        -- force the live-plot labels/parking to re-drive on the new window
        if carrier.acftLerp then
            for _, e in base.pairs(carrier.acftLerp) do e.lb, e.parked = nil, false end
        end
        -- re-probe the bridge so lblStatus/lblNvgState repaint (local mode)
        carrier.bridgeProbeAt = (DCS.getRealTime() or 0) + 1
        logInfo('live rescale: respawning window')
    end

    -- ------------------------------------------------ DCS hook callbacks ---
    local handler = {}

    function handler.onSimulationFrame()
        -- Cap window-creation attempts.  On a normal client the dialog spawns on
        -- attempt 1.  On a HEADLESS dedicated server there is no GUI Lua state
        -- (DialogLoader/dxgui absent), so creation fails — without this cap it
        -- would retry and log every frame forever.  Try a handful of times, then
        -- give up quietly so the hook is harmless on a server.
        if not carrier.windowCreated then
            carrier.createAttempts = (carrier.createAttempts or 0) + 1
            if carrier.createAttempts <= 30 then
                base.pcall(createWindow)
                if not carrier.windowCreated and carrier.createAttempts == 30 then
                    logErr('window not created after 30 tries — disabling ' ..
                           '(headless server / no GUI state?)')
                end
            end
        end
        if carrier.bridgeProbeAt and DCS.getRealTime() >= carrier.bridgeProbeAt then
            carrier.bridgeProbeAt = nil
            base.pcall(probeBridge)
        end
        -- ── kneeboard-style drag rescale ─────────────────────────────────
        -- Watch the frame size; once the user releases the drag (~0.6 s at a
        -- stable size different from the built size) snap the scale to the
        -- dragged WIDTH and rebuild the panel at it (live, no restart).
        if carrier.windowCreated and carrier.window and carrier.visible
           and not carrier._noGetSize then
            local dnow = DCS.getRealTime() or 0
            local okS, gw = base.pcall(function() return carrier.window:getSize() end)
            if not okS or type(gw) ~= 'number' then
                carrier._noGetSize = true   -- API absent: drag off (button still works)
                logInfo('drag-rescale: getSize unavailable, using button only')
            elseif not carrier._baseW then
                -- baseline = the size dxgui ACTUALLY spawned at (not our math):
                -- comparing against a computed width could disagree by a few px
                -- and trigger an endless respawn loop.
                carrier._baseW = gw
            else
                if math.abs(gw - carrier._baseW) > 10 then
                    if gw ~= carrier._dragW then
                        carrier._dragW, carrier._dragT = gw, dnow
                    elseif dnow - (carrier._dragT or 0) > 0.6 then
                        -- drag released: derive scale from the dragged width
                        -- relative to the 100% width
                        local sc = (carrier.uiScale or 1) * gw / carrier._baseW
                        if sc < 0.5 then sc = 0.5 elseif sc > 2.5 then sc = 2.5 end
                        sc = math.floor(sc * 20 + 0.5) / 20      -- 5% steps
                        carrier._dragW = nil
                        base.pcall(function()
                            local f = io.open(lfs.writedir() .. 'carriergui_scale.txt', 'w')
                            if f then f:write(tostring(math.floor(sc * 100 + 0.5))); f:close() end
                        end)
                        if carrier.writeDlgScale and carrier.writeDlgScale(sc) and respawnWindow then
                            respawnWindow()
                        end
                    end
                else
                    carrier._dragW = nil
                end
            end
        end
        -- ── Olympus client pump + login state machine ────────────────────
        if CGOLY then
            base.pcall(CGOLY.tick)
            if carrier.connecting then
                local st = CGOLY.status()
                if st.ok then
                    carrier.connecting = false
                    carrier.loggedIn = true
                    carrier.dataMode = 'olympus'
                    saveLogin(carrier._loginHost or '', carrier._loginPort or '')
                    showTab('marshall')
                    logInfo('Olympus connected — live')
                elseif not st.enabled then
                    -- auth rejection (client disables itself) or hard stop
                    carrier.connecting = false
                    base.pcall(function()
                        setText('lblLoginStatus', st.lastError or 'connection failed')
                    end)
                elseif st.fails >= 3 then
                    carrier.connecting = false
                    CGOLY.stop()
                    base.pcall(function()
                        setText('lblLoginStatus', (st.lastError or 'connection failed')
                            .. '  - check host/port and that Olympus is running')
                    end)
                end
            elseif carrier.dataMode == 'olympus' then
                -- CONNECTED session watchdog: auth revoked mid-session = forced
                -- logout; a quiet feed = visible STALE banner (never a silent
                -- frozen picture).
                local st = CGOLY.status()
                if not st.enabled then
                    carrier.loggedIn = false
                    carrier.dataMode = nil
                    carrier.olympusActive = false
                    carrier.q = { ship = '', stack = '', ccz = '', pattern = '', deck = '' }
                    base.pcall(function()
                        setText('lblLoginStatus', st.lastError or 'Olympus connection lost')
                    end)
                    showTab('login')
                    logInfo('Olympus session dropped -> login')
                else
                    base.pcall(function()
                        if st.ageSecs and st.ageSecs > 5 then
                            setText('lblStatus', string.format(
                                'OLYMPUS: STALE %ds — reconnecting...', math.floor(st.ageSecs)))
                        elseif st.ok then
                            setText('lblStatus', '')
                        end
                    end)
                end
            end
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
            -- Elevator instrument FIRST and unconditionally: it must run even
            -- when dataMode is nil (still on the login tab), which is exactly
            -- the case that produced a silent no-op on the first test run.
            base.pcall(pollElevatorArgs)
            base.pcall(runMissionQuery)
            base.pcall(readShipState)
            -- Olympus mode: backfill QNH/weather/wind from the client's own
            -- mission copy (the units feed doesn't carry them)
            if carrier.dataMode == 'olympus' then base.pcall(readClientMissionWx) end
            base.pcall(renderLsoGrades)   -- (replaces bridge event tailing)
            base.pcall(readStackState)
            base.pcall(readCczState)
            base.pcall(readPatternState)
            base.pcall(readDeckState)
        end
        -- Every frame: decay WAVE OFF / CUT light timers (short-lived state)
        -- and tick the groove timer so it climbs smoothly between 1 Hz polls.
        base.pcall(updateLights)
        base.pcall(updateGrooveTimer)
        -- Smoothly ease the CASE I/II live aircraft dots every frame (CASE III
        -- positions its own dots directly in readPatternState).
        if carrier.tab == 'lso' and carrier.recoveryCase ~= 'III' then
            base.pcall(updateAcftLerp)
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
        -- next mission may have a different date → re-init magvar for it
        if carrier.resetMagvarInit then base.pcall(carrier.resetMagvarInit) end
    end

    DCS.setUserCallbacks(handler)
    logInfo('hook loaded (v1.3-beta60)')
end

local ok, err = pcall(load)
if not ok then
    -- last-ditch logging — at this point even our log helper might not exist
    if base.log and base.log.write then
        base.log.write('CarrierGUI', base.log.ERROR, 'load failed: ' .. tostring(err))
    end
end
