<#
    Enables the CarrierGUI v1.1 LSO tab features by patching DCS:

      gui.fx (Bazar\shaders\MissionEditor\gui.fx)
          - Alpha-as-gain NVG mixer (unchanged from v1.0)

      PLATCameraUI.lua (Mods\tech\Supercarrier\PLATCameraUI\)
          - Reads carriergui_nvg.txt     -> sets PLAT widget alpha (NVG gain)
          - Reads carriergui_foul.txt    -> setFoulDeck(true/false)
          - Reads carriergui_wire.txt    -> setDesiredRope(1..4)
          - Reads carriergui_zoom.txt    -> adjustGate(fov, ...) PLAT FOV
          File reads are throttled to ~30 frames so we're not pegging the IO.

    Same .platcamnvg.bak files as the v1.0 Enable-NvgDial script — safe to
    run if you previously ran that. Safe to re-run.

    Self-elevates (UAC). Modifies Program Files; needs admin.
    NOTE: modifies a core shader -> FAILS multiplayer integrity check.
    Single-player / IC-free servers only. Fully reversible via
    Disable-LsoTools.ps1.
#>

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------- transcript log ----------
# Always write a log file next to this script so silent failures / fast-closing
# windows aren't a problem. Best-effort; if PowerShell can't transcript (e.g.,
# locked, AV, weird policy) we proceed anyway.
$logPath = Join-Path $PSScriptRoot 'LsoTools-install-log.txt'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

Write-Host '=== CarrierGUI LSO tools installer ===' -ForegroundColor Cyan
Write-Host "Started: $(Get-Date)"
Write-Host "Script:  $PSCommandPath"
Write-Host "Log:     $logPath"
Write-Host ''

