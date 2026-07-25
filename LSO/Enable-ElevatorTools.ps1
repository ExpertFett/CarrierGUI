<#
    Enable-ElevatorTools.ps1   (CarrierGUI v1.4 - EXPERIMENTAL)

    Tests / drives the DCS Supercarrier deck ELEVATORS from the CarrierGUI
    ELEVATOR tab by patching ONE stock file:

      Mods\tech\Supercarrier\AirBossScreensUI\AirBoss.lua
        Injects a probe + command bridge into update(shipId):
          * one-shot PROBE  - logs (dcs.log) and writes carriergui_elev_result.txt
            telling us whether the engine global setElevatorCommand actually
            exists in the AirBoss screen Lua state.
          * COMMAND POLL    - reads Saved Games\DCS\carriergui_elev_cmd.txt
            ("idx,cmd"; idx 0-3, cmd 1=down/2=up) written by the CarrierGUI hook,
            calls setElevatorCommand(shipId, idx, cmd), and writes the result
            back to carriergui_elev_result.txt (shown on the panel).

    WHY this file: setElevatorCommand is referenced (commented out) in
    Elevators.lua but defined nowhere in Lua, so it can only be a C++ engine
    global living in the AirBoss screen state - which the GameGUI hook cannot
    reach. AirBoss.lua runs in that state AND receives a valid shipId, so it is
    the correct place to probe and call it.

    EXPERIMENTAL. Modifies a core Supercarrier file -> FAILS multiplayer
    integrity check. Single-player / IC-free test servers only. DCS reverts it
    on update (just re-run). Fully reversible via Disable-ElevatorTools.ps1.

    Usage:
      Enable-ElevatorTools.ps1                  (auto-find DCS, self-elevate)
      Enable-ElevatorTools.ps1 -DcsRoot <path>  (explicit root, no elevation)
#>
param([string]$DcsRoot)

$ErrorActionPreference = 'Stop'

# ---- self-elevate (auto mode only) -------------------------------------------
if (-not $DcsRoot) {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
        exit
    }
}

$logPath = Join-Path $PSScriptRoot 'ElevatorTools-install-log.txt'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

Write-Host '=== CarrierGUI ELEVATOR tools installer (EXPERIMENTAL) ===' -ForegroundColor Cyan
Write-Host "Started: $(Get-Date)"
Write-Host "Log:     $logPath"
Write-Host ''

# ---- refuse to run while DCS holds the file ----------------------------------
$running = @(Get-Process -Name 'DCS','DCS_server' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host 'ERROR: DCS is running. Close DCS (and any server) first, then re-run.' -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    pause; exit 1
}

