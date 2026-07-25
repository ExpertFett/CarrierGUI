-- carrier-gui-server.lua  (v1.3-beta45)
-- CarrierGUI DEDICATED-SERVER bridge injector.
--
-- A headless dedicated server can't render the Ctrl+Shift+c panel, so carrier
-- control is the in-game F10 "Carrier Control" radio menu built by the bridge.
-- This GameGUI hook loads the bridge straight into the mission scripting env on
-- each mission start via net.dostring_in('server', ...).  That's reliable on a
-- dedicated server (the hook + mission run in one process) and does NOT depend
-- on the .miz trigger firing.  The bridge's own idempotency guard means it's
-- safe even if the mission ALSO embeds it.
--
-- Deck lights still need the patcher's native triggers, so the loaded mission
-- should still be run through Patch Mission.bat (which also embeds the carrier).
--
-- INSTALL: drop this + carrier-gui-bridge.lua in the dedicated server's
--   Saved Games\<server profile>\Scripts\Hooks\  then restart the server.

local BRIDGE = lfs.writedir() .. [[Scripts\Hooks\carrier-gui-bridge.lua]]

local function L(m)
    if log and log.write then log.write('CarrierGUI-Server', log.INFO, m) end
end

local cb = {}

function cb.onSimulationStart()
    local ok, err = pcall(function()
        local f = io.open(BRIDGE, 'r')
        if not f then
            L('ERROR bridge file not found: ' .. BRIDGE)
            return
        end
        local code = f:read('*a')
        f:close()
        if not code or code == '' then
            L('ERROR bridge file empty: ' .. BRIDGE)
            return
        end
        net.dostring_in('server', code)
        L('bridge injected (' .. tostring(#code) .. ' bytes) -> F10 Carrier Control should be live')
    end)
    if not ok then L('ERROR inject failed: ' .. tostring(err)) end
end

DCS.setUserCallbacks(cb)
L('CarrierGUI server injector loaded')