# ---------------------------------------------------------------- locate DCS --
# Search every drive letter for an Eagle Dynamics install in BOTH
# Program Files and Program Files (x86). Plus a couple of Steam library
# fallbacks. The first candidate that has Bazar\shaders\MissionEditor\gui.fx
# wins. Logs every candidate checked so it's obvious where DCS was found
# (or every place we looked if not).
$drives   = 'C','D','E','F','G','H'
$suffixes = @(
    'Program Files\Eagle Dynamics\DCS World',
    'Program Files\Eagle Dynamics\DCS World OpenBeta',
    'Program Files (x86)\Eagle Dynamics\DCS World',
    'Program Files (x86)\Eagle Dynamics\DCS World OpenBeta',
    'SteamLibrary\steamapps\common\DCSWorld',
    'Games\DCS World',
    'Games\Eagle Dynamics\DCS World',
    'DCS World',
    'Eagle Dynamics\DCS World'
)
Write-Host 'Searching for DCS install...'
$candidates = @()
foreach ($d in $drives) {
    # Skip drive letters that aren't ready (empty card readers, USB slots,
    # disconnected network drives).  Without this guard, Join-Path / Test-Path
    # throw DriveNotFoundException on a not-ready drive (e.g. F:) and abort the
    # whole patch before it runs.
    if (-not (Test-Path "${d}:\" -ErrorAction SilentlyContinue)) { continue }
    foreach ($s in $suffixes) {
        $p = "${d}:\$s"
        try {
            if (Test-Path "$p\Bazar\shaders\MissionEditor\gui.fx" -ErrorAction SilentlyContinue) {
                Write-Host "  FOUND: $p" -ForegroundColor Green
                $candidates += $p
            }
        } catch { }
    }
}
if (-not $candidates) {
    Write-Host ''
    Write-Host 'ERROR: No DCS install found.' -ForegroundColor Red
    Write-Host 'Checked these patterns on drives C-H:' -ForegroundColor Yellow
    foreach ($s in $suffixes) { Write-Host "  <drive>:\$s" }
    Write-Host ''
    Write-Host 'If your DCS is somewhere else, edit Enable-LsoTools.ps1 and add' -ForegroundColor Yellow
    Write-Host 'your install path to the $suffixes list near the top, then re-run.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '=== FAILED ===' -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host "Log saved to: $logPath"
    pause; exit 1
}
$dcs = $candidates[0]
Write-Host "Using: $dcs" -ForegroundColor Cyan

$fx     = Join-Path $dcs 'Bazar\shaders\MissionEditor\gui.fx'
$fxBak  = "$fx.platcamnvg.bak"
$lua    = Join-Path $dcs 'Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua'
$luaBak = "$lua.platcamnvg.bak"

Write-Host '=== CarrierGUI LSO tools installer ===' -ForegroundColor Cyan
Write-Host "DCS: $dcs"

# ---------------------------------------------------------- patch gui.fx ------
# Update-resilient backup: if the LIVE file does NOT already contain our patch
# marker (_amp), it's a clean/stock file — capture it as the backup (refreshing
# any stale backup left over from before a DCS update).  If the live file IS
# already patched, keep the existing clean .bak.  Either way we then patch from
# the clean .bak.  This is what makes re-running after a DCS update Just Work.
$liveFx = [IO.File]::ReadAllText($fx)
if (-not $liveFx.Contains('_amp')) {
    Copy-Item $fx $fxBak -Force
    Write-Host 'Backed up gui.fx (fresh clean baseline)'
} elseif (-not (Test-Path $fxBak)) {
    Copy-Item $fx $fxBak -Force
    Write-Host 'Backed up gui.fx'
}
$g = [IO.File]::ReadAllText($fxBak)

$fxTarget = 'return correctGammaAndBrightness(diffuse * IN.Color);'
$fxReplace = '{ float3 _amp = diffuse.rgb * IN.Color.rgb; float _outA = diffuse.a * IN.Color.a; if (IN.Color.r < 0.05 && IN.Color.g > 0.95 && IN.Color.b > 0.70 && IN.Color.b < 0.80) { float _l = dot(diffuse.rgb, float3(0.2126, 0.7152, 0.0722)); _l = pow(saturate(_l * 12.0), 1.0 / 2.6); float3 _green = float3(0.23, 0.78, 0.26) * _l * 1.8; _amp = lerp(diffuse.rgb, _green, IN.Color.a); _outA = diffuse.a; } return correctGammaAndBrightness(float4(_amp, _outA)); }'

if (-not $g.Contains($fxTarget)) {
    Write-Host 'ERROR: gui.fx anchor line not found.' -ForegroundColor Red
    pause; exit 1
}
$g = $g.Replace($fxTarget, $fxReplace)
[IO.File]::WriteAllText($fx, $g)
Write-Host 'Patched gui.fx (alpha-as-gain mixer)' -ForegroundColor Green

# -------------------------------------------------------- patch PLATCameraUI --
# Same update-resilient logic.  If the live file is clean (no CARRIERGUI
# marker) capture it as the fresh backup; otherwise restore from the clean
# .bak so we re-patch from a known-good baseline.
$liveLua = [IO.File]::ReadAllText($lua)
if (-not $liveLua.Contains('CARRIERGUI_LSO_TOOLS')) {
    Copy-Item $lua $luaBak -Force
    Write-Host 'Backed up PLATCameraUI.lua (fresh clean baseline)'
} elseif (Test-Path $luaBak) {
    Copy-Item $luaBak $lua -Force
} else {
    Copy-Item $lua $luaBak -Force
}
$t = [IO.File]::ReadAllText($lua)
$luaAnchor = 'function setShipYawPitchRoll(heading,pitch,roll)'

if (-not $t.Contains($luaAnchor)) {
    Write-Host 'ERROR: PLATCameraUI.lua anchor "setShipYawPitchRoll" not found.' -ForegroundColor Red
    pause; exit 1
}

# Combined injection: NVG dial + foul deck + desired wire + PLAT zoom.
# Each piece file-IPC reads at ~30-frame intervals to keep IO cost negligible.
# Effects applied only when the file value actually changes (so we don't spam
# setSkin / setFoulDeck / setDesiredRope / adjustGate every frame).
$luaInject = @'
  -- BEGIN CARRIERGUI_LSO_TOOLS_v1
  _G.__cgF = (_G.__cgF or 0) + 1
  local _read = function(name)
    local f = io.open(lfs.writedir() .. name, 'r')
    if not f then return nil end
    local s = f:read('*a') or ''
    f:close()
    return s
  end
  if _G.__cgF % 30 == 1 then
    pcall(function()
      local s = _read('carriergui_nvg.txt')
      if s then
        local n = tonumber(s) or 0
        if n < 0   then n = 0 end
        if n > 100 then n = 100 end
        _G.__cgNvgPct = n
        _G.__cgNvgSeen = true
      end
      s = _read('carriergui_foul.txt')
      if s then
        local foul = (s:sub(1,1) == '1')
        if foul ~= _G.__cgFoulApplied then
          if setFoulDeck then pcall(setFoulDeck, foul) end
          _G.__cgFoulApplied = foul
        end
      end
      s = _read('carriergui_wire.txt')
      if s then
        local w = tonumber(s) or 0
        if w ~= _G.__cgWireApplied then
          if setDesiredRope then pcall(setDesiredRope, w) end
          _G.__cgWireApplied = w
        end
      end
      s = _read('carriergui_zoom.txt')
      if s then
        local fov = tonumber(s) or 0
        if fov > 0 and fov ~= _G.__cgZoomApplied then
          if adjustGate then pcall(adjustGate, fov, 50, 0) end
          _G.__cgZoomApplied = fov
        end
      end
    end)
  end
  -- NVG dial colour application: every frame to defeat .dlg re-stomp.
  -- At gain 0 we MUST use white (0xffffffff) and not the sentinel-with-
  -- alpha-0 (0x00ffc000). The alpha-0 form makes dxgui cull the widget
  -- before the shader even runs (alpha 0 = "fully transparent skip"),
  -- which black-holes the PLAT cam. White bypasses the shader gate
  -- entirely so DCS draws the raw camera feed.
  if _G.__cgNvgSeen then
    pcall(function()
      local w = LSOStation_ and LSOStation_.PLATCamera
      if not w then return end
      local pct = _G.__cgNvgPct or 0
      local target
      if pct <= 0 then
        target = '0xffffffff'    -- normal feed: gate misses, shader returns diffuse
      else
        local alpha = math.floor(pct * 2.55 + 0.5)
        if alpha < 1 then alpha = 1 end
        target = string.format('0x00ffc0%02x', alpha)
      end
      local sk = w:getSkin()
      local st = sk and sk.skinData and sk.skinData.states and sk.skinData.states.released
      local p = st and st[1] and st[1].picture
      if p and p.color ~= target then
        p.color = target
        w:setSkin(sk)
      end
    end)
  end
  -- END CARRIERGUI_LSO_TOOLS_v1
'@

$t = $t.Replace($luaAnchor, $luaAnchor + "`n" + $luaInject)
[IO.File]::WriteAllText($lua, $t)
Write-Host 'Patched PLATCameraUI.lua (NVG dial + foul/wire/zoom readers)' -ForegroundColor Green

# ---- radar scope image -------------------------------------------------------
# Copy the radar scope TGA into the DCS install next to FLOLS, where the dxgui
# picture loader resolves bkg.file paths (relative to the DCS root).  The
# CarrierGUI panel references it at dialog-load time; without this copy the
# panel falls back to its drawn dot rings.
$imgPairs = @(
    @{ Src = 'radar_scope.tga';   Dst = 'carriergui_radar.tga'; Name = 'MARSHALL radar scope' },
    @{ Src = 'deck_overhead.tga'; Dst = 'carriergui_deck.tga';  Name = 'DECKBOSS deck overhead' }
)
foreach ($img in $imgPairs) {
    $tgaSrc = Join-Path $env:USERPROFILE ("Saved Games\DCS\Scripts\Hooks\" + $img.Src)
    $tgaDst = Join-Path $dcs ('Mods\tech\Supercarrier\PLATCameraUI\' + $img.Dst)
    if (Test-Path $tgaSrc) {
        Copy-Item $tgaSrc $tgaDst -Force
        Write-Host ("Installed {0} image -> {1}" -f $img.Name, $tgaDst) -ForegroundColor Green
    } else {
        Write-Host ("{0} not found in Saved Games\DCS\Scripts\Hooks (skipping image)" -f $img.Src) -ForegroundColor Yellow
    }
}

# Clear shader cache so DCS rebuilds for our patched gui.fx.
foreach ($c in @('metashaders2','fxo','fxo2')) {
    foreach ($sg in @('Saved Games\DCS','Saved Games\DCS.openbeta')) {
        $p = Join-Path $env:USERPROFILE (Join-Path $sg $c)
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared shader cache: $p"
        }
    }
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Green
Write-Host '  CarrierGUI LSO tools installed successfully.' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT:' -ForegroundColor Cyan
Write-Host '  1. Launch DCS. First launch will be slow (rebuilding shaders).'
Write-Host '  2. Start a Supercarrier mission, LAlt+F9 (LSO).'
Write-Host '  3. Ctrl+Shift+c, LSO tab. Try the NVG dial, Wire, Foul Deck,'
Write-Host '     and PLAT Zoom controls. See LSO calls broadcast on screen.'
Write-Host ''
Write-Host 'Undo: Disable-LsoTools.ps1'
Write-Host ''
try { Stop-Transcript | Out-Null } catch {}
Write-Host "Log saved: $logPath" -ForegroundColor Cyan
Write-Host '   ^ If anything went wrong, send that file to the project owner.'
pause