# ---- locate DCS --------------------------------------------------------------
function Find-Dcs {
    $drives   = 'C','D','E','F','G','H'
    $suffixes = @(
        'Program Files\Eagle Dynamics\DCS World',
        'Program Files\Eagle Dynamics\DCS World OpenBeta',
        'Program Files (x86)\Eagle Dynamics\DCS World',
        'Program Files (x86)\Eagle Dynamics\DCS World OpenBeta',
        'SteamLibrary\steamapps\common\DCSWorld',
        'Games\DCS World','DCS World','Eagle Dynamics\DCS World')
    foreach ($d in $drives) {
        if (-not (Test-Path "${d}:\" -ErrorAction SilentlyContinue)) { continue }
        foreach ($s in $suffixes) {
            $p = "${d}:\$s"
            try {
                if (Test-Path "$p\Mods\tech\Supercarrier\AirBossScreensUI\AirBoss.lua" -ErrorAction SilentlyContinue) {
                    return $p
                }
            } catch {}
        }
    }
    return $null
}

if ($DcsRoot) { $dcs = $DcsRoot } else { $dcs = Find-Dcs }
if (-not $dcs) {
    Write-Host 'ERROR: No DCS install with the Supercarrier module found.' -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    pause; exit 1
}
Write-Host "Using DCS: $dcs" -ForegroundColor Cyan

$lua    = Join-Path $dcs 'Mods\tech\Supercarrier\AirBossScreensUI\AirBoss.lua'
$luaBak = "$lua.cgelev.bak"
if (-not (Test-Path $lua)) {
    Write-Host "ERROR: AirBoss.lua not found at $lua" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    pause; exit 1
}

$MARK = 'CARRIERGUI_ELEVATOR_TOOLS'

# ---- update-resilient backup (always patch from a clean baseline) ------------
$live = [IO.File]::ReadAllText($lua)
if (-not $live.Contains($MARK)) {
    Copy-Item $lua $luaBak -Force
    Write-Host 'Backed up AirBoss.lua (fresh clean baseline)'
} elseif (Test-Path $luaBak) {
    Copy-Item $luaBak $lua -Force
    Write-Host 'Restored clean AirBoss.lua from backup before re-patching'
} else {
    Copy-Item $lua $luaBak -Force
}

$t = [IO.File]::ReadAllText($luaBak)
$anchor = 'function update(shipId)'
if (-not $t.Contains($anchor)) {
    Write-Host "ERROR: anchor '$anchor' not found in AirBoss.lua (DCS layout changed?)" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    pause; exit 1
}

# Injected Lua. base = _G in AirBoss.lua, so base.io / base.os / base.tonumber
# reach the (unsanitized) GUI-side std libs; print + string + lfs are locals.
$inject = @'

  -- BEGIN CARRIERGUI_ELEVATOR_TOOLS
  base.pcall(function()
    local fn = base.setElevatorCommand
    if not base.__cgElevProbed then
      base.__cgElevProbed = true
      base.print('CARRIERGUI ELEV PROBE: env=airboss shipId=' .. base.tostring(shipId) .. ' setElevatorCommand=' .. base.type(fn))
      if base.io then
        local pf = base.io.open(lfs.writedir() .. 'carriergui_elev_result.txt', 'w')
        if pf then pf:write('probe env=airboss shipId=' .. base.tostring(shipId) .. ' setElevatorCommand=' .. base.type(fn)) pf:close() end
      end
    end
    if base.io then
      local cf = lfs.writedir() .. 'carriergui_elev_cmd.txt'
      local h = base.io.open(cf, 'r')
      if h then
        local line = h:read('*a') or ''
        h:close()
        if base.os then base.os.remove(cf) end
        local i, c = string.match(line, '(%d+)%s*,%s*(%d+)')
        if i then
          local res
          if base.type(fn) == 'function' then
            local ok, err = base.pcall(fn, shipId, base.tonumber(i), base.tonumber(c))
            res = 'cmd idx=' .. i .. ' cmd=' .. c .. ' ok=' .. base.tostring(ok) .. ' err=' .. base.tostring(err)
          else
            res = 'setElevatorCommand=' .. base.type(fn) .. ' (binding absent) idx=' .. i .. ' cmd=' .. c
          end
          base.print('CARRIERGUI ELEV ' .. res)
          local rf = base.io.open(lfs.writedir() .. 'carriergui_elev_result.txt', 'w')
          if rf then rf:write(res) rf:close() end
        end
      end
    end
  end)
  -- END CARRIERGUI_ELEVATOR_TOOLS
'@

$t = $t.Replace($anchor, $anchor + $inject)
[IO.File]::WriteAllText($lua, $t)   # WriteAllText = UTF-8 no BOM (DCS-safe)
Write-Host 'Patched AirBoss.lua (elevator probe + command bridge)' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT:' -ForegroundColor Cyan
Write-Host '  1. Launch DCS, start a Supercarrier mission with a CVN.'
Write-Host '  2. Open the AirBoss / deck-control interface so the airboss screens tick.'
Write-Host '  3. Ctrl+Shift+c -> ELEVATOR tab, press RAISE / LOWER. Read the status:'
Write-Host '       "...setElevatorCommand=function"  => engine accepts it (watch the deck!)'
Write-Host '       "...=nil (binding absent)"         => ED cut the engine binding; dead end'
Write-Host '  4. Watch the elevator; add a 2nd client to confirm MP sync.'
Write-Host ''
Write-Host 'Undo: Disable-ElevatorTools.ps1'
Write-Host ''
try { Stop-Transcript | Out-Null } catch {}
if (-not $DcsRoot) { pause }
